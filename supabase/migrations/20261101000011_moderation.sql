-- The Usual — 0011: reports, moderator tools and product metrics
--
-- * Anyone can report a post, a reply message or a person they can actually see.
--   Reporting is silent: the reported person is never told, and the reporter
--   gets the same "thanks" whatever happens next.
-- * Moderators are listed in private.moderators (added by hand in the SQL editor,
--   see README). Nobody else can read reports, the audit log or the metrics.
-- * Everything lives in schema "private", which the API does not expose. Clients
--   only reach it through the SECURITY DEFINER functions below, each of which
--   checks the caller first.
-- * A report keeps a snapshot of what was reported (text + photo path), so the
--   evidence survives if the author deletes it.
-- * Suspending someone bans their sign-in (auth.users.banned_until) and ends
--   their sessions. An access token already issued stays valid until it expires
--   (at most an hour).

-- ===== Tables =====

create table private.moderators (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);

create table private.reports (
  id               uuid primary key default gen_random_uuid(),
  reporter_id      uuid references auth.users (id) on delete set null,
  reported_user_id uuid references auth.users (id) on delete set null,
  kind             text not null check (kind in ('post', 'reply', 'person')),
  post_id          uuid references public.posts (id) on delete set null,
  reply_id         uuid references public.post_replies (id) on delete set null,
  reason           text not null check (reason in ('spam', 'harassment', 'inappropriate', 'impersonation', 'safety', 'other')),
  details          text not null default '' check (char_length(details) <= 500),
  reported_name    text not null default '',     -- display name at the time of the report
  snapshot_body    text not null default '',     -- post / reply text, or a bartender's bio
  snapshot_photo   text,                         -- post-photos path
  status           text not null default 'open' check (status in ('open', 'dismissed', 'actioned')),
  resolution       text not null default '' check (char_length(resolution) <= 500),
  resolved_by      uuid references auth.users (id) on delete set null,
  resolved_at      timestamptz,
  created_at       timestamptz not null default now(),
  target_id        uuid not null                 -- what was reported (kept after the content is deleted)
);
create index reports_status_idx   on private.reports (status, created_at desc);
create index reports_reported_idx on private.reports (reported_user_id);
create index reports_reporter_idx on private.reports (reporter_id, created_at desc);
create index reports_photo_idx    on private.reports (snapshot_photo) where snapshot_photo is not null;
-- Reporting the same thing twice while it is still open does nothing.
create unique index reports_one_open on private.reports (reporter_id, kind, target_id) where status = 'open';

create table private.suspensions (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  until      timestamptz not null,
  note       text not null default '',
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now()
);

-- Audit log of every moderator action.
create table private.mod_actions (
  id           bigint generated always as identity primary key,
  moderator_id uuid references auth.users (id) on delete set null,
  action       text not null check (action in ('dismiss', 'remove', 'suspend', 'unsuspend')),
  report_id    uuid references private.reports (id) on delete set null,
  target_user  uuid references auth.users (id) on delete set null,
  target_name  text not null default '',
  note         text not null default '',
  created_at   timestamptz not null default now()
);
create index mod_actions_created_idx on private.mod_actions (created_at desc);

revoke all on private.moderators, private.reports, private.suspensions, private.mod_actions
  from anon, authenticated, public;

-- ===== Helpers =====

create or replace function private.is_moderator()
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (select 1 from private.moderators where user_id = (select auth.uid()))
$$;

create or replace function private.require_moderator()
returns void
language plpgsql stable security definer
set search_path = ''
as $$
begin
  if not private.is_moderator() then
    raise exception 'not_a_moderator' using errcode = '42501';
  end if;
end
$$;

-- Storage policies run as the caller, who can't read private.reports directly.
create or replace function private.is_reported_photo(p_path text)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (select 1 from private.reports where snapshot_photo = p_path)
$$;

create policy "usual: moderators view reported photos" on storage.objects for select to authenticated
  using (bucket_id = 'post-photos' and private.is_moderator() and private.is_reported_photo(name));

-- ===== Reporting (anyone signed in) =====

-- p_kind 'post' | 'reply' (p_target = its id) | 'person' (p_target = their user id).
-- Something the caller can't see gives the same 'not_found' as something that doesn't exist.
create or replace function public.report(p_kind text, p_target uuid, p_reason text, p_details text default '')
returns void
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_user    uuid;
  v_post    uuid;
  v_reply   uuid;
  v_body    text := '';
  v_photo   text;
  v_details text := btrim(coalesce(p_details, ''));
begin
  if v_uid is null then
    raise exception 'not_signed_in' using errcode = '42501';
  end if;
  if p_reason is null or p_reason not in ('spam', 'harassment', 'inappropriate', 'impersonation', 'safety', 'other') then
    raise exception 'bad_reason' using errcode = '22023';
  end if;
  if char_length(v_details) > 500 then
    raise exception 'too_long' using errcode = '22001';
  end if;
  if (select count(*) from private.reports
       where reporter_id = v_uid and created_at > now() - interval '1 day') >= 20 then
    raise exception 'rate_limited' using errcode = '54000';
  end if;

  if p_kind = 'post' then
    select p.bartender_id, p.id, p.body, p.photo_path into v_user, v_post, v_body, v_photo
      from public.posts p
     where p.id = p_target and p.bartender_id <> v_uid
       and (private.can_view_bartender(p.bartender_id)
            or (p.visibility = 'public' and private.can_view_schedule(p.bartender_id)));
  elsif p_kind = 'reply' then
    -- The other side of one of my own conversations.
    select r.author_id, r.post_id, r.id, r.body into v_user, v_post, v_reply, v_body
      from public.post_replies r
     where r.id = p_target and r.author_id <> v_uid
       and ((r.regular_id = v_uid and private.can_view_bartender(r.bartender_id))
            or r.bartender_id = v_uid);
  elsif p_kind = 'person' then
    -- A bartender whose page I can see, or one of my (current or blocked) regulars.
    select pr.id, coalesce(b.bio, '') into v_user, v_body
      from public.profiles pr left join public.bartenders b on b.id = pr.id
     where pr.id = p_target and pr.id <> v_uid
       and ((b.id is not null and private.can_view_schedule(b.id)) or private.is_my_regular(pr.id));
  else
    raise exception 'bad_kind' using errcode = '22023';
  end if;

  if v_user is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  insert into private.reports (reporter_id, reported_user_id, kind, target_id, post_id, reply_id, reason, details,
                               reported_name, snapshot_body, snapshot_photo)
  values (v_uid, v_user, p_kind, p_target, v_post, v_reply, p_reason, v_details,
          coalesce((select display_name from public.profiles where id = v_user), ''),
          coalesce(v_body, ''), v_photo)
  on conflict (reporter_id, kind, target_id) where status = 'open' do nothing;
end
$$;

-- ===== Moderator tools =====

-- Only ever answers for the caller, so it reveals nothing about anyone else.
create or replace function public.am_i_moderator()
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select private.is_moderator()
$$;

-- p_status: 'open' or 'closed' (dismissed + actioned).
create or replace function public.mod_reports(p_status text default 'open', p_limit int default 50)
returns table (
  id uuid, kind text, reason text, details text, status text, created_at timestamptz,
  reporter_name text, reported_user_id uuid, reported_name text, reported_is_bartender boolean,
  reports_against int, suspended_until timestamptz,
  body text, photo_path text, content_live boolean,
  resolution text, resolved_at timestamptz
)
language plpgsql stable security definer
set search_path = ''
as $$
begin
  perform private.require_moderator();
  return query
  select r.id, r.kind, r.reason, r.details, r.status, r.created_at,
         coalesce(rp.display_name, 'Deleted account'),
         r.reported_user_id,
         coalesce(tp.display_name, nullif(r.reported_name, ''), 'Deleted account'),
         exists (select 1 from public.bartenders b where b.id = r.reported_user_id),
         (select count(*)::int from private.reports x where x.reported_user_id = r.reported_user_id),
         (select s.until from private.suspensions s where s.user_id = r.reported_user_id and s.until > now()),
         r.snapshot_body, r.snapshot_photo,
         case r.kind when 'post'   then exists (select 1 from public.posts p where p.id = r.target_id)
                     when 'reply'  then exists (select 1 from public.post_replies y where y.id = r.target_id)
                     else exists (select 1 from public.profiles p where p.id = r.target_id) end,
         r.resolution, r.resolved_at
    from private.reports r
    left join public.profiles rp on rp.id = r.reporter_id
    left join public.profiles tp on tp.id = r.reported_user_id
   where (p_status = 'open' and r.status = 'open') or (p_status = 'closed' and r.status <> 'open')
   order by case when p_status = 'open' then r.created_at end asc,      -- oldest first: a queue
            case when p_status <> 'open' then r.resolved_at end desc
   limit least(greatest(coalesce(p_limit, 50), 1), 200);
end
$$;

-- Ban sign-in and end every session. p_days null = until lifted.
create or replace function private.suspend_user(p_user uuid, p_days int, p_note text)
returns timestamptz
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_until timestamptz := case when p_days is null then now() + interval '100 years'
                              else now() + make_interval(days => greatest(p_days, 1)) end;
begin
  if p_user is null or not exists (select 1 from auth.users where id = p_user) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if p_user = auth.uid() or exists (select 1 from private.moderators where user_id = p_user) then
    raise exception 'cannot_suspend_moderator' using errcode = '42501';
  end if;
  insert into private.suspensions (user_id, until, note, created_by)
  values (p_user, v_until, coalesce(p_note, ''), auth.uid())
  on conflict (user_id) do update set until = excluded.until, note = excluded.note,
                                      created_by = excluded.created_by, created_at = now();
  update auth.users set banned_until = v_until where id = p_user;
  delete from auth.sessions where user_id = p_user;   -- refresh tokens go with them
  return v_until;
end
$$;

-- Resolve a report. Neither flag = dismiss. p_remove deletes the reported post or
-- reply (not a person). p_suspend suspends the reported person (p_days null = until lifted).
-- Other open reports about the same post/reply are closed with it.
create or replace function public.mod_resolve(p_report uuid, p_remove boolean default false,
                                              p_suspend boolean default false, p_days int default null,
                                              p_note text default '')
returns void
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_uid  uuid := auth.uid();
  v_r    private.reports;
  v_note text := left(btrim(coalesce(p_note, '')), 500);
  v_did  text[] := '{}';
begin
  perform private.require_moderator();
  select * into v_r from private.reports where id = p_report for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if v_r.status <> 'open' then
    raise exception 'already_resolved' using errcode = '55000';
  end if;

  if coalesce(p_remove, false) then
    if v_r.kind = 'post' then
      delete from public.posts where id = v_r.target_id;
    elsif v_r.kind = 'reply' then
      delete from public.post_replies where id = v_r.target_id;
    else
      raise exception 'cannot_remove_person' using errcode = '22023';
    end if;
    v_did := v_did || 'removed'::text;
    insert into private.mod_actions (moderator_id, action, report_id, target_user, target_name, note)
    values (v_uid, 'remove', v_r.id, v_r.reported_user_id, v_r.reported_name, v_note);
  end if;

  if coalesce(p_suspend, false) then
    perform private.suspend_user(v_r.reported_user_id, p_days, v_note);
    v_did := v_did || 'suspended'::text;
    insert into private.mod_actions (moderator_id, action, report_id, target_user, target_name, note)
    values (v_uid, 'suspend', v_r.id, v_r.reported_user_id, v_r.reported_name,
            concat_ws(' · ', case when p_days is null then 'until lifted' else p_days || ' days' end, nullif(v_note, '')));
  end if;

  if cardinality(v_did) = 0 then
    insert into private.mod_actions (moderator_id, action, report_id, target_user, target_name, note)
    values (v_uid, 'dismiss', v_r.id, v_r.reported_user_id, v_r.reported_name, v_note);
  end if;

  update private.reports
     set status = case when cardinality(v_did) = 0 then 'dismissed' else 'actioned' end,
         resolution = concat_ws(' · ', nullif(array_to_string(v_did, ' + '), ''), nullif(v_note, '')),
         resolved_by = v_uid, resolved_at = now()
   where status = 'open'
     and (id = v_r.id or (cardinality(v_did) > 0 and kind = v_r.kind and kind <> 'person' and target_id = v_r.target_id));
end
$$;

create or replace function public.mod_suspend(p_user uuid, p_days int default null, p_note text default '')
returns timestamptz
language plpgsql volatile security definer
set search_path = ''
as $$
declare v_until timestamptz;
begin
  perform private.require_moderator();
  v_until := private.suspend_user(p_user, p_days, left(btrim(coalesce(p_note, '')), 500));
  insert into private.mod_actions (moderator_id, action, target_user, target_name, note)
  values (auth.uid(), 'suspend', p_user, coalesce((select display_name from public.profiles where id = p_user), ''),
          case when p_days is null then 'until lifted' else p_days || ' days' end);
  return v_until;
end
$$;

create or replace function public.mod_unsuspend(p_user uuid)
returns void
language plpgsql volatile security definer
set search_path = ''
as $$
begin
  perform private.require_moderator();
  delete from private.suspensions where user_id = p_user;
  update auth.users set banned_until = null where id = p_user;
  insert into private.mod_actions (moderator_id, action, target_user, target_name)
  values (auth.uid(), 'unsuspend', p_user, coalesce((select display_name from public.profiles where id = p_user), ''));
end
$$;

create or replace function public.mod_suspended()
returns table (user_id uuid, display_name text, until timestamptz, note text, created_at timestamptz)
language plpgsql stable security definer
set search_path = ''
as $$
begin
  perform private.require_moderator();
  return query
  select s.user_id, coalesce(p.display_name, 'Deleted account'), s.until, s.note, s.created_at
    from private.suspensions s left join public.profiles p on p.id = s.user_id
   where s.until > now()
   order by s.created_at desc;
end
$$;

create or replace function public.mod_log(p_limit int default 30)
returns table (action text, moderator_name text, target_name text, note text, created_at timestamptz)
language plpgsql stable security definer
set search_path = ''
as $$
begin
  perform private.require_moderator();
  return query
  select a.action, coalesce(p.display_name, '—'), a.target_name, a.note, a.created_at
    from private.mod_actions a left join public.profiles p on p.id = a.moderator_id
   order by a.created_at desc
   limit least(greatest(coalesce(p_limit, 30), 1), 200);
end
$$;

-- ===== Product metrics (aggregates only, no personal data) =====
-- "Active" = did something we can see in the database in the window: posted,
-- reacted, replied, or followed someone. Days are UTC.
create or replace function public.mod_metrics()
returns json
language plpgsql stable security definer
set search_path = ''
as $$
declare
  d7  timestamptz := now() - interval '7 days';
  d30 timestamptz := now() - interval '30 days';
  v   json;
begin
  perform private.require_moderator();

  with
  actors as (
    select bartender_id as uid, created_at from public.posts
    union all select regular_id, created_at from public.post_reactions
    union all select author_id, created_at from public.post_replies
    union all select regular_id, created_at from public.connections
  ),
  regs as (select bartender_id, count(*) as n from public.connections group by bartender_id),
  posted30 as (select distinct bartender_id from public.posts where created_at > d30),
  scheduled as (select bartender_id from public.shifts union select bartender_id from public.shift_patterns),
  p30 as (
    select p.id, p.visibility,
           (select count(*) from public.post_reactions r where r.post_id = p.id) as reactions,
           (select count(*) from public.post_replies y where y.post_id = p.id and y.author_id <> p.bartender_id) as replies
      from public.posts p where p.created_at > d30
  ),
  days as (select generate_series((now() at time zone 'utc')::date - 13, (now() at time zone 'utc')::date, '1 day')::date as day)
  select json_build_object(
    'generated_at', now(),
    'people', json_build_object(
      'total',       (select count(*) from public.profiles),
      'bartenders',  (select count(*) from public.bartenders),
      'regulars',    (select count(distinct regular_id) from public.connections),
      'new_7d',      (select count(*) from public.profiles where created_at > d7),
      'new_30d',     (select count(*) from public.profiles where created_at > d30),
      'active_7d',   (select count(distinct uid) from actors where created_at > d7),
      'active_30d',  (select count(distinct uid) from actors where created_at > d30)),
    'bartender_funnel', json_build_object(
      'signed_up',      (select count(*) from public.bartenders),
      'set_schedule',   (select count(*) from public.bartenders b where b.id in (select bartender_id from scheduled)),
      'has_regular',    (select count(*) from regs),
      'posted_30d',     (select count(*) from posted30),
      'five_regulars',  (select count(*) from regs where n >= 5)),
    'regulars_per_bartender', json_build_object(
      'avg',    (select round(avg(n), 1) from regs),
      'median', (select percentile_cont(0.5) within group (order by n) from regs),
      'max',    (select max(n) from regs)),
    'follows', json_build_object(
      'total',   (select count(*) from public.connections),
      'new_7d',  (select count(*) from public.connections where created_at > d7),
      'new_30d', (select count(*) from public.connections where created_at > d30),
      'by_source_30d', json_build_object(
        'qr',   (select count(*) from public.connections where created_at > d30 and source = 'qr'),
        'code', (select count(*) from public.connections where created_at > d30 and source = 'code'),
        'link', (select count(*) from public.connections where created_at > d30 and source = 'link'))),
    'posts', json_build_object(
      'total',             (select count(*) from public.posts),
      'new_7d',            (select count(*) from public.posts where created_at > d7),
      'new_30d',           (select count(*) from p30),
      'public_30d',        (select count(*) from p30 where visibility = 'public'),
      'with_response_30d', (select count(*) from p30 where reactions + replies > 0),
      'reactions_30d',     (select coalesce(sum(reactions), 0) from p30),
      'replies_30d',       (select coalesce(sum(replies), 0) from p30)),
    'safety', json_build_object(
      'blocks_total',  (select count(*) from public.blocks),
      'blocks_30d',    (select count(*) from public.blocks where created_at > d30),
      'reports_open',  (select count(*) from private.reports where status = 'open'),
      'reports_30d',   (select count(*) from private.reports where created_at > d30),
      'suspended_now', (select count(*) from private.suspensions where until > now())),
    'daily', (select json_agg(json_build_object(
        'day', d.day,
        'signups', (select count(*) from public.profiles x where (x.created_at at time zone 'utc')::date = d.day),
        'follows', (select count(*) from public.connections x where (x.created_at at time zone 'utc')::date = d.day),
        'posts',   (select count(*) from public.posts x where (x.created_at at time zone 'utc')::date = d.day),
        'active',  (select count(distinct a.uid) from actors a where (a.created_at at time zone 'utc')::date = d.day))
      order by d.day) from days d)
  ) into v;
  return v;
end
$$;

-- ===== Privileges =====

revoke all on function public.report(text, uuid, text, text) from public, anon;
revoke all on function public.am_i_moderator() from public, anon;
revoke all on function public.mod_reports(text, int) from public, anon;
revoke all on function public.mod_resolve(uuid, boolean, boolean, int, text) from public, anon;
revoke all on function public.mod_suspend(uuid, int, text) from public, anon;
revoke all on function public.mod_unsuspend(uuid) from public, anon;
revoke all on function public.mod_suspended() from public, anon;
revoke all on function public.mod_log(int) from public, anon;
revoke all on function public.mod_metrics() from public, anon;
revoke all on function private.suspend_user(uuid, int, text) from public, anon, authenticated;

grant execute on function public.report(text, uuid, text, text) to authenticated;
grant execute on function public.am_i_moderator() to authenticated;
grant execute on function public.mod_reports(text, int) to authenticated;
grant execute on function public.mod_resolve(uuid, boolean, boolean, int, text) to authenticated;
grant execute on function public.mod_suspend(uuid, int, text) to authenticated;
grant execute on function public.mod_unsuspend(uuid) to authenticated;
grant execute on function public.mod_suspended() to authenticated;
grant execute on function public.mod_log(int) to authenticated;
grant execute on function public.mod_metrics() to authenticated;
