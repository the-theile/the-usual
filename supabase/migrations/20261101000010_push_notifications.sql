-- The Usual — 0010: shift alerts (web push)
--
-- A regular turns on the bell for a bartender (connections.notify). About two
-- hours before each of that bartender's shifts, every device the regular has
-- registered gets "Sam's working tonight at Tiki Moon, 8pm".
--
-- Pieces:
--   push_subscriptions      one row per device (browser push endpoint + keys)
--   private.shift_alerts    which shift occurrences were already announced
--   claim_shift_alerts()    service role only: marks due shifts as sent and
--                           returns who to notify (called by the shift-alerts
--                           edge function every 15 minutes, see 0011)

-- ===== The bell: a regular may change only notify, only on their own rows =====
grant update (notify) on public.connections to authenticated;
create policy connections_update_notify_by_regular on public.connections for update to authenticated
  using (regular_id = (select auth.uid()))
  with check (regular_id = (select auth.uid()));

-- ===== Devices =====
-- No client grants: devices are saved and removed through the functions below,
-- because one browser can move between accounts (same endpoint, new owner).
create table public.push_subscriptions (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles (id) on delete cascade,
  endpoint   text not null unique check (endpoint ~ '^https://' and char_length(endpoint) <= 1000),
  p256dh     text not null check (char_length(p256dh) between 1 and 200),
  auth       text not null check (char_length(auth) between 1 and 100),
  created_at timestamptz not null default now()
);
create index push_subscriptions_user_idx on public.push_subscriptions (user_id);
revoke all on public.push_subscriptions from anon, authenticated;
alter table public.push_subscriptions enable row level security;

create or replace function public.save_push_subscription(p_endpoint text, p_p256dh text, p_auth text)
returns void
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'not_signed_in' using errcode = '42501';
  end if;
  if (select count(*) from public.push_subscriptions where user_id = v_uid and endpoint <> p_endpoint) >= 10 then
    raise exception 'too_many_devices' using errcode = '54000';
  end if;
  insert into public.push_subscriptions (user_id, endpoint, p256dh, auth)
  values (v_uid, p_endpoint, p_p256dh, p_auth)
  on conflict (endpoint) do update
    set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth, created_at = now();
end
$$;

-- On sign-out: this device stops getting the person's alerts.
create or replace function public.remove_push_subscription(p_endpoint text)
returns void
language sql volatile security definer
set search_path = ''
as $$
  delete from public.push_subscriptions where endpoint = p_endpoint and user_id = (select auth.uid())
$$;

-- ===== Sent log =====
-- Keyed on the occurrence, so moving a shift to a new time announces it again.
create table private.shift_alerts (
  bartender_id    uuid not null references public.bartenders (id) on delete cascade,
  bar_id          uuid not null,
  occurrence_date date not null,
  start_time      time not null,
  sent_at         timestamptz not null default now(),
  primary key (bartender_id, bar_id, occurrence_date, start_time)
);
revoke all on private.shift_alerts from anon, authenticated;

-- ===== Due alerts =====
-- Shifts starting in the next two hours that haven't been announced yet.
-- A start time before 5am belongs to the next morning (bar days run 5am → 5am).
-- Claiming and returning happen in one statement, so overlapping runs can't double-send.
create or replace function public.claim_shift_alerts()
returns table (
  endpoint text, p256dh text, auth text,
  bartender_name text, public_id text, bar_name text, start_time time, occurrence_date date
)
language plpgsql volatile security definer
set search_path = ''
as $$
#variable_conflict use_column
begin
  return query
  with notified as (
    select distinct c.bartender_id from public.connections c where c.notify
  ),
  occ as (
    select o.bartender_id, o.bar_id, o.bar_name, o.occurrence_date, o.start_time,
           ((o.occurrence_date + case when o.start_time < time '05:00' then 1 else 0 end) + o.start_time)
             at time zone b.timezone as starts_at
      from public.get_schedule((select coalesce(array_agg(bartender_id), '{}') from notified),
                               current_date - 1, current_date + 1) o
      join public.bartenders b on b.id = o.bartender_id
     where not o.cancelled
  ),
  due as (
    select * from occ where occ.starts_at > now() and occ.starts_at <= now() + interval '2 hours'
  ),
  claimed as (
    insert into private.shift_alerts (bartender_id, bar_id, occurrence_date, start_time)
    select d.bartender_id, d.bar_id, d.occurrence_date, d.start_time from due d
    on conflict do nothing
    returning shift_alerts.bartender_id, shift_alerts.bar_id, shift_alerts.occurrence_date, shift_alerts.start_time
  )
  select s.endpoint, s.p256dh, s.auth, p.display_name, b.public_id, d.bar_name, d.start_time, d.occurrence_date
    from claimed cl
    join due d on d.bartender_id = cl.bartender_id and d.bar_id = cl.bar_id
              and d.occurrence_date = cl.occurrence_date and d.start_time = cl.start_time
    join public.bartenders b on b.id = cl.bartender_id
    join public.profiles p on p.id = cl.bartender_id
    join public.connections c on c.bartender_id = cl.bartender_id and c.notify
    join public.push_subscriptions s on s.user_id = c.regular_id;

  -- Keep the log small: nothing older than a week is needed.
  delete from private.shift_alerts where sent_at < now() - interval '7 days';
end
$$;

-- The edge function removes devices the push service says are gone (404/410).
create or replace function public.drop_push_subscriptions(p_endpoints text[])
returns void
language sql volatile security definer
set search_path = ''
as $$
  delete from public.push_subscriptions where endpoint = any (p_endpoints)
$$;

-- ===== Function privileges =====
revoke all on function public.save_push_subscription(text, text, text) from public, anon;
revoke all on function public.remove_push_subscription(text) from public, anon;
grant execute on function public.save_push_subscription(text, text, text),
                          public.remove_push_subscription(text) to authenticated;

revoke all on function public.claim_shift_alerts() from public, anon, authenticated;
revoke all on function public.drop_push_subscriptions(text[]) from public, anon, authenticated;
grant execute on function public.claim_shift_alerts(), public.drop_push_subscriptions(text[]) to service_role;
