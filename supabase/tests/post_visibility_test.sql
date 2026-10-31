-- The Usual — per-post visibility test suite (migration 0007).
-- Runs in one transaction and ROLLS BACK, so it is safe on a real project:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/post_visibility_test.sql
-- Any failure raises "FAIL: ..." and aborts. Success ends with "ALL VISIBILITY TESTS PASSED".

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

--  alice = bartender, schedule public; bob = bartender, schedule regulars-only
--  rita  = alice's regular; sam = signed-in stranger; tom = alice's regular, then blocked
create temp table ids (name text primary key, id uuid);
grant select on ids to authenticated, anon;
insert into ids values
  ('alice', '00000000-0000-4000-c000-00000000000a'),
  ('bob',   '00000000-0000-4000-c000-00000000000b'),
  ('rita',  '00000000-0000-4000-c000-0000000000c1'),
  ('sam',   '00000000-0000-4000-c000-0000000000c2'),
  ('tom',   '00000000-0000-4000-c000-0000000000c3');
create function pg_temp.id(n text) returns uuid language sql stable as $$ select id from ids where name = n $$;

create temp table t (k text primary key, v uuid);
grant select on t to authenticated, anon;
create function pg_temp.v(k text) returns uuid language sql stable as $$ select v from t where t.k = $1 $$;

insert into auth.users (id, phone) select id, '1555200' || row_number() over () from ids;

do $$
declare v jsonb;
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
  insert into public.bartenders (id, schedule_visibility) values (pg_temp.id('alice'), 'public');
  insert into public.posts (bartender_id, body, photo_path)
    values (pg_temp.id('alice'), 'Regulars post', pg_temp.id('alice') || '/r.webp');
  insert into public.posts (bartender_id, body, photo_path, visibility)
    values (pg_temp.id('alice'), 'Public post', pg_temp.id('alice') || '/p.webp', 'public');
  perform pg_temp.fails(format('insert into public.posts (bartender_id, body, visibility) values (%L, %L, %L)',
    pg_temp.id('alice'), 'x', 'everyone'), 'unknown visibility value refused');

  perform pg_temp.login(pg_temp.id('bob'));
  insert into public.bartenders (id, schedule_visibility) values (pg_temp.id('bob'), 'regulars');
  insert into public.posts (bartender_id, body, visibility) values (pg_temp.id('bob'), 'Bob public post', 'public');

  perform pg_temp.admin();
  insert into t select 'r',  id from public.posts where body = 'Regulars post' and bartender_id = pg_temp.id('alice');
  insert into t select 'p',  id from public.posts where body = 'Public post' and bartender_id = pg_temp.id('alice');
  insert into t select 'bp', id from public.posts where body = 'Bob public post' and bartender_id = pg_temp.id('bob');
  insert into public.connections (bartender_id, regular_id, source) values
    (pg_temp.id('alice'), pg_temp.id('rita'), 'code'),
    (pg_temp.id('alice'), pg_temp.id('tom'),  'code');
  insert into storage.objects (bucket_id, name) values
    ('post-photos', pg_temp.id('alice') || '/r.webp'),
    ('post-photos', pg_temp.id('alice') || '/p.webp');
end $$;

-- ---------- Who sees what ----------
do $$
begin
  perform pg_temp.login(pg_temp.id('alice'));
  perform pg_temp.ok((select visibility from public.posts where id = pg_temp.v('r')) = 'regulars', 'posts default to regulars only');

  perform pg_temp.login(pg_temp.id('rita'));
  perform pg_temp.ok((select count(*) from public.posts where bartender_id = pg_temp.id('alice')) = 2, 'regular sees both kinds of post');

  perform pg_temp.login(pg_temp.id('sam'));
  perform pg_temp.ok((select count(*) from public.posts where bartender_id = pg_temp.id('alice')) = 1, 'stranger sees only the public post');
  perform pg_temp.ok((select id from public.posts where bartender_id = pg_temp.id('alice')) = pg_temp.v('p'), '…and it is the public one');
  perform pg_temp.ok((select count(*) from public.posts where bartender_id = pg_temp.id('bob')) = 0, 'public post hidden while the schedule is regulars-only');
  perform pg_temp.ok((select count(*) from storage.objects where bucket_id = 'post-photos' and name like pg_temp.id('alice') || '/%') = 1, 'stranger sees only the public post''s photo');
  perform pg_temp.ok((select name from storage.objects where bucket_id = 'post-photos') = pg_temp.id('alice') || '/p.webp', '…and it is the public one');

  perform pg_temp.anon();
  perform pg_temp.fails('select * from public.posts', 'anon still cannot read posts');
end $$;

-- ---------- Reactions and replies on a public post ----------
do $$
begin
  perform pg_temp.login(pg_temp.id('rita'));
  perform public.react_to_post(pg_temp.v('p'), 'cheers');

  perform pg_temp.login(pg_temp.id('sam'));
  perform pg_temp.ok((select n from public.post_reaction_counts(array[pg_temp.v('p')]) where reaction = 'cheers') = 1, 'stranger sees counts on a public post');
  perform pg_temp.ok((select not mine from public.post_reaction_counts(array[pg_temp.v('p')]) where reaction = 'cheers'), '…not marked as theirs');
  perform pg_temp.ok((select count(*) from public.post_reactions) = 0, 'stranger still cannot see who reacted');
  perform pg_temp.fails(format('select public.react_to_post(%L, %L)', pg_temp.v('p'), 'love'), 'stranger cannot react to a public post');
  perform pg_temp.fails(format('select public.send_reply(%L, %L)', pg_temp.v('p'), 'hi'), 'stranger cannot reply to a public post');
  perform pg_temp.ok((select count(*) from public.post_reaction_counts(array[pg_temp.v('r')])) = 0, 'no counts for a regulars-only post');
end $$;

-- ---------- Changing visibility ----------
do $$
begin
  perform pg_temp.login(pg_temp.id('rita'));
  update public.posts set visibility = 'public' where id = pg_temp.v('r');
  perform pg_temp.login(pg_temp.id('alice'));
  perform pg_temp.ok((select visibility from public.posts where id = pg_temp.v('r')) = 'regulars', 'regular cannot change a post''s visibility');
  update public.posts set visibility = 'public' where id = pg_temp.v('bp');
  perform pg_temp.login(pg_temp.id('bob'));
  perform pg_temp.ok((select visibility from public.posts where id = pg_temp.v('bp')) = 'public', 'bartender cannot change someone else''s post');

  perform pg_temp.login(pg_temp.id('alice'));
  perform pg_temp.fails(format('update public.posts set body = %L where id = %L', 'edited', pg_temp.v('p')), 'post body still not editable');
  perform pg_temp.fails(format('update public.posts set visibility = %L where id = %L', 'everyone', pg_temp.v('p')), 'unknown visibility value refused on update');
  update public.posts set visibility = 'regulars' where id = pg_temp.v('p');
  perform pg_temp.login(pg_temp.id('sam'));
  perform pg_temp.ok((select count(*) from public.posts) = 0, 'switched to regulars only: stranger loses it');
  perform pg_temp.ok((select count(*) from storage.objects where bucket_id = 'post-photos') = 0, '…and its photo');

  perform pg_temp.login(pg_temp.id('alice'));
  update public.posts set visibility = 'public' where id = pg_temp.v('p');
  update public.bartenders set schedule_visibility = 'regulars' where id = pg_temp.id('alice');
  perform pg_temp.login(pg_temp.id('sam'));
  perform pg_temp.ok((select count(*) from public.posts) = 0, 'schedule set to regulars only: public posts hidden from strangers');
  perform pg_temp.ok((select count(*) from public.post_reaction_counts(array[pg_temp.v('p')])) = 0, '…and their counts');
  perform pg_temp.login(pg_temp.id('alice'));
  update public.bartenders set schedule_visibility = 'public' where id = pg_temp.id('alice');
end $$;

-- ---------- Blocking ----------
do $$
begin
  perform pg_temp.login(pg_temp.id('alice'));
  perform public.block_regular(pg_temp.id('tom'));
  perform pg_temp.login(pg_temp.id('tom'));
  perform pg_temp.ok((select count(*) from public.posts) = 0, 'blocked person sees no posts, public ones included');
  perform pg_temp.ok((select count(*) from storage.objects where bucket_id = 'post-photos') = 0, 'blocked person sees no post photos');
  perform pg_temp.ok((select count(*) from public.post_reaction_counts(array[pg_temp.v('p')])) = 0, 'blocked person sees no counts');
end $$;

select pg_temp.admin();
do $$ begin raise notice 'ALL VISIBILITY TESTS PASSED'; end $$;
rollback;
