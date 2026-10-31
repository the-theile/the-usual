-- The Usual — privacy & RLS test suite.
-- Runs in one transaction and ROLLS BACK, so it is safe on a real project:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/privacy_test.sql
-- Any failure raises "FAIL: ..." and aborts. Success ends with "ALL PRIVACY TESTS PASSED".

begin;

create function pg_temp.ok(c boolean, msg text) returns void language plpgsql as $$
begin
  if c is not true then raise exception 'FAIL: %', msg; end if;
  raise notice 'ok - %', msg;
end $$;

-- Expect a statement to error (permission / RLS / constraint).
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

-- Fixed ids for readability
--  alice  = bartender, schedule "regulars only"
--  bob    = bartender, schedule "public"
--  rita   = regular connected to alice
--  sam    = signed-in stranger
--  tom    = regular of alice and bob, then blocked by both
create temp table ids (name text primary key, id uuid);
grant select on ids to authenticated, anon;
insert into ids values
  ('alice', '00000000-0000-4000-a000-00000000000a'),
  ('bob',   '00000000-0000-4000-a000-00000000000b'),
  ('rita',  '00000000-0000-4000-a000-0000000000c1'),
  ('sam',   '00000000-0000-4000-a000-0000000000c2'),
  ('tom',   '00000000-0000-4000-a000-0000000000c3');
create function pg_temp.id(n text) returns uuid language sql stable as $$ select id from ids where name = n $$;

insert into auth.users (id, phone) select id, '1555000' || row_number() over () from ids;

-- ---------- Setup through the API roles ----------
do $$
declare v jsonb; bar uuid; bob_bar uuid; pat uuid;
begin
  foreach v in array array[
    jsonb_build_object('n','alice','d','Alice'), jsonb_build_object('n','bob','d','Bob'),
    jsonb_build_object('n','rita','d','Rita'),   jsonb_build_object('n','sam','d','Sam'),
    jsonb_build_object('n','tom','d','Tom')]
  loop
    perform pg_temp.login(pg_temp.id(v->>'n'));
    insert into public.profiles (id, display_name) values (pg_temp.id(v->>'n'), v->>'d');
  end loop;

  perform pg_temp.login(pg_temp.id('alice'));
  insert into public.bartenders (id, bio, timezone) values (pg_temp.id('alice'), 'Tiki nights', 'America/New_York');
  insert into public.bars (bartender_id, name, area) values (pg_temp.id('alice'), 'Tiki Bar', 'Northside') returning id into bar;
  insert into public.shift_patterns (bartender_id, bar_id, weekdays, start_time, end_time, starts_on)
    values (pg_temp.id('alice'), bar, '{1,2,3,4,5,6,7}', '18:00', null, current_date - 7) returning id into pat;
  insert into public.posts (bartender_id, body) values (pg_temp.id('alice'), 'Mai tai special');
  insert into storage.objects (bucket_id, name) values ('avatars', pg_temp.id('alice') || '/a.webp'),
                                                       ('post-photos', pg_temp.id('alice') || '/p.webp');

  perform pg_temp.login(pg_temp.id('bob'));
  insert into public.bartenders (id, timezone, schedule_visibility) values (pg_temp.id('bob'), 'America/Chicago', 'public');
  insert into public.bars (bartender_id, name) values (pg_temp.id('bob'), 'The Anchor') returning id into bob_bar;
  insert into public.shifts (bartender_id, bar_id, shift_date, start_time, end_time)
    values (pg_temp.id('bob'), bob_bar, current_date + 1, '20:00', '02:00');
  insert into public.posts (bartender_id, body) values (pg_temp.id('bob'), 'Bob post, regulars only');
  insert into storage.objects (bucket_id, name) values ('avatars', pg_temp.id('bob') || '/b.webp'),
                                                       ('post-photos', pg_temp.id('bob') || '/bp.webp');
end $$;

-- ---------- Invites ----------
create temp table t (k text primary key, v text);
grant all on t to authenticated, anon;

do $$
declare j json; j2 json;
begin
  perform pg_temp.login(pg_temp.id('alice'));
  j := public.get_today_invite();
  perform pg_temp.ok((j->>'code') ~ '^[A-Z]{3,6}-[A-Z]{3,6}-[1-9][0-9]$', 'daily code looks like WORD-WORD-NN: ' || (j->>'code'));
  perform pg_temp.ok((j->>'token') ~ '^[0-9a-f]{32}$', 'QR token is 32 hex chars');
  perform pg_temp.ok((j->>'expires_at')::timestamptz between now() and now() + interval '25 hours', 'daily code expires at next 5am');
  j2 := public.get_today_invite();
  perform pg_temp.ok(j2->>'code' = j->>'code', 'same code all bar day');
  insert into t values ('code', j->>'code'), ('qr', j->>'token');
  insert into t values ('link', public.create_invite_link()->>'token');

  perform pg_temp.login(pg_temp.id('bob'));
  insert into t values ('bobcode', public.get_today_invite()->>'code');
end $$;

do $$
declare j json;
begin
  -- rita joins alice with the spoken code, typed sloppily
  perform pg_temp.login(pg_temp.id('rita'));
  j := public.redeem_invite('  ' || lower(replace((select v from t where k='code'), '-', ' ')) || ' ');
  perform pg_temp.ok((j->>'ok')::boolean and j->>'display_name' = 'Alice', 'code works lower-case with spaces');
  perform pg_temp.ok((select source from public.connections where regular_id = pg_temp.id('rita')) = 'code', 'source=code');

  -- tom joins alice by link and bob by code
  perform pg_temp.login(pg_temp.id('tom'));
  j := public.redeem_invite((select v from t where k='link'));
  perform pg_temp.ok((j->>'ok')::boolean, 'link works');
  j := public.redeem_invite((select v from t where k='bobcode'));
  perform pg_temp.ok((j->>'ok')::boolean, 'tom joins bob');

  -- alice cannot join herself
  perform pg_temp.login(pg_temp.id('alice'));
  perform pg_temp.ok(public.redeem_invite((select v from t where k='code'))->>'reason' = 'self', 'cannot follow yourself');

  -- anon preview of the QR token shows only the name
  perform pg_temp.anon();
  j := public.preview_invite((select v from t where k='qr'));
  perform pg_temp.ok((j->>'ok')::boolean and j->>'display_name' = 'Alice', 'anon can preview a live token');
  perform pg_temp.ok((public.preview_invite('0123456789abcdef0123456789abcdef')->>'ok')::boolean = false, 'bad token previews nothing');
end $$;

-- anon has no table access at all
select pg_temp.anon();
select pg_temp.fails('select * from public.profiles', 'anon cannot read profiles');
select pg_temp.fails('select * from public.posts', 'anon cannot read posts');
select pg_temp.fails('select public.redeem_invite(''x'')', 'anon cannot redeem');

-- ---------- Blocking ----------
do $$
begin
  perform pg_temp.login(pg_temp.id('alice'));
  perform public.block_regular(pg_temp.id('tom'));
  perform public.block_regular(pg_temp.id('sam'));  -- never a regular: silent no-op
  perform pg_temp.ok((select count(*) from public.blocks) = 1, 'block only applies to own regulars');
  perform pg_temp.login(pg_temp.id('bob'));
  perform public.block_regular(pg_temp.id('tom'));
end $$;

-- ---------- What each person can see ----------
do $$
declare
  alice uuid := pg_temp.id('alice'); bob uuid := pg_temp.id('bob');
begin
  -- rita (connected to alice)
  perform pg_temp.login(pg_temp.id('rita'));
  perform pg_temp.ok((select count(*) from public.posts where bartender_id = alice) = 1, 'rita sees alice posts');
  perform pg_temp.ok((select count(*) from public.bartenders where id = alice) = 1, 'rita sees alice profile');
  perform pg_temp.ok((select count(*) from public.get_schedule(array[alice], current_date, current_date + 6)) = 7, 'rita sees alice schedule');
  perform pg_temp.ok((select count(distinct bartender_id) from public.whos_working_tonight()) = 1, 'rita: who''s working tonight = alice');
  perform pg_temp.ok((select count(*) from public.profiles) = 3, 'rita sees self + alice + bob(public), not other regulars');
  perform pg_temp.ok(not exists (select 1 from public.profiles where id in (pg_temp.id('tom'), pg_temp.id('sam'))), 'rita cannot see other regulars');
  perform pg_temp.ok((select count(*) from public.blocks) = 0, 'rita sees no blocks');
  perform pg_temp.ok((select count(*) from public.invites) = 0, 'rita sees no invite codes');
  perform pg_temp.ok((select count(*) from storage.objects where name like alice || '/%') = 2, 'rita sees alice photos');
  perform pg_temp.ok((select count(*) from public.posts where bartender_id = bob) = 0, 'rita cannot see bob posts (public schedule only)');
  perform pg_temp.ok((select count(*) from public.get_schedule(array[bob], current_date, current_date + 6)) = 1, 'rita sees bob public schedule');

  -- sam (signed-in stranger)
  perform pg_temp.login(pg_temp.id('sam'));
  perform pg_temp.ok((select count(*) from public.bartenders where id = alice) = 0, 'stranger cannot see regulars-only bartender');
  perform pg_temp.ok((select count(*) from public.get_schedule(array[alice], current_date, current_date + 6)) = 0, 'stranger cannot see regulars-only schedule');
  perform pg_temp.ok((select count(*) from public.bars where bartender_id = alice) = 0, 'stranger cannot see alice bars');
  perform pg_temp.ok((select count(*) from public.get_schedule(array[bob], current_date, current_date + 6)) = 1, 'stranger sees public schedule');
  perform pg_temp.ok((select count(*) from public.posts) = 0, 'stranger sees no posts');
  perform pg_temp.ok((select count(*) from storage.objects) = 1, 'stranger sees only bob avatar');

  -- tom (blocked by both)
  perform pg_temp.login(pg_temp.id('tom'));
  perform pg_temp.ok((select count(*) from public.connections) = 0, 'blocked: connections gone');
  perform pg_temp.ok((select count(*) from public.bartenders) = 0, 'blocked: no bartender profiles, even public one');
  perform pg_temp.ok((select count(*) from public.profiles where id in (alice, bob)) = 0, 'blocked: no names');
  perform pg_temp.ok((select count(*) from public.posts) = 0, 'blocked: no posts');
  perform pg_temp.ok((select count(*) from public.get_schedule(array[alice, bob], current_date, current_date + 6)) = 0, 'blocked: no schedule, even public');
  perform pg_temp.ok((select count(*) from storage.objects) = 0, 'blocked: no photos');
  perform pg_temp.ok((select count(*) from public.blocks) = 0, 'blocked: cannot see blocks table');
  perform pg_temp.ok((select count(*) from public.whos_working_tonight()) = 0, 'blocked: home screen empty');
  perform pg_temp.ok(public.redeem_invite((select v from t where k='code'))->>'reason' = 'not_valid', 'blocked: code looks merely invalid');
  perform pg_temp.ok(public.redeem_invite((select v from t where k='link'))->>'reason' = 'not_valid', 'blocked: link looks merely invalid');
  perform pg_temp.ok((public.preview_invite((select v from t where k='qr'))->>'ok')::boolean = false, 'blocked: QR preview shows nothing');

  -- alice sees her regulars + blocked list
  perform pg_temp.login(alice);
  perform pg_temp.ok((select count(*) from public.my_regulars() where not blocked) = 1, 'alice: 1 regular');
  perform pg_temp.ok((select display_name from public.my_regulars() where blocked) = 'Tom', 'alice: tom in blocked list');
  perform pg_temp.ok((select count(*) from public.profiles where id = pg_temp.id('sam')) = 0, 'alice cannot see random users');
end $$;

-- ---------- Writes that must be refused ----------
select pg_temp.login(pg_temp.id('rita'));
select pg_temp.fails($$insert into public.connections (bartender_id, regular_id, source) values ('00000000-0000-4000-a000-00000000000b', auth.uid(), 'code')$$, 'cannot self-insert a connection');
select pg_temp.fails($$update public.connections set messaging_enabled = true$$, 'regular cannot enable messaging');
select pg_temp.fails($$insert into public.posts (bartender_id, body) values ('00000000-0000-4000-a000-00000000000a', 'fake')$$, 'cannot post as someone else');
select pg_temp.fails($$insert into public.blocks values ('00000000-0000-4000-a000-00000000000a', auth.uid())$$, 'cannot write blocks directly');
select pg_temp.fails($$select * from private.invite_attempts$$, 'cannot read attempts');
select pg_temp.fails($$insert into storage.objects (bucket_id, name) values ('avatars', '00000000-0000-4000-a000-00000000000a/x.webp')$$, 'cannot upload into another folder');
select pg_temp.fails($$select public.get_today_invite()$$, 'regular has no invite code');
select pg_temp.ok((select count(*) from public.connections where regular_id = auth.uid()) = 1, 'rita still connected');

select pg_temp.login(pg_temp.id('alice'));
select pg_temp.fails($$update public.bartenders set public_id = 'aaaaaaaaaa'$$, 'public_id is not client-writable');
select pg_temp.fails($$insert into public.shifts (bartender_id, bar_id, shift_date, start_time) select auth.uid(), id, current_date, '18:00' from public.bars where name = 'The Anchor'$$, 'cannot schedule at another bartender''s bar');
select pg_temp.fails($$update public.bartenders set photo_path = '00000000-0000-4000-a000-00000000000b/b.webp'$$, 'cannot point photo at another folder');
do $$ begin
  update public.posts set body = 'x';
  perform pg_temp.ok((select body from public.posts limit 1) = 'Mai tai special', 'posts are not editable');
exception when insufficient_privilege then perform pg_temp.ok(true, 'posts are not editable');
end $$;

-- ---------- Exceptions to repeating shifts ----------
do $$
declare pat uuid; d date;
begin
  perform pg_temp.login(pg_temp.id('alice'));
  select id into pat from public.shift_patterns;
  d := public.bar_today(pg_temp.id('alice'));
  insert into public.shift_exceptions (pattern_id, bartender_id, occurrence_date, cancelled)
    values (pat, pg_temp.id('alice'), d, true);
  insert into public.shift_exceptions (pattern_id, bartender_id, occurrence_date, bar_id, start_time, end_time)
    select pat, pg_temp.id('alice'), d + 1, bar_id, '20:00', '23:00' from public.shift_patterns where id = pat;
  perform pg_temp.ok((select cancelled from public.get_schedule(array[pg_temp.id('alice')], d, d)), 'owner sees cancelled night');

  perform pg_temp.login(pg_temp.id('rita'));
  perform pg_temp.ok((select count(*) from public.get_schedule(array[pg_temp.id('alice')], d, d)) = 0, 'regular does not see cancelled night');
  perform pg_temp.ok((select bar_name from public.whos_working_tonight()) is null, 'cancelled tonight -> "off tonight"');
  perform pg_temp.ok((select start_time from public.get_schedule(array[pg_temp.id('alice')], d + 1, d + 1)) = '20:00', 'changed night shows new time');
  perform pg_temp.ok((select end_time from public.get_schedule(array[pg_temp.id('alice')], d + 2, d + 2)) is null, 'untouched nights stay "until close"');
end $$;

-- ---------- Rate limiting ----------
do $$
declare i int;
begin
  perform pg_temp.login(pg_temp.id('sam'));
  for i in 1..5 loop
    perform pg_temp.ok(public.redeem_invite('WRONG-CODE-' || i)->>'reason' = 'not_valid', 'wrong code ' || i);
  end loop;
  perform pg_temp.ok(public.redeem_invite((select v from t where k='code'))->>'reason' = 'too_many_tries', 'locked out after 5 misses, even with the right code');
end $$;

-- ---------- Reset invites ----------
do $$
declare j json;
begin
  perform pg_temp.login(pg_temp.id('alice'));
  perform public.reset_invites();
  j := public.get_today_invite();
  perform pg_temp.ok(j->>'code' <> (select v from t where k='code'), 'reset gives a new code');
  perform pg_temp.admin();
  delete from private.invite_attempts where user_id in (select id from ids);
  perform pg_temp.login(pg_temp.id('sam'));
  perform pg_temp.ok(public.redeem_invite((select v from t where k='code'))->>'reason' = 'not_valid', 'old code dead after reset');
  perform pg_temp.ok(public.redeem_invite((select v from t where k='link'))->>'reason' = 'not_valid', 'old link dead after reset');
  perform pg_temp.ok((public.redeem_invite(j->>'code')->>'ok')::boolean, 'new code works');
end $$;

-- ---------- Expiry ----------
do $$
begin
  perform pg_temp.admin();
  delete from private.invite_attempts where user_id in (select id from ids);
  delete from public.connections where regular_id = pg_temp.id('sam');
  insert into t select 'expired', code from public.invites
   where kind = 'daily' and revoked_at is null and bartender_id = pg_temp.id('alice');
  update public.invites set expires_at = now() - interval '1 second'
   where kind = 'daily' and revoked_at is null and bartender_id = pg_temp.id('alice');
  perform pg_temp.login(pg_temp.id('sam'));
  perform pg_temp.ok(public.redeem_invite((select v from t where k = 'expired'))->>'reason' = 'not_valid', 'expired (yesterday''s) code refused');
end $$;

select pg_temp.admin();
do $$ begin raise notice 'ALL PRIVACY TESTS PASSED'; end $$;
rollback;
