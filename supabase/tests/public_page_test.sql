-- The Usual — signed-out public page test suite (migration 0010).
-- Runs in one transaction and ROLLS BACK, so it is safe on a real project:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/public_page_test.sql
-- Any failure raises "FAIL: ..." and aborts. Success ends with "ALL PUBLIC PAGE TESTS PASSED".

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

create function pg_temp.admin() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
end $$;

--  alice = bartender, page public; bob = bartender, page regulars-only; rita = alice's regular
create temp table ids (name text primary key, id uuid);
grant select on ids to authenticated, anon;
insert into ids values
  ('alice', '00000000-0000-4000-d000-00000000000a'),
  ('bob',   '00000000-0000-4000-d000-00000000000b'),
  ('rita',  '00000000-0000-4000-d000-0000000000c1');
create function pg_temp.id(n text) returns uuid language sql stable as $$ select id from ids where name = n $$;

create temp table pids (name text primary key, pid text);
grant select on pids to authenticated, anon;
create function pg_temp.pid(n text) returns text language sql stable as $$ select pid from pids where name = n $$;
create function pg_temp.page(n text) returns json language sql volatile as $$ select public.public_page(pg_temp.pid(n)) $$;

insert into auth.users (id, phone) select id, '1555500' || row_number() over () from ids;

do $$
declare v jsonb; bar uuid; pat uuid; today date;
begin
  foreach v in array array[
    jsonb_build_object('n','alice','d','Alice'), jsonb_build_object('n','bob','d','Bob'),
    jsonb_build_object('n','rita','d','Rita')]
  loop
    perform pg_temp.login(pg_temp.id(v->>'n'));
    insert into public.profiles (id, display_name) values (pg_temp.id(v->>'n'), v->>'d');
  end loop;

  perform pg_temp.login(pg_temp.id('alice'));
  insert into public.bartenders (id, schedule_visibility, bio, photo_path)
    values (pg_temp.id('alice'), 'public', 'Pouring at the Owl', pg_temp.id('alice') || '/me.webp');
  insert into public.bars (bartender_id, name, area) values (pg_temp.id('alice'), 'The Owl', 'Downtown') returning id into bar;
  today := private.bar_day('America/Los_Angeles');
  insert into public.shifts (bartender_id, bar_id, shift_date, start_time, note)
    values (pg_temp.id('alice'), bar, today, '18:00', 'Trivia night'),
           (pg_temp.id('alice'), bar, today + 30, '18:00', 'Too far ahead');
  insert into public.shift_patterns (bartender_id, bar_id, weekdays, start_time, starts_on)
    values (pg_temp.id('alice'), bar, '{1,2,3,4,5,6,7}', '20:00', today) returning id into pat;
  insert into public.shift_exceptions (pattern_id, bartender_id, occurrence_date, cancelled)
    values (pat, pg_temp.id('alice'), today + 1, true);
  insert into public.posts (bartender_id, body, photo_path)
    values (pg_temp.id('alice'), 'Regulars post', pg_temp.id('alice') || '/r.webp');
  insert into public.posts (bartender_id, body, photo_path, visibility)
    values (pg_temp.id('alice'), 'Public post', pg_temp.id('alice') || '/p.webp', 'public');

  perform pg_temp.login(pg_temp.id('bob'));
  insert into public.bartenders (id, schedule_visibility, photo_path)
    values (pg_temp.id('bob'), 'regulars', pg_temp.id('bob') || '/me.webp');
  insert into public.posts (bartender_id, body, photo_path, visibility)
    values (pg_temp.id('bob'), 'Bob public post', pg_temp.id('bob') || '/p.webp', 'public');

  perform pg_temp.admin();
  insert into pids select 'alice', public_id from public.bartenders where id = pg_temp.id('alice');
  insert into pids select 'bob',   public_id from public.bartenders where id = pg_temp.id('bob');
  insert into public.connections (bartender_id, regular_id, source) values (pg_temp.id('alice'), pg_temp.id('rita'), 'code');
  insert into storage.objects (bucket_id, name) values
    ('avatars',     pg_temp.id('alice') || '/me.webp'),
    ('avatars',     pg_temp.id('bob')   || '/me.webp'),
    ('post-photos', pg_temp.id('alice') || '/r.webp'),
    ('post-photos', pg_temp.id('alice') || '/p.webp'),
    ('post-photos', pg_temp.id('bob')   || '/p.webp');
end $$;

-- ---------- Signed out: the public page ----------
do $$
declare pg json;
begin
  perform pg_temp.anon();
  pg := pg_temp.page('alice');
  perform pg_temp.ok(pg is not null, 'signed-out visitor can open a public page');
  perform pg_temp.ok(pg->>'display_name' = 'Alice', '…sees the name');
  perform pg_temp.ok(pg->>'bio' = 'Pouring at the Owl', '…the bio');
  perform pg_temp.ok(json_array_length(pg->'bars') = 1 and pg->'bars'->0->>'name' = 'The Owl', '…the bars');
  perform pg_temp.ok(json_array_length(pg->'posts') = 1, '…exactly one post');
  perform pg_temp.ok(pg->'posts'->0->>'body' = 'Public post', '…and it is the public one');
  perform pg_temp.ok(exists (select 1 from json_array_elements(pg->'shifts') s where s->>'note' = 'Trivia night'), '…tonight''s one-off shift');
  perform pg_temp.ok(not exists (select 1 from json_array_elements(pg->'shifts') s where s->>'note' = 'Too far ahead'), '…nothing beyond two weeks');
  perform pg_temp.ok(not exists (select 1 from json_array_elements(pg->'shifts') s
                                  where (s->>'occurrence_date')::date = (pg->>'today')::date + 1), '…no cancelled nights');
  perform pg_temp.ok((select count(*) from json_array_elements(pg->'shifts')) = 14, '…13 weekly nights plus the one-off');
  perform pg_temp.ok(pg::text not like '%' || pg_temp.id('rita') || '%', '…no trace of who follows them');
  perform pg_temp.ok(pg::text not like '%1555%', '…no phone numbers');
  perform pg_temp.ok(pg->>'id' is null, '…no internal account id');

  perform pg_temp.ok(pg_temp.page('bob') is null, 'regulars-only page returns nothing');
  perform pg_temp.ok(public.public_page('nope-not-real') is null, 'unknown link returns nothing');
  perform pg_temp.ok(public.public_page(null) is null, 'empty link returns nothing');
end $$;

-- ---------- Signed out: no table access, no listing ----------
do $$
begin
  perform pg_temp.anon();
  perform pg_temp.fails('select * from public.bartenders', 'cannot list bartenders');
  perform pg_temp.fails('select * from public.profiles', 'cannot read profiles');
  perform pg_temp.fails('select * from public.posts', 'cannot read posts');
  perform pg_temp.fails('select * from public.bars', 'cannot read bars');
  perform pg_temp.fails('select * from public.shifts', 'cannot read shifts');
  perform pg_temp.fails('select * from public.connections', 'cannot read connections');
  perform pg_temp.fails(format('select * from public.get_schedule(array[%L]::uuid[], current_date, current_date + 7)', pg_temp.id('alice')),
    'cannot call get_schedule directly');
  perform pg_temp.fails(format('select * from public.post_reaction_counts(array[%L]::uuid[])', pg_temp.id('alice')),
    'cannot see reaction counts');
end $$;

-- ---------- Signed out: photos ----------
do $$
begin
  perform pg_temp.anon();
  perform pg_temp.ok((select count(*) from storage.objects where bucket_id = 'avatars') = 1, 'sees one avatar');
  perform pg_temp.ok((select name from storage.objects where bucket_id = 'avatars') = pg_temp.id('alice') || '/me.webp', '…the public page''s');
  perform pg_temp.ok((select count(*) from storage.objects where bucket_id = 'post-photos') = 1, 'sees one post photo');
  perform pg_temp.ok((select name from storage.objects where bucket_id = 'post-photos') = pg_temp.id('alice') || '/p.webp', '…the public post''s');
end $$;

-- ---------- Signed in: unchanged ----------
do $$
begin
  perform pg_temp.login(pg_temp.id('rita'));
  perform pg_temp.fails(format('select public.public_page(%L)', pg_temp.pid('alice')), 'signed-in users use the normal page, not this function');
  perform pg_temp.ok((select count(*) from public.posts where bartender_id = pg_temp.id('alice')) = 2, 'regular still sees both posts');
end $$;

-- ---------- Turning the page private ----------
do $$
begin
  perform pg_temp.login(pg_temp.id('alice'));
  update public.bartenders set schedule_visibility = 'regulars' where id = pg_temp.id('alice');
  perform pg_temp.anon();
  perform pg_temp.ok(pg_temp.page('alice') is null, 'page set to regulars only: signed-out visitor sees nothing');
  perform pg_temp.ok((select count(*) from storage.objects) = 0, '…and no photos');

  perform pg_temp.login(pg_temp.id('alice'));
  update public.bartenders set schedule_visibility = 'public' where id = pg_temp.id('alice');
  update public.posts set visibility = 'regulars' where bartender_id = pg_temp.id('alice');
  perform pg_temp.anon();
  perform pg_temp.ok(json_array_length(pg_temp.page('alice')->'posts') = 0, 'post switched to regulars: gone from the page');
  perform pg_temp.ok((select count(*) from storage.objects where bucket_id = 'post-photos') = 0, '…and its photo');
end $$;

select pg_temp.admin();
do $$ begin raise notice 'ALL PUBLIC PAGE TESTS PASSED'; end $$;
rollback;
