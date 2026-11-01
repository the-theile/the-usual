-- The Usual — shift alerts test suite (migration 0010).
-- Runs in one transaction and ROLLS BACK, so it is safe on a real project:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/push_notifications_test.sql
-- Any failure raises "FAIL: ..." and aborts. Success ends with "ALL SHIFT ALERT TESTS PASSED".

begin;

create function pg_temp.ok(c boolean, msg text) returns void language plpgsql as $$
begin
  if c is not true then raise exception 'FAIL: %', msg; end if;
  raise notice 'ok - %', msg;
end $$;

create function pg_temp.fails(stmt text, msg text) returns void language plpgsql as $$
begin
  begin
    execute stmt;
  exception when others then
    raise notice 'ok - % (%)', msg, sqlerrm;
    return;
  end;
  raise exception 'FAIL: % — statement succeeded: %', msg, stmt;
end $$;

create function pg_temp.login(u uuid) returns void language plpgsql as $$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
end $$;

create function pg_temp.anon() returns void language plpgsql as $$
begin
  perform set_config('role', 'anon', true);
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
end $$;

create function pg_temp.service() returns void language plpgsql as $$
begin
  perform set_config('role', 'service_role', true);
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
end $$;

create function pg_temp.admin() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
end $$;

-- A shift "N minutes from now" in a time zone, dated the way the app dates it
-- (a start before 5am belongs to the previous bar day).
create function pg_temp.at(tz text, minutes int, out d date, out t time) language sql stable as $$
  select (date_trunc('minute', now() at time zone tz + make_interval(mins => minutes)) - interval '5 hours')::date,
         date_trunc('minute', now() at time zone tz + make_interval(mins => minutes))::time
$$;

--  alice = bartender (LA); rita (bell on), tom (bell off) = alice's regulars
--  bob   = bartender (Tokyo) with no bells on; una = bob's regular; sam = stranger
create temp table ids (name text primary key, id uuid);
grant select on ids to authenticated, anon, service_role;
insert into ids values
  ('alice', '00000000-0000-4000-f000-00000000000a'),
  ('bob',   '00000000-0000-4000-f000-00000000000b'),
  ('rita',  '00000000-0000-4000-f000-0000000000c1'),
  ('tom',   '00000000-0000-4000-f000-0000000000c2'),
  ('una',   '00000000-0000-4000-f000-0000000000c3'),
  ('sam',   '00000000-0000-4000-f000-0000000000c4');
create function pg_temp.id(n text) returns uuid language sql stable as $$ select id from ids where name = n $$;
create function pg_temp.ep(n text) returns text language sql stable as $$ select 'https://push.example.com/' || n $$;

insert into auth.users (id, phone) select id, '1555500' || row_number() over () from ids;

do $$
declare a record; a2 record; a3 record; a4 record; b record;
begin
  perform pg_temp.admin();
  insert into public.profiles (id, display_name) select id, initcap(name) from ids;
  insert into public.bartenders (id, timezone) values
    (pg_temp.id('alice'), 'America/Los_Angeles'), (pg_temp.id('bob'), 'Asia/Tokyo');
  insert into public.bars (id, bartender_id, name) values
    ('00000000-0000-4000-f000-0000000000b1', pg_temp.id('alice'), 'Tiki Moon'),
    ('00000000-0000-4000-f000-0000000000b2', pg_temp.id('alice'), 'The Anchor'),
    ('00000000-0000-4000-f000-0000000000b3', pg_temp.id('bob'),   'Neon Crab');
  insert into public.connections (bartender_id, regular_id, source) values
    (pg_temp.id('alice'), pg_temp.id('rita'), 'code'),
    (pg_temp.id('alice'), pg_temp.id('tom'),  'code'),
    (pg_temp.id('bob'),   pg_temp.id('una'),  'code');

  a  := pg_temp.at('America/Los_Angeles', 60);    -- due
  a2 := pg_temp.at('America/Los_Angeles', 90);    -- due (weekly pattern)
  a3 := pg_temp.at('America/Los_Angeles', 180);   -- too far off
  a4 := pg_temp.at('America/Los_Angeles', -10);   -- already started
  b  := pg_temp.at('Asia/Tokyo', 60);             -- due, but nobody has the bell on
  insert into public.shifts (bartender_id, bar_id, shift_date, start_time) values
    (pg_temp.id('alice'), '00000000-0000-4000-f000-0000000000b1', a.d,  a.t),
    (pg_temp.id('alice'), '00000000-0000-4000-f000-0000000000b1', a3.d, a3.t),
    (pg_temp.id('alice'), '00000000-0000-4000-f000-0000000000b2', a4.d, a4.t),
    (pg_temp.id('bob'),   '00000000-0000-4000-f000-0000000000b3', b.d,  b.t);
  insert into public.shift_patterns (bartender_id, bar_id, weekdays, start_time, starts_on) values
    (pg_temp.id('alice'), '00000000-0000-4000-f000-0000000000b2',
     array[extract(isodow from a2.d)::smallint], a2.t, a2.d - 7);
end $$;

-- ---------- The bell ----------
do $$
begin
  perform pg_temp.login(pg_temp.id('rita'));
  update public.connections set notify = true where bartender_id = pg_temp.id('alice');
  perform pg_temp.ok((select notify from public.connections where bartender_id = pg_temp.id('alice') and regular_id = pg_temp.id('rita')),
    'regular can turn the bell on for a bartender they follow');
  perform pg_temp.fails(format('update public.connections set messaging_enabled = true where regular_id = %L', pg_temp.id('rita')),
    'regular cannot change anything else on the connection');

  perform pg_temp.login(pg_temp.id('tom'));
  update public.connections set notify = true where regular_id = pg_temp.id('rita');
  perform pg_temp.login(pg_temp.id('alice'));
  update public.connections set notify = true where regular_id = pg_temp.id('tom');
  perform pg_temp.admin();
  perform pg_temp.ok(not (select notify from public.connections where regular_id = pg_temp.id('tom')),
    'nobody else can turn on a regular''s bell (not another regular, not the bartender)');
end $$;

-- ---------- Devices ----------
do $$
begin
  perform pg_temp.anon();
  perform pg_temp.fails(format('select public.save_push_subscription(%L, %L, %L)', pg_temp.ep('x'), 'k', 'a'),
    'anonymous visitor cannot register a device');

  perform pg_temp.login(pg_temp.id('rita'));
  perform public.save_push_subscription(pg_temp.ep('rita-phone'), 'k', 'a');
  perform public.save_push_subscription(pg_temp.ep('rita-laptop'), 'k', 'a');
  perform pg_temp.fails('select count(*) from public.push_subscriptions', 'devices cannot be read directly');
  perform pg_temp.fails(format('select public.save_push_subscription(%L, %L, %L)', 'http://insecure.example.com/x', 'k', 'a'),
    'push endpoints must be https');

  perform pg_temp.login(pg_temp.id('tom'));
  perform public.save_push_subscription(pg_temp.ep('tom-phone'), 'k', 'a');
  perform public.remove_push_subscription(pg_temp.ep('rita-phone'));
  perform pg_temp.login(pg_temp.id('una'));
  perform public.save_push_subscription(pg_temp.ep('una-phone'), 'k', 'a');
  perform pg_temp.login(pg_temp.id('sam'));
  perform public.save_push_subscription(pg_temp.ep('shared-ipad'), 'k', 'a');

  perform pg_temp.admin();
  perform pg_temp.ok(exists (select 1 from public.push_subscriptions where endpoint = pg_temp.ep('rita-phone')),
    'you cannot remove someone else''s device');
end $$;

-- ---------- Who may claim alerts ----------
do $$
begin
  perform pg_temp.login(pg_temp.id('rita'));
  perform pg_temp.fails('select * from public.claim_shift_alerts()', 'a signed-in user cannot claim alerts (would expose devices)');
  perform pg_temp.fails(format('select public.drop_push_subscriptions(array[%L])', pg_temp.ep('tom-phone')), '…or drop devices');
  perform pg_temp.anon();
  perform pg_temp.fails('select * from public.claim_shift_alerts()', 'anonymous visitor cannot claim alerts');
end $$;

-- ---------- Claiming ----------
create temp table got (endpoint text, p256dh text, auth text, bartender_name text, public_id text,
                       bar_name text, start_time time, occurrence_date date);
grant all on got to service_role;
select pg_temp.service();
insert into got select * from public.claim_shift_alerts();
select pg_temp.admin();

do $$
begin
  perform pg_temp.ok((select count(*) from got) = 4, 'two due shifts × rita''s two devices = 4 alerts (got ' || (select count(*) from got) || ')');
  perform pg_temp.ok((select count(distinct endpoint) from got) = 2 and not exists (select 1 from got where endpoint not like '%/rita-%'),
    'only the regular with the bell on is alerted (not tom, una or sam)');
  perform pg_temp.ok((select count(*) from got where bar_name = 'Tiki Moon') = 2, 'one-off shift in an hour is announced');
  perform pg_temp.ok((select count(*) from got where bar_name = 'The Anchor') = 2, 'weekly shift in 90 minutes is announced');
  perform pg_temp.ok((select bool_and(bartender_name = 'Alice' and public_id is not null) from got), 'alert carries the bartender name and page id');
  perform pg_temp.ok((select count(*) from private.shift_alerts) = 2, 'shift in 3 hours, already-started shift and bob''s shift are not logged');
end $$;

select pg_temp.service();
do $$ begin
  perform pg_temp.ok((select count(*) from public.claim_shift_alerts()) = 0, 'running again sends nothing (no double alerts)');
end $$;

-- Bob's regular turns the bell on: the next run picks up bob's shift.
select pg_temp.login(pg_temp.id('una'));
update public.connections set notify = true where bartender_id = pg_temp.id('bob');
select pg_temp.service();
do $$ begin
  perform pg_temp.ok((select count(*) from public.claim_shift_alerts() where endpoint = pg_temp.ep('una-phone') and bar_name = 'Neon Crab') = 1,
    'bell turned on before the shift: the next run alerts (other time zone)');
end $$;

-- ---------- Device moves between accounts; account deletion ----------
do $$
begin
  perform pg_temp.login(pg_temp.id('tom'));
  perform public.save_push_subscription(pg_temp.ep('shared-ipad'), 'k2', 'a2');
  perform pg_temp.admin();
  perform pg_temp.ok((select user_id from public.push_subscriptions where endpoint = pg_temp.ep('shared-ipad')) = pg_temp.id('tom'),
    'a device belongs to whoever signed in on it last');

  perform pg_temp.service();
  perform public.drop_push_subscriptions(array[pg_temp.ep('tom-phone')]);
  perform pg_temp.admin();
  perform pg_temp.ok(not exists (select 1 from public.push_subscriptions where endpoint = pg_temp.ep('tom-phone')), 'dead devices can be dropped');

  perform pg_temp.login(pg_temp.id('rita'));
  perform public.delete_my_account();
  perform pg_temp.admin();
  perform pg_temp.ok(not exists (select 1 from public.push_subscriptions where endpoint like '%/rita-%'), 'deleting an account removes its devices');
end $$;

select pg_temp.admin();
do $$ begin raise notice 'ALL SHIFT ALERT TESTS PASSED'; end $$;
rollback;
