-- The Usual — pinned post test suite (migration 0011).
-- Runs in one transaction and ROLLS BACK, so it is safe on a real project:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/pinned_post_test.sql
-- Any failure raises "FAIL: ..." and aborts. Success ends with "ALL PINNED POST TESTS PASSED".

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

--  alice, bob = bartenders; rita = alice's regular; sam = stranger
create temp table ids (name text primary key, id uuid);
grant select on ids to authenticated;
insert into ids values
  ('alice', '00000000-0000-4000-a100-00000000000a'),
  ('bob',   '00000000-0000-4000-a100-00000000000b'),
  ('rita',  '00000000-0000-4000-a100-0000000000c1'),
  ('sam',   '00000000-0000-4000-a100-0000000000c2'),
  ('p1',    '00000000-0000-4000-a100-0000000000d1'),   -- alice, regulars-only
  ('p2',    '00000000-0000-4000-a100-0000000000d2'),   -- alice, public
  ('p3',    '00000000-0000-4000-a100-0000000000d3');   -- bob
create function pg_temp.id(n text) returns uuid language sql stable as $$ select id from ids where name = n $$;
create function pg_temp.pinned(n text) returns boolean language sql stable as $$
  select pinned_at is not null from public.posts where id = pg_temp.id(n) $$;

insert into auth.users (id, phone) select id, '1555600' || row_number() over () from ids where name not like 'p_';

do $$
begin
  perform pg_temp.admin();
  insert into public.profiles (id, display_name) select id, initcap(name) from ids where name not like 'p_';
  insert into public.bartenders (id, schedule_visibility) values (pg_temp.id('alice'), 'public'), (pg_temp.id('bob'), 'regulars');
  insert into public.connections (bartender_id, regular_id, source) values (pg_temp.id('alice'), pg_temp.id('rita'), 'code');
  insert into public.posts (id, bartender_id, body, visibility, created_at) values
    (pg_temp.id('p1'), pg_temp.id('alice'), 'Mai tai Monday', 'regulars', now() - interval '30 days'),
    (pg_temp.id('p2'), pg_temp.id('alice'), 'New menu',       'public',   now()),
    (pg_temp.id('p3'), pg_temp.id('bob'),   'Quiz night',     'regulars', now());
end $$;

-- ---------- Pinning ----------
do $$
begin
  perform pg_temp.login(pg_temp.id('alice'));
  perform public.pin_post(pg_temp.id('p1'));
  perform pg_temp.ok(pg_temp.pinned('p1'), 'bartender can pin an old update');

  perform public.pin_post(pg_temp.id('p2'));
  perform pg_temp.ok(pg_temp.pinned('p2') and not pg_temp.pinned('p1'), 'pinning another update replaces the pin');

  perform public.pin_post(pg_temp.id('p2'));
  perform pg_temp.ok(pg_temp.pinned('p2'), 'pinning the pinned update again keeps it pinned');

  perform public.pin_post(pg_temp.id('p3'));
  perform pg_temp.admin();
  perform pg_temp.ok(not pg_temp.pinned('p3') and pg_temp.pinned('p2'), 'pinning someone else''s update does nothing (and keeps your pin)');

  perform pg_temp.login(pg_temp.id('alice'));
  perform pg_temp.fails(format('update public.posts set pinned_at = now() where id = %L', pg_temp.id('p1')),
    'pinned_at cannot be set directly (only through pin_post)');

  perform pg_temp.login(pg_temp.id('rita'));
  perform pg_temp.fails(format('select public.pin_post(%L)', pg_temp.id('p1')), 'a regular cannot pin');

  perform pg_temp.admin();
  perform pg_temp.fails(format('update public.posts set pinned_at = now() where id = %L', pg_temp.id('p1')),
    'the database refuses two pinned updates for one bartender');
end $$;

-- ---------- Who sees the pin ----------
do $$
begin
  perform pg_temp.login(pg_temp.id('rita'));
  perform pg_temp.ok((select count(*) from public.posts where bartender_id = pg_temp.id('alice') and pinned_at is not null) = 1,
    'a regular sees their bartender''s pinned update');

  perform pg_temp.login(pg_temp.id('sam'));
  perform pg_temp.ok((select count(*) from public.posts where bartender_id = pg_temp.id('alice') and pinned_at is not null) = 1,
    'a stranger sees a pinned update that is public');

  perform pg_temp.login(pg_temp.id('alice'));
  perform public.pin_post(pg_temp.id('p1'));
  perform pg_temp.login(pg_temp.id('sam'));
  perform pg_temp.ok((select count(*) from public.posts where pinned_at is not null) = 0,
    'a stranger never sees a pinned regulars-only update');
end $$;

-- ---------- Unpinning ----------
do $$
begin
  perform pg_temp.login(pg_temp.id('alice'));
  perform public.pin_post(null);
  perform pg_temp.ok(not exists (select 1 from public.posts where bartender_id = pg_temp.id('alice') and pinned_at is not null), 'unpin removes the pin');

  perform public.pin_post(pg_temp.id('p2'));
  delete from public.posts where id = pg_temp.id('p2');
  perform public.pin_post(pg_temp.id('p1'));
  perform pg_temp.ok(pg_temp.pinned('p1'), 'after deleting the pinned update, another can be pinned');
end $$;

select pg_temp.admin();
do $$ begin raise notice 'ALL PINNED POST TESTS PASSED'; end $$;
rollback;
