-- The Usual — delete my account test suite (migration 0009).
-- Runs in one transaction and ROLLS BACK, so it is safe on a real project:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/delete_account_test.sql
-- Any failure raises "FAIL: ..." and aborts. Success ends with "ALL DELETE ACCOUNT TESTS PASSED".

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

--  alice = bartender; rita = alice's regular
--  bob   = bartender who is also alice's regular; una = bob's regular
create temp table ids (name text primary key, id uuid);
grant select on ids to authenticated, anon;
insert into ids values
  ('alice', '00000000-0000-4000-e000-00000000000a'),
  ('bob',   '00000000-0000-4000-e000-00000000000b'),
  ('rita',  '00000000-0000-4000-e000-0000000000c1'),
  ('una',   '00000000-0000-4000-e000-0000000000c4');
create function pg_temp.id(n text) returns uuid language sql stable as $$ select id from ids where name = n $$;

insert into auth.users (id, phone) select id, '1555400' || row_number() over () from ids;

-- ---------- Setup: a bit of everything, on both sides ----------
do $$
declare v_post uuid := gen_random_uuid();
begin
  perform pg_temp.admin();
  insert into public.profiles (id, display_name) select id, initcap(name) from ids;
  insert into public.bartenders (id) values (pg_temp.id('alice')), (pg_temp.id('bob'));
  insert into public.bars (bartender_id, name) values (pg_temp.id('alice'), 'Tiki Moon'), (pg_temp.id('bob'), 'The Anchor');
  insert into public.connections (bartender_id, regular_id, source) values
    (pg_temp.id('alice'), pg_temp.id('rita'), 'code'),
    (pg_temp.id('alice'), pg_temp.id('bob'),  'code'),
    (pg_temp.id('bob'),   pg_temp.id('una'),  'code');
  insert into public.blocks (bartender_id, regular_id) values (pg_temp.id('bob'), pg_temp.id('rita'));
  insert into public.posts (id, bartender_id, body) values (v_post, pg_temp.id('alice'), 'Tonight: mai tais');
  insert into public.posts (bartender_id, body) values (pg_temp.id('bob'), 'Quiz night');
  insert into public.post_reactions (post_id, bartender_id, regular_id, reaction) values
    (v_post, pg_temp.id('alice'), pg_temp.id('rita'), 'cheers'),
    (v_post, pg_temp.id('alice'), pg_temp.id('bob'),  'fire');
  insert into public.post_replies (post_id, bartender_id, regular_id, author_id, body) values
    (v_post, pg_temp.id('alice'), pg_temp.id('rita'), pg_temp.id('rita'),  'See you there'),
    (v_post, pg_temp.id('alice'), pg_temp.id('rita'), pg_temp.id('alice'), 'Cheers!'),
    (v_post, pg_temp.id('alice'), pg_temp.id('bob'),  pg_temp.id('bob'),   'Save me a seat');
  insert into public.regular_details (id, usual) values (pg_temp.id('rita'), 'Mezcal Negroni'), (pg_temp.id('bob'), 'Fernet');
  insert into public.regular_notes (bartender_id, regular_id, body) values
    (pg_temp.id('alice'), pg_temp.id('rita'), 'Tips well'),
    (pg_temp.id('alice'), pg_temp.id('bob'),  'Works at The Anchor'),
    (pg_temp.id('bob'),   pg_temp.id('una'),  'Likes quiz night');
  insert into private.invite_attempts (user_id, ok) values (pg_temp.id('rita'), false);
end $$;

-- ---------- Who may call it ----------
do $$
begin
  perform pg_temp.anon();
  perform pg_temp.fails('select public.delete_my_account()', 'anonymous caller cannot delete anything');
  perform pg_temp.admin();
  perform pg_temp.ok((select count(*) from auth.users where id in (select id from ids)) = 4, '…and nobody was deleted');
end $$;

-- ---------- A regular deletes their account ----------
do $$
begin
  perform pg_temp.login(pg_temp.id('rita'));
  perform public.delete_my_account();

  perform pg_temp.admin();
  perform pg_temp.ok(not exists (select 1 from auth.users where id = pg_temp.id('rita')), 'regular: sign-in record is gone');
  perform pg_temp.ok(not exists (select 1 from public.profiles where id = pg_temp.id('rita')), '…profile is gone');
  perform pg_temp.ok(not exists (select 1 from public.regular_details where id = pg_temp.id('rita')), '…photo, usual and birthday are gone');
  perform pg_temp.ok(not exists (select 1 from public.connections where regular_id = pg_temp.id('rita')), '…follows are gone');
  perform pg_temp.ok(not exists (select 1 from public.blocks where regular_id = pg_temp.id('rita')), '…blocks against them are gone');
  perform pg_temp.ok(not exists (select 1 from public.post_reactions where regular_id = pg_temp.id('rita')), '…reactions are gone');
  perform pg_temp.ok(not exists (select 1 from public.post_replies where regular_id = pg_temp.id('rita')), '…whole reply conversations are gone (bartender side too)');
  perform pg_temp.ok(not exists (select 1 from public.regular_notes where regular_id = pg_temp.id('rita')), '…bartender notes about them are gone');
  perform pg_temp.ok(not exists (select 1 from private.invite_attempts where user_id = pg_temp.id('rita')), '…code-attempt log is gone');

  perform pg_temp.ok(exists (select 1 from public.posts where bartender_id = pg_temp.id('alice')), 'bartender keeps their posts');
  perform pg_temp.ok((select count(*) from public.post_replies where regular_id = pg_temp.id('bob')) = 1, 'other regulars keep their replies');
  perform pg_temp.ok((select count(*) from public.post_reactions where regular_id = pg_temp.id('bob')) = 1, 'other regulars keep their reactions');
  perform pg_temp.ok((select count(*) from public.regular_notes) = 2, 'notes about other regulars are kept');
end $$;

-- ---------- A bartender (who is also a regular) deletes their account ----------
do $$
begin
  perform pg_temp.login(pg_temp.id('alice'));
  perform public.delete_my_account();

  perform pg_temp.admin();
  perform pg_temp.ok(not exists (select 1 from auth.users where id = pg_temp.id('alice')), 'bartender: sign-in record is gone');
  perform pg_temp.ok(not exists (select 1 from public.bartenders where id = pg_temp.id('alice')), '…bartender page is gone');
  perform pg_temp.ok(not exists (select 1 from public.bars where bartender_id = pg_temp.id('alice')), '…bars are gone');
  perform pg_temp.ok(not exists (select 1 from public.posts where bartender_id = pg_temp.id('alice')), '…posts are gone');
  perform pg_temp.ok(not exists (select 1 from public.post_replies where bartender_id = pg_temp.id('alice')), '…replies to their posts are gone');
  perform pg_temp.ok(not exists (select 1 from public.connections where bartender_id = pg_temp.id('alice')), '…their regulars are disconnected');
  perform pg_temp.ok(not exists (select 1 from public.regular_notes where bartender_id = pg_temp.id('alice')), '…their private notes are gone');

  perform pg_temp.ok(exists (select 1 from public.profiles where id = pg_temp.id('bob')), 'their regular (bob) keeps his account');
  perform pg_temp.ok(exists (select 1 from public.regular_details where id = pg_temp.id('bob')), '…and his usual');
  perform pg_temp.ok(exists (select 1 from public.posts where bartender_id = pg_temp.id('bob')), '…and his own bartender posts');
  perform pg_temp.ok(exists (select 1 from public.connections where bartender_id = pg_temp.id('bob') and regular_id = pg_temp.id('una')), '…and his own regulars');
  perform pg_temp.ok(exists (select 1 from public.regular_notes where bartender_id = pg_temp.id('bob')), '…and his notes');
end $$;

-- ---------- It only ever deletes the caller ----------
do $$
begin
  perform pg_temp.login(pg_temp.id('una'));
  perform public.delete_my_account();
  perform pg_temp.admin();
  perform pg_temp.ok(exists (select 1 from auth.users where id = pg_temp.id('bob')), 'deleting una leaves bob alone');
  perform pg_temp.ok(not exists (select 1 from public.connections where regular_id = pg_temp.id('una')), 'una is gone from bob''s regulars');
end $$;

select pg_temp.admin();
do $$ begin raise notice 'ALL DELETE ACCOUNT TESTS PASSED'; end $$;
rollback;
