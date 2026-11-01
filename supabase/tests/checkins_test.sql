-- The Usual — "I'm coming tonight" test suite (migration 0012).
-- Runs in one transaction and ROLLS BACK, so it is safe on a real project:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/checkins_test.sql
-- Any failure raises "FAIL: ..." and aborts. Success ends with "ALL CHECK-IN TESTS PASSED".

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

create function pg_temp.admin() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
end $$;

--  alice = bartender working tonight; bob = bartender off tonight
--  rita, tom, una = alice's regulars (una gets blocked); sam = stranger
create temp table ids (name text primary key, id uuid);
grant select on ids to authenticated;
insert into ids values
  ('alice', '00000000-0000-4000-a200-00000000000a'),
  ('bob',   '00000000-0000-4000-a200-00000000000b'),
  ('rita',  '00000000-0000-4000-a200-0000000000c1'),
  ('tom',   '00000000-0000-4000-a200-0000000000c2'),
  ('una',   '00000000-0000-4000-a200-0000000000c3'),
  ('sam',   '00000000-0000-4000-a200-0000000000c4');
create function pg_temp.id(n text) returns uuid language sql stable as $$ select id from ids where name = n $$;
create function pg_temp.tonight(viewer text, bartender text) returns table (others int, me boolean) language plpgsql as $$
begin
  perform pg_temp.login(pg_temp.id(viewer));
  return query select t.others, t.me from public.tonight_checkins(array[pg_temp.id(bartender)]) t;
end $$;

insert into auth.users (id, phone) select id, '1555700' || row_number() over () from ids;

do $$
begin
  perform pg_temp.admin();
  insert into public.profiles (id, display_name) select id, initcap(name) from ids;
  insert into public.bartenders (id, timezone) values (pg_temp.id('alice'), 'America/Chicago'), (pg_temp.id('bob'), 'America/Chicago');
  insert into public.bars (id, bartender_id, name) values
    ('00000000-0000-4000-a200-0000000000b1', pg_temp.id('alice'), 'Tiki Moon'),
    ('00000000-0000-4000-a200-0000000000b2', pg_temp.id('bob'),   'The Anchor');
  insert into public.shifts (bartender_id, bar_id, shift_date, start_time) values
    (pg_temp.id('alice'), '00000000-0000-4000-a200-0000000000b1', private.bar_day('America/Chicago'), '20:00'),
    (pg_temp.id('bob'),   '00000000-0000-4000-a200-0000000000b2', private.bar_day('America/Chicago') + 1, '20:00');
  insert into public.connections (bartender_id, regular_id, source) values
    (pg_temp.id('alice'), pg_temp.id('rita'), 'code'),
    (pg_temp.id('alice'), pg_temp.id('tom'),  'code'),
    (pg_temp.id('alice'), pg_temp.id('una'),  'code'),
    (pg_temp.id('bob'),   pg_temp.id('rita'), 'code');
end $$;

-- ---------- Checking in ----------
do $$
begin
  perform pg_temp.login(pg_temp.id('rita'));
  perform pg_temp.ok(public.check_in(pg_temp.id('alice'), true), 'regular can say they''re coming when their bartender works tonight');
  perform pg_temp.ok(public.check_in(pg_temp.id('alice'), true), '…saying it twice is fine');
  perform pg_temp.ok((select count(*) from public.checkins where regular_id = pg_temp.id('rita')) = 1, '…and counts once');
  perform pg_temp.ok((select bar_day from public.checkins where regular_id = pg_temp.id('rita')) = private.bar_day('America/Chicago'),
    'check-in is for tonight''s bar day in the bartender''s time zone');

  perform pg_temp.ok(not public.check_in(pg_temp.id('bob'), true), 'cannot check in when the bartender is off tonight');

  perform pg_temp.login(pg_temp.id('sam'));
  perform pg_temp.ok(not public.check_in(pg_temp.id('alice'), true), 'a stranger cannot check in');
  perform pg_temp.fails(format('insert into public.checkins (bartender_id, regular_id, bar_day) values (%L, %L, current_date)', pg_temp.id('alice'), pg_temp.id('sam')),
    'check-ins cannot be written directly');

  perform pg_temp.login(pg_temp.id('tom'));
  perform public.check_in(pg_temp.id('alice'), true);
  perform pg_temp.login(pg_temp.id('una'));
  perform public.check_in(pg_temp.id('alice'), true);
end $$;

-- ---------- Who sees what ----------
do $$
declare r record;
begin
  perform pg_temp.login(pg_temp.id('alice'));
  perform pg_temp.ok((select count(*) from public.checkins where bartender_id = pg_temp.id('alice')) = 3, 'bartender sees who is coming');

  select * into r from pg_temp.tonight('rita', 'alice');
  perform pg_temp.ok(r.me and r.others = 2, 'regular sees they''re coming and "2 others"');
  perform pg_temp.login(pg_temp.id('rita'));
  perform pg_temp.ok((select count(*) from public.checkins) = 1, 'regulars never see other regulars'' check-ins (only the count)');

  perform pg_temp.login(pg_temp.id('sam'));
  perform pg_temp.ok((select count(*) from public.tonight_checkins(array[pg_temp.id('alice')])) = 0, 'a stranger gets no count');
end $$;

-- ---------- Blocking, unfollowing, taking it back ----------
do $$
declare r record;
begin
  perform pg_temp.login(pg_temp.id('alice'));
  perform public.block_regular(pg_temp.id('una'));
  perform pg_temp.ok((select count(*) from public.checkins where bartender_id = pg_temp.id('alice')) = 2, 'blocked person drops off the bartender''s list');
  select * into r from pg_temp.tonight('rita', 'alice');
  perform pg_temp.ok(r.others = 1, '…and from the count');
  perform pg_temp.login(pg_temp.id('una'));
  perform pg_temp.ok(not public.check_in(pg_temp.id('alice'), true), '…and cannot check in');
  perform pg_temp.ok((select count(*) from public.tonight_checkins(array[pg_temp.id('alice')])) = 0, '…or see the count');

  perform pg_temp.login(pg_temp.id('tom'));
  delete from public.connections where bartender_id = pg_temp.id('alice') and regular_id = pg_temp.id('tom');
  select * into r from pg_temp.tonight('rita', 'alice');
  perform pg_temp.ok(r.others = 0, 'a regular who unfollows is no longer counted');

  perform pg_temp.login(pg_temp.id('rita'));
  perform pg_temp.ok(public.check_in(pg_temp.id('alice'), false), 'regular can take it back');
  select * into r from pg_temp.tonight('rita', 'alice');
  perform pg_temp.ok(not r.me, '…and is no longer coming');
end $$;

-- ---------- Resets with the bar day ----------
do $$
declare r record;
begin
  perform pg_temp.admin();
  insert into public.checkins (bartender_id, regular_id, bar_day)
    values (pg_temp.id('alice'), pg_temp.id('rita'), private.bar_day('America/Chicago') - 1);
  select * into r from pg_temp.tonight('rita', 'alice');
  perform pg_temp.ok(not r.me, 'last night''s check-in doesn''t count tonight');
end $$;

select pg_temp.admin();
do $$ begin raise notice 'ALL CHECK-IN TESTS PASSED'; end $$;
rollback;
