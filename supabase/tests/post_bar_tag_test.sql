-- The Usual — post bar tag test suite (migration 0013).
-- Runs in one transaction and ROLLS BACK, so it is safe on a real project:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/post_bar_tag_test.sql
-- Any failure raises "FAIL: ..." and aborts. Success ends with "ALL BAR TAG TESTS PASSED".

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

--  alice and bob = bartenders, each with one bar
create temp table ids (name text primary key, id uuid);
grant select on ids to authenticated;
insert into ids values
  ('alice', '00000000-0000-4000-d000-00000000000a'),
  ('bob',   '00000000-0000-4000-d000-00000000000b');
create function pg_temp.id(n text) returns uuid language sql stable as $$ select id from ids where name = n $$;

create temp table t (k text primary key, v uuid);
grant select, insert on t to authenticated;
create function pg_temp.v(k text) returns uuid language sql stable as $$ select v from t where t.k = $1 $$;

insert into auth.users (id, phone) select id, '1555300' || row_number() over () from ids;

do $$
declare n text;
begin
  foreach n in array array['alice', 'bob'] loop
    perform pg_temp.login(pg_temp.id(n));
    insert into public.profiles (id, display_name) values (pg_temp.id(n), initcap(n));
    insert into public.bartenders (id, schedule_visibility) values (pg_temp.id(n), 'public');
    insert into public.bars (bartender_id, name) values (pg_temp.id(n), initcap(n) || '''s Bar');
    insert into t select n || '_bar', id from public.bars where bartender_id = pg_temp.id(n);
  end loop;

  perform pg_temp.login(pg_temp.id('alice'));
  insert into public.posts (bartender_id, body, bar_id) values (pg_temp.id('alice'), 'Tagged', pg_temp.v('alice_bar'));
  insert into t select 'post', id from public.posts where body = 'Tagged' and bartender_id = pg_temp.id('alice');
  perform pg_temp.ok((select bar_id from public.posts where id = pg_temp.v('post')) = pg_temp.v('alice_bar'),
    'bartender can tag their own bar');
  insert into public.posts (bartender_id, body) values (pg_temp.id('alice'), 'Untagged');
  perform pg_temp.ok((select bar_id from public.posts where body = 'Untagged' and bartender_id = pg_temp.id('alice')) is null,
    'tag is optional');
  perform pg_temp.fails(format('insert into public.posts (bartender_id, body, bar_id) values (%L, %L, %L)',
    pg_temp.id('alice'), 'x', pg_temp.v('bob_bar')), 'cannot tag another bartender''s bar');
  perform pg_temp.fails(format('update public.posts set bar_id = null where id = %L', pg_temp.v('post')),
    'tag cannot be changed after posting');

  perform pg_temp.ok((select b.name from public.posts p join public.bars b on b.id = p.bar_id where p.id = pg_temp.v('post')) = 'Alice''s Bar',
    'bar name readable through the tag');

  delete from public.bars where id = pg_temp.v('alice_bar');
  perform pg_temp.ok((select bar_id from public.posts where id = pg_temp.v('post')) is null
    and (select bartender_id from public.posts where id = pg_temp.v('post')) = pg_temp.id('alice'),
    'deleting the bar clears the tag and keeps the post');
end $$;

select pg_temp.admin();
do $$ begin raise notice 'ALL BAR TAG TESTS PASSED'; end $$;
rollback;
