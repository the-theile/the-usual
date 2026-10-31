-- The Usual — 0004: functions the app calls via supabase.rpc()

-- ===== Invites (bartender side) =====

-- Today's sayable code + QR token, created on first request of the bar day.
create or replace function public.get_today_invite()
returns json
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_tz  text;
  v_day date;
  v_inv public.invites;
  v_code text;
begin
  select timezone into v_tz from public.bartenders where id = v_uid;
  if v_tz is null then
    raise exception 'not_a_bartender' using errcode = '42501';
  end if;
  v_day := private.bar_day(v_tz);

  select * into v_inv from public.invites
   where bartender_id = v_uid and kind = 'daily' and bar_day = v_day and revoked_at is null;

  if not found then
    perform pg_advisory_xact_lock(hashtext('the-usual:daily-code'));
    v_code := private.new_daily_code();
    insert into public.invites (bartender_id, kind, code, code_norm, bar_day, valid_from, expires_at)
    values (v_uid, 'daily', v_code, private.normalize_code(v_code), v_day, now(),
            private.bar_day_end(v_tz, v_day))
    on conflict (bartender_id, bar_day) where kind = 'daily' and revoked_at is null do nothing;

    select * into v_inv from public.invites
     where bartender_id = v_uid and kind = 'daily' and bar_day = v_day and revoked_at is null;
  end if;

  return json_build_object('code', v_inv.code, 'token', v_inv.token, 'expires_at', v_inv.expires_at);
end
$$;

-- A fresh link token valid for 7 days.
create or replace function public.create_invite_link()
returns json
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_inv public.invites;
begin
  if not exists (select 1 from public.bartenders where id = v_uid) then
    raise exception 'not_a_bartender' using errcode = '42501';
  end if;
  insert into public.invites (bartender_id, kind, expires_at)
  values (v_uid, 'link', now() + interval '7 days')
  returning * into v_inv;
  return json_build_object('token', v_inv.token, 'expires_at', v_inv.expires_at);
end
$$;

-- "My code got out": kill every live code/link; a new daily code is made on next request.
create or replace function public.reset_invites()
returns void
language sql volatile security definer
set search_path = ''
as $$
  update public.invites set revoked_at = now()
   where bartender_id = (select auth.uid()) and revoked_at is null and expires_at > now()
$$;

-- ===== Invites (regular side) =====

-- Before sign-in the join page shows who invited you. Reveals only a display name,
-- and only to someone holding a live 122-bit token. Blocked users get "not found".
create or replace function public.preview_invite(p_token text)
returns json
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_b uuid;
  v_uid uuid := auth.uid();
begin
  select bartender_id into v_b from public.invites
   where token = btrim(coalesce(p_token, '')) and revoked_at is null
     and valid_from <= now() and expires_at > now();
  if v_b is null
     or (v_uid is not null and exists (select 1 from public.blocks
                                        where bartender_id = v_b and regular_id = v_uid)) then
    return json_build_object('ok', false);
  end if;
  return json_build_object(
    'ok', true,
    'display_name', (select display_name from public.profiles where id = v_b),
    'is_self', v_b = v_uid,
    'already_connected', exists (select 1 from public.connections
                                  where bartender_id = v_b and regular_id = v_uid)
  );
end
$$;

-- Redeem a sayable code or a QR/link token. Connects instantly.
-- A blocked user gets exactly the same answer as a wrong code.
create or replace function public.redeem_invite(p_input text)
returns json
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_ip      text;
  v_input   text := btrim(coalesce(p_input, ''));
  v_inv     public.invites;
  v_is_token boolean;
  v_10min   int;
  v_day     int;
  v_ip_hour int := 0;
  v_source  text;
  v_already boolean;
begin
  if v_uid is null then
    raise exception 'not_signed_in' using errcode = '42501';
  end if;
  if not exists (select 1 from public.profiles where id = v_uid) then
    return json_build_object('ok', false, 'reason', 'no_profile');
  end if;

  -- Rate limit on failures: 5 per 10 min and 20 per day per account; 50/hour per IP.
  v_ip := nullif(btrim(split_part(
            coalesce(nullif(current_setting('request.headers', true), '')::json ->> 'x-forwarded-for', ''),
            ',', 1)), '');
  select count(*) filter (where attempted_at > now() - interval '10 minutes'), count(*)
    into v_10min, v_day
    from private.invite_attempts
   where user_id = v_uid and not ok and attempted_at > now() - interval '1 day';
  if v_ip is not null then
    select count(*) into v_ip_hour from private.invite_attempts
     where ip = v_ip and not ok and attempted_at > now() - interval '1 hour';
  end if;
  if v_10min >= 5 or v_day >= 20 or v_ip_hour >= 50 then
    return json_build_object('ok', false, 'reason', 'too_many_tries');
  end if;

  v_is_token := v_input ~ '^[0-9a-f]{32}$';
  if v_is_token then
    select * into v_inv from public.invites
     where token = v_input and revoked_at is null
       and valid_from <= now() and expires_at > now();
  elsif char_length(v_input) between 4 and 40 then
    select * into v_inv from public.invites
     where kind = 'daily' and code_norm = private.normalize_code(v_input)
       and revoked_at is null and valid_from <= now() and expires_at > now()
     limit 1;
  end if;

  if v_inv.id is null
     or exists (select 1 from public.blocks
                 where bartender_id = v_inv.bartender_id and regular_id = v_uid) then
    insert into private.invite_attempts (user_id, ip, ok) values (v_uid, v_ip, false);
    return json_build_object('ok', false, 'reason', 'not_valid');
  end if;

  if v_inv.bartender_id = v_uid then
    return json_build_object('ok', false, 'reason', 'self');
  end if;

  v_source := case when v_inv.kind = 'link' then 'link'
                   when v_is_token then 'qr'
                   else 'code' end;
  v_already := exists (select 1 from public.connections
                        where bartender_id = v_inv.bartender_id and regular_id = v_uid);
  insert into public.connections (bartender_id, regular_id, source)
  values (v_inv.bartender_id, v_uid, v_source)
  on conflict do nothing;
  insert into private.invite_attempts (user_id, ip, ok) values (v_uid, v_ip, true);

  return json_build_object(
    'ok', true,
    'already', v_already,
    'public_id', (select public_id from public.bartenders where id = v_inv.bartender_id),
    'display_name', (select display_name from public.profiles where id = v_inv.bartender_id)
  );
end
$$;

-- ===== Blocking (silent) =====

create or replace function public.block_regular(p_regular uuid)
returns void
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if not exists (select 1 from public.bartenders where id = v_uid) then
    raise exception 'not_a_bartender' using errcode = '42501';
  end if;
  -- Only people who are (or were) your regulars; anything else is a silent no-op.
  if not exists (select 1 from public.connections where bartender_id = v_uid and regular_id = p_regular)
     and not exists (select 1 from public.blocks where bartender_id = v_uid and regular_id = p_regular) then
    return;
  end if;
  insert into public.blocks (bartender_id, regular_id) values (v_uid, p_regular)
  on conflict do nothing;
  delete from public.connections where bartender_id = v_uid and regular_id = p_regular;
end
$$;

-- Unblocking does not reconnect; they would need a fresh code.
create or replace function public.unblock_regular(p_regular uuid)
returns void
language sql volatile security definer
set search_path = ''
as $$
  delete from public.blocks where bartender_id = (select auth.uid()) and regular_id = p_regular
$$;

-- The bartender's regulars plus the people they blocked.
create or replace function public.my_regulars()
returns table (regular_id uuid, display_name text, since timestamptz, blocked boolean)
language sql stable
set search_path = ''
as $$
  select c.regular_id, p.display_name, c.created_at, false
    from public.connections c join public.profiles p on p.id = c.regular_id
   where c.bartender_id = (select auth.uid())
  union all
  select b.regular_id, p.display_name, b.created_at, true
    from public.blocks b join public.profiles p on p.id = b.regular_id
   where b.bartender_id = (select auth.uid())
  order by 4, 2
$$;

-- ===== Schedule =====

-- Expands one-off shifts + weekly patterns + per-night exceptions into occurrences.
-- SECURITY INVOKER: RLS on the underlying tables decides what the caller can see.
create or replace function public.get_schedule(p_bartenders uuid[], p_from date, p_to date)
returns table (
  bartender_id uuid, occurrence_date date, bar_id uuid, bar_name text, bar_area text,
  start_time time, end_time time, note text, source text, source_id uuid, cancelled boolean
)
language sql stable
set search_path = ''
as $$
  with days as (
    select d::date as d
      from generate_series(p_from, least(p_to, p_from + 62), interval '1 day') d
  ),
  occ as (
    select s.bartender_id, s.shift_date as d, s.bar_id, s.start_time, s.end_time, s.note,
           'shift'::text as source, s.id as source_id, false as cancelled
      from public.shifts s
     where s.bartender_id = any (p_bartenders)
       and s.shift_date between p_from and least(p_to, p_from + 62)
    union all
    select p.bartender_id, days.d,
           case when e.pattern_id is null then p.bar_id     else coalesce(e.bar_id, p.bar_id) end,
           case when e.pattern_id is null then p.start_time else coalesce(e.start_time, p.start_time) end,
           case when e.pattern_id is null then p.end_time   else e.end_time end,
           case when e.pattern_id is null then p.note       else e.note end,
           'pattern', p.id, coalesce(e.cancelled, false)
      from public.shift_patterns p
      join days on extract(isodow from days.d)::smallint = any (p.weekdays)
               and days.d >= p.starts_on
               and (p.ends_on is null or days.d <= p.ends_on)
      left join public.shift_exceptions e
             on e.pattern_id = p.id and e.occurrence_date = days.d
     where p.bartender_id = any (p_bartenders)
  )
  select o.bartender_id, o.d, o.bar_id, b.name, b.area, o.start_time, o.end_time, o.note,
         o.source, o.source_id, o.cancelled
    from occ o
    join public.bars b on b.id = o.bar_id
   where not o.cancelled or o.bartender_id = (select auth.uid())
   order by o.d, o.start_time
$$;

-- The regular's home screen: every connected bartender and their shift(s) tonight.
-- Rows with null bar_name mean "off tonight".
create or replace function public.whos_working_tonight()
returns table (
  bartender_id uuid, public_id text, display_name text, photo_path text, bar_day date,
  bar_name text, bar_area text, start_time time, end_time time, note text
)
language sql stable
set search_path = ''
as $$
  select b.id, b.public_id, p.display_name, b.photo_path, d.day,
         o.bar_name, o.bar_area, o.start_time, o.end_time, o.note
    from public.connections c
    join public.bartenders b on b.id = c.bartender_id
    join public.profiles p on p.id = b.id
    cross join lateral (select private.bar_day(b.timezone) as day) d
    left join lateral public.get_schedule(array[b.id], d.day, d.day) o on not o.cancelled
   where c.regular_id = (select auth.uid())
   order by (o.start_time is null), o.start_time, p.display_name
$$;

-- The current bar day for a bartender (used by the client for "tonight").
create or replace function public.bar_today(p_bartender uuid)
returns date
language sql stable
set search_path = ''
as $$
  select private.bar_day(timezone) from public.bartenders where id = p_bartender
$$;

-- ===== Function privileges =====
revoke execute on all functions in schema public from public, anon;
grant execute on function
  public.get_today_invite(), public.create_invite_link(), public.reset_invites(),
  public.redeem_invite(text), public.block_regular(uuid), public.unblock_regular(uuid),
  public.my_regulars(), public.get_schedule(uuid[], date, date),
  public.whos_working_tonight(), public.bar_today(uuid), public.preview_invite(text)
  to authenticated;
grant execute on function public.preview_invite(text) to anon;
