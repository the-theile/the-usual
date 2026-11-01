-- The Usual — reports, moderator tools and metrics test suite (migration 0011).
-- Runs in one transaction and ROLLS BACK, so it is safe on a real project:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/moderation_test.sql
-- Any failure raises "FAIL: ..." and aborts. Success ends with "ALL MODERATION TESTS PASSED".

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

--  alice = bartender (regulars-only schedule); rita = alice's regular
--  bob   = bartender with a public schedule;   una  = follows nobody
--  mo    = moderator
create temp table ids (name text primary key, id uuid);
grant select on ids to authenticated, anon;
insert into ids values
  ('alice', '00000000-0000-4000-e100-00000000000a'),
  ('bob',   '00000000-0000-4000-e100-00000000000b'),
  ('rita',  '00000000-0000-4000-e100-0000000000c1'),
  ('una',   '00000000-0000-4000-e100-0000000000c4'),
  ('mo',    '00000000-0000-4000-e100-0000000000d1');
create function pg_temp.id(n text) returns uuid language sql stable as $$ select id from ids where name = n $$;

create temp table t (k text primary key, v uuid);
grant select, insert, update on t to authenticated;
create function pg_temp.v(k text) returns uuid language sql stable as $$ select v from t where t.k = $1 $$;

insert into auth.users (id, phone) select id, '1555500' || row_number() over () from ids;

do $$
declare v_post uuid := gen_random_uuid(); v_pub uuid := gen_random_uuid(); v_reply uuid := gen_random_uuid(); v_mine uuid := gen_random_uuid();
begin
  perform pg_temp.admin();
  insert into public.profiles (id, display_name) select id, initcap(name) from ids;
  insert into public.bartenders (id, bio) values (pg_temp.id('alice'), 'Tiki nights');
  insert into public.bartenders (id, schedule_visibility) values (pg_temp.id('bob'), 'public');
  insert into public.connections (bartender_id, regular_id, source) values (pg_temp.id('alice'), pg_temp.id('rita'), 'qr');
  insert into public.posts (id, bartender_id, body, photo_path) values (v_post, pg_temp.id('alice'), 'Tonight: mai tais', pg_temp.id('alice') || '/x.jpg');
  insert into public.posts (id, bartender_id, body, visibility) values (v_pub, pg_temp.id('bob'), 'Quiz night', 'public');
  insert into public.post_replies (id, post_id, bartender_id, regular_id, author_id, body) values
    (v_reply, v_post, pg_temp.id('alice'), pg_temp.id('rita'), pg_temp.id('alice'), 'Rude reply'),
    (v_mine,  v_post, pg_temp.id('alice'), pg_temp.id('rita'), pg_temp.id('rita'),  'My own message');
  insert into private.moderators (user_id) values (pg_temp.id('mo'));
  insert into auth.sessions (id, user_id) values (gen_random_uuid(), pg_temp.id('rita'));
  insert into t values ('post', v_post), ('pub', v_pub), ('reply', v_reply), ('mine', v_mine);
end $$;

-- ---------- Reporting: only what you can see ----------
do $$
begin
  perform pg_temp.login(pg_temp.id('rita'));
  perform public.report('post', pg_temp.v('post'), 'inappropriate', '  not ok  ');
  perform public.report('reply', pg_temp.v('reply'), 'harassment');
  perform public.report('person', pg_temp.id('alice'), 'harassment');
  perform public.report('post', pg_temp.v('post'), 'spam');   -- duplicate while open: no-op
  perform pg_temp.fails($q$select public.report('reply', pg_temp.v('mine'), 'spam')$q$, 'cannot report your own message');
  perform pg_temp.fails($q$select public.report('person', pg_temp.id('rita'), 'spam')$q$, 'cannot report yourself');
  perform pg_temp.fails($q$select public.report('person', pg_temp.id('una'), 'spam')$q$, 'cannot report a stranger');
  perform pg_temp.fails($q$select public.report('post', pg_temp.v('post'), 'meh')$q$, 'unknown reason is refused');
  perform pg_temp.fails($q$select public.report('thing', pg_temp.v('post'), 'spam')$q$, 'unknown kind is refused');
  perform pg_temp.fails($q$select public.report('post', pg_temp.v('post'), 'other', repeat('x', 501))$q$, 'details over 500 chars are refused');
  perform pg_temp.fails('select count(*) from private.reports', 'a regular cannot read reports');
  perform pg_temp.ok(public.am_i_moderator() = false, 'a regular is not a moderator');
  perform pg_temp.fails('select * from public.mod_reports()', 'a regular cannot list reports');
  perform pg_temp.fails('select public.mod_metrics()', 'a regular cannot see metrics');
  perform pg_temp.fails($q$select public.mod_suspend(pg_temp.id('una'))$q$, 'a regular cannot suspend anyone');
  perform pg_temp.fails('select private.suspend_user(pg_temp.id(''una''), null, '''')', 'the suspend helper is not callable directly');

  perform pg_temp.login(pg_temp.id('una'));
  perform pg_temp.fails($q$select public.report('post', pg_temp.v('post'), 'spam')$q$, 'non-regular cannot report a regulars-only post');
  perform pg_temp.fails($q$select public.report('reply', pg_temp.v('reply'), 'spam')$q$, 'outsider cannot report someone else''s conversation');
  perform pg_temp.fails($q$select public.report('person', pg_temp.id('rita'), 'spam')$q$, 'outsider cannot report a regular');
  perform public.report('post', pg_temp.v('pub'), 'spam');
  perform public.report('person', pg_temp.id('bob'), 'impersonation');

  perform pg_temp.login(pg_temp.id('alice'));
  perform public.report('person', pg_temp.id('rita'), 'safety', 'Threatened staff');
  perform public.report('reply', pg_temp.v('mine'), 'harassment');
  perform pg_temp.fails($q$select public.report('post', pg_temp.v('post'), 'spam')$q$, 'cannot report your own post');

  perform pg_temp.admin();
  perform pg_temp.ok((select count(*) from private.reports) = 7, 'seven distinct reports were filed (the duplicate was ignored)');
  perform pg_temp.ok((select details from private.reports where kind = 'post' and reporter_id = pg_temp.id('rita')) = 'not ok', 'details are trimmed');
  perform pg_temp.ok((select snapshot_body = 'Tonight: mai tais' and snapshot_photo = pg_temp.id('alice') || '/x.jpg'
                        from private.reports where kind = 'post' and target_id = pg_temp.v('post')), 'post text and photo are snapshotted');
  perform pg_temp.ok((select reported_user_id = pg_temp.id('alice') from private.reports where kind = 'reply' and target_id = pg_temp.v('reply')), 'a reply report points at its author');
  perform pg_temp.ok((select snapshot_body from private.reports where kind = 'person' and target_id = pg_temp.id('alice')) = 'Tiki nights', 'a bartender report keeps their bio');
end $$;

-- ---------- Rate limit ----------
do $$
begin
  perform pg_temp.admin();
  insert into private.reports (reporter_id, reported_user_id, kind, target_id, reason)
    select pg_temp.id('una'), pg_temp.id('bob'), 'person', gen_random_uuid(), 'spam' from generate_series(1, 18);
  perform pg_temp.login(pg_temp.id('una'));
  perform pg_temp.fails($q$select public.report('person', pg_temp.id('bob'), 'other', 'again')$q$, 'more than 20 reports a day is refused');
  perform pg_temp.admin();
  delete from private.reports where reporter_id = pg_temp.id('una') and kind = 'person' and target_id <> pg_temp.id('bob');
end $$;

-- ---------- Moderator: queue and photo access ----------
do $$
begin
  perform pg_temp.login(pg_temp.id('mo'));
  perform pg_temp.ok(public.am_i_moderator(), 'mo is a moderator');
  perform pg_temp.ok((select count(*) from public.mod_reports('open')) = 7, 'moderator sees every open report');
  perform pg_temp.ok((select reports_against from public.mod_reports('open') where kind = 'person' and reported_user_id = pg_temp.id('alice')) = 3,
                     'each report shows how many reports the person has against them');
  perform pg_temp.ok((select reporter_name from public.mod_reports('open') where kind = 'post' and reported_user_id = pg_temp.id('alice')) = 'Rita',
                     'moderator sees who reported');
  perform pg_temp.ok(private.is_reported_photo(pg_temp.id('alice') || '/x.jpg'), 'reported photo is viewable by moderators');
  perform pg_temp.ok(not private.is_reported_photo(pg_temp.id('bob') || '/y.jpg'), 'unreported photos are not');
  perform pg_temp.ok((select (public.mod_metrics() -> 'safety' ->> 'reports_open')::int) = 7, 'metrics count open reports');
  perform pg_temp.ok((select json_array_length(public.mod_metrics() -> 'daily')) = 14, 'metrics include 14 days');
  perform pg_temp.ok((select (public.mod_metrics() -> 'bartender_funnel' ->> 'has_regular')::int) = 1, 'funnel counts bartenders with a regular');
  perform pg_temp.ok((select (public.mod_metrics() -> 'posts' ->> 'with_response_30d')::int) = 1, 'a post with a regular''s reply counts as responded');
end $$;

-- ---------- Moderator: remove, suspend, dismiss ----------
do $$
declare v_r uuid;
begin
  perform pg_temp.login(pg_temp.id('mo'));

  select id into v_r from public.mod_reports('open') where kind = 'post' and reported_user_id = pg_temp.id('alice');
  perform public.mod_resolve(v_r, p_remove => true, p_note => 'Not allowed');
  perform pg_temp.admin();
  perform pg_temp.ok(not exists (select 1 from public.posts where id = pg_temp.v('post')), 'remove deletes the post');
  perform pg_temp.ok((select status from private.reports where id = v_r) = 'actioned', '…the report is actioned');
  perform pg_temp.ok((select snapshot_body from private.reports where id = v_r) = 'Tonight: mai tais', '…and the evidence is kept');
  perform pg_temp.ok((select status from private.reports where kind = 'reply' and target_id = pg_temp.v('reply')) = 'open',
                     'reports about other things stay open (the reply was deleted with the post, its report remains)');

  perform pg_temp.login(pg_temp.id('mo'));
  perform pg_temp.fails(format('select public.mod_resolve(%L, true)', v_r), 'a resolved report cannot be resolved again');

  select id into v_r from public.mod_reports('open') where kind = 'person' and reported_user_id = pg_temp.id('rita');
  perform pg_temp.fails(format('select public.mod_resolve(%L, p_remove => true)', v_r), 'a person cannot be "removed"');
  perform public.mod_resolve(v_r, p_suspend => true, p_days => 7, p_note => 'Threats');
  perform pg_temp.admin();
  perform pg_temp.ok((select banned_until between now() + interval '6 days' and now() + interval '8 days' from auth.users where id = pg_temp.id('rita')),
                     'suspend bans sign-in for the chosen days');
  perform pg_temp.ok(not exists (select 1 from auth.sessions where user_id = pg_temp.id('rita')), '…and ends their sessions');
  perform pg_temp.ok(exists (select 1 from private.suspensions where user_id = pg_temp.id('rita')), '…and is listed as suspended');

  perform pg_temp.login(pg_temp.id('mo'));
  perform pg_temp.ok((select count(*) from public.mod_suspended()) = 1, 'moderator sees the suspension');
  perform pg_temp.fails($q$select public.mod_suspend(pg_temp.id('mo'))$q$, 'a moderator cannot suspend themselves');
  perform public.mod_unsuspend(pg_temp.id('rita'));
  perform pg_temp.admin();
  perform pg_temp.ok((select banned_until is null from auth.users where id = pg_temp.id('rita')), 'unsuspend lifts the ban');

  perform pg_temp.login(pg_temp.id('mo'));
  select id into v_r from public.mod_reports('open') where kind = 'person' and reported_user_id = pg_temp.id('bob');
  perform public.mod_resolve(v_r, p_note => 'Is the real Bob');
  perform pg_temp.ok((select status from public.mod_reports('closed') where id = v_r) = 'dismissed', 'neither action = dismissed');
  perform pg_temp.ok((select count(*) from public.mod_log()) = 4, 'every action is in the log (remove, suspend, unsuspend, dismiss)');
end $$;

-- ---------- Account deletion keeps the record ----------
do $$
begin
  perform pg_temp.login(pg_temp.id('una'));
  perform public.delete_my_account();
  perform pg_temp.admin();
  perform pg_temp.ok((select count(*) from private.reports where reporter_id is null) = 2, 'a deleted reporter''s reports remain, unattributed');
end $$;

select pg_temp.admin();
do $$ begin raise notice 'ALL MODERATION TESTS PASSED'; end $$;
rollback;
