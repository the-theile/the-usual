-- The Usual — App Store review safety test suite (migration 0014).
-- Runs in one transaction and ROLLS BACK, so it is safe on a real project:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/app_review_safety_test.sql
-- Any failure raises "FAIL: ..." and aborts. Success ends with "ALL APP REVIEW SAFETY TESTS PASSED".

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

--  alice = bartender (public schedule); rita = alice's regular
--  bob   = bartender (regulars-only schedule); una = bob's regular
create temp table ids (name text primary key, id uuid);
grant select on ids to authenticated, anon;
insert into ids values
  ('alice', '00000000-0000-4000-f000-00000000000a'),
  ('bob',   '00000000-0000-4000-f000-00000000000b'),
  ('rita',  '00000000-0000-4000-f000-0000000000c1'),
  ('una',   '00000000-0000-4000-f000-0000000000c4');
create function pg_temp.id(n text) returns uuid language sql stable as $$ select id from ids where name = n $$;

insert into auth.users (id, phone) select id, '1555500' || row_number() over () from ids;

do $$
begin
  perform pg_temp.admin();
  insert into public.profiles (id, display_name) select id, initcap(name) from ids;
  insert into public.bartenders (id, schedule_visibility) values
    (pg_temp.id('alice'), 'public'), (pg_temp.id('bob'), 'regulars');
  insert into public.bars (bartender_id, name) values (pg_temp.id('alice'), 'Tiki Moon');
  insert into public.connections (bartender_id, regular_id, source) values
    (pg_temp.id('alice'), pg_temp.id('rita'), 'code'),
    (pg_temp.id('bob'),   pg_temp.id('una'),  'code');
  insert into public.posts (bartender_id, body) values (pg_temp.id('alice'), 'Tonight: mai tais');
  insert into public.regular_details (id, usual) values (pg_temp.id('rita'), 'Mezcal Negroni');
end $$;

-- ---------- Content filter ----------
do $$
begin
  perform pg_temp.login(pg_temp.id('alice'));
  perform pg_temp.fails($q$insert into public.posts (bartender_id, body) values (pg_temp.id('alice'), 'you RETARDS')$q$,
    'post with a blocked term is rejected');
  perform pg_temp.fails($q$insert into public.posts (bartender_id, body) values (pg_temp.id('alice'), 'f4gs out')$q$,
    'leetspeak variant is rejected');
  perform pg_temp.fails($q$update public.bartenders set bio = 'no fags' where id = pg_temp.id('alice')$q$,
    'bio with a blocked term is rejected');
  perform pg_temp.fails($q$insert into public.bars (bartender_id, name) values (pg_temp.id('alice'), 'Spic Bar')$q$,
    'bar name with a blocked term is rejected');
  insert into public.posts (bartender_id, body) values (pg_temp.id('alice'), 'Scunthorpe fagioli night, spice rack, retardant-free');
  perform pg_temp.ok(true, 'whole-word match: innocent words containing a term still post');
  update public.bartenders set bio = 'Tiki nights' where id = pg_temp.id('alice');
  perform pg_temp.ok(true, 'clean bio saves');

  perform pg_temp.login(pg_temp.id('rita'));
  perform pg_temp.fails($q$update public.profiles set display_name = 'Kike' where id = pg_temp.id('rita')$q$,
    'display name with a blocked term is rejected');
  perform pg_temp.fails($q$update public.regular_details set usual = 'nigga juice' where id = pg_temp.id('rita')$q$,
    'usual with a blocked term is rejected');
  perform pg_temp.fails($q$select public.send_reply((select id from public.posts where body = 'Tonight: mai tais'), 'shut up retard')$q$,
    'reply with a blocked term is rejected (through send_reply)');
end $$;

do $$
declare v_err text; v_detail text;
begin
  perform pg_temp.login(pg_temp.id('alice'));
  begin
    insert into public.posts (bartender_id, body) values (pg_temp.id('alice'), 'gook');
  exception when others then
    get stacked diagnostics v_err = message_text, v_detail = pg_exception_detail;
  end;
  perform pg_temp.ok(v_err = 'content_not_allowed' and v_detail = 'body', 'error is content_not_allowed with the column as detail');
end $$;

do $$
begin
  perform pg_temp.login(pg_temp.id('rita'));
  perform pg_temp.fails('select * from private.blocked_terms', 'clients cannot read the term list');
  perform pg_temp.fails($q$insert into private.blocked_terms values ('hello')$q$, 'clients cannot change the term list');
end $$;

-- ---------- Bartender blocks a regular → moderators get a report ----------
do $$
begin
  perform pg_temp.login(pg_temp.id('bob'));
  perform public.block_regular(pg_temp.id('una'));
  perform pg_temp.admin();
  perform pg_temp.ok((select count(*) from private.reports
                       where reporter_id = pg_temp.id('bob') and reported_user_id = pg_temp.id('una')
                         and reason = 'blocked' and kind = 'person' and status = 'open') = 1,
    'block_regular opens a "blocked" report for moderators');
  perform pg_temp.login(pg_temp.id('bob'));
  perform public.unblock_regular(pg_temp.id('una'));
  perform pg_temp.admin();
  insert into public.connections (bartender_id, regular_id, source) values (pg_temp.id('bob'), pg_temp.id('una'), 'code');
  perform pg_temp.login(pg_temp.id('bob'));
  perform public.block_regular(pg_temp.id('una'));
  perform pg_temp.admin();
  perform pg_temp.ok((select count(*) from private.reports
                       where reporter_id = pg_temp.id('bob') and reported_user_id = pg_temp.id('una')) = 1,
    're-blocking while the report is open does not duplicate it');
  perform pg_temp.login(pg_temp.id('una'));
  perform pg_temp.fails($q$select public.report('person', pg_temp.id('bob'), 'blocked')$q$,
    'people cannot pick "blocked" as a report reason');
end $$;

-- ---------- Regular blocks a bartender ----------
do $$
begin
  perform pg_temp.login(pg_temp.id('rita'));
  perform pg_temp.ok((select count(*) from public.posts where bartender_id = pg_temp.id('alice')) >= 1, 'before: rita sees alice''s updates');
  perform public.block_bartender(pg_temp.id('alice'));

  perform pg_temp.ok((select count(*) from public.regular_blocks where bartender_id = pg_temp.id('alice')) = 1, 'rita sees her own block');
  perform pg_temp.ok((select count(*) from public.connections where bartender_id = pg_temp.id('alice')) = 0, 'blocking unfollows');
  perform pg_temp.ok((select count(*) from public.posts where bartender_id = pg_temp.id('alice')) = 0, 'updates are hidden at once');
  perform pg_temp.ok((select count(*) from public.bartenders where id = pg_temp.id('alice')) = 0, 'public page is hidden too');
  perform pg_temp.ok((select count(*) from public.bars where bartender_id = pg_temp.id('alice')) = 0, 'bars are hidden');
  perform pg_temp.ok((select display_name from public.my_blocked_bartenders()) = 'Alice', 'my_blocked_bartenders lists her by name');

  perform pg_temp.login(pg_temp.id('alice'));
  perform pg_temp.ok((select count(*) from public.regular_blocks) = 0, 'the bartender cannot see that she was blocked');
  perform pg_temp.ok((select count(*) from public.regular_details where id = pg_temp.id('rita')) = 0, 'and no longer sees rita''s profile');
  perform pg_temp.ok((select count(*) from public.my_regulars() where regular_id = pg_temp.id('rita')) = 0, 'rita leaves her regulars list (looks like an unfollow)');

  perform pg_temp.admin();
  perform pg_temp.ok((select count(*) from private.reports
                       where reporter_id = pg_temp.id('rita') and reported_user_id = pg_temp.id('alice') and reason = 'blocked') = 1,
    'block_bartender opens a "blocked" report for moderators');
  perform pg_temp.fails($q$insert into public.connections (bartender_id, regular_id, source) values (pg_temp.id('alice'), pg_temp.id('rita'), 'code')$q$,
    'a blocked bartender cannot be reconnected');
end $$;

do $$
declare v_link text;
begin
  perform pg_temp.login(pg_temp.id('alice'));
  v_link := (public.create_invite_link() ->> 'token');
  perform pg_temp.login(pg_temp.id('rita'));
  perform pg_temp.fails(format('select public.redeem_invite(%L)', v_link), 'redeem_invite refuses while rita has alice blocked');
  perform pg_temp.fails($q$insert into public.regular_blocks (regular_id, bartender_id) values (pg_temp.id('rita'), pg_temp.id('bob'))$q$,
    'regular_blocks cannot be written directly');

  perform public.block_bartender(pg_temp.id('bob'));
  perform pg_temp.ok((select count(*) from public.regular_blocks where bartender_id = pg_temp.id('bob')) = 0,
    'cannot block a bartender whose page you cannot see (silent no-op)');

  perform public.unblock_bartender(pg_temp.id('alice'));
  perform pg_temp.ok((select count(*) from public.regular_blocks) = 0, 'unblock removes the block');
  perform pg_temp.ok((select count(*) from public.connections where bartender_id = pg_temp.id('alice')) = 0, 'unblocking does not reconnect');
  perform pg_temp.ok((public.redeem_invite(v_link) ->> 'ok')::boolean, 'after unblocking, the link works again');
end $$;

select 'ALL APP REVIEW SAFETY TESTS PASSED';
rollback;
