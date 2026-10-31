-- The Usual — regular profiles + bartender notes test suite (migration 0008).
-- Runs in one transaction and ROLLS BACK, so it is safe on a real project:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/regular_profiles_test.sql
-- Any failure raises "FAIL: ..." and aborts. Success ends with "ALL REGULAR PROFILE TESTS PASSED".

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

--  alice = bartender; rita, tom = alice's regulars (tom gets blocked later)
--  bob   = bartender who is also alice's regular; una = bob's regular
--  sam   = signed-in stranger
create temp table ids (name text primary key, id uuid);
grant select on ids to authenticated, anon;
insert into ids values
  ('alice', '00000000-0000-4000-d000-00000000000a'),
  ('bob',   '00000000-0000-4000-d000-00000000000b'),
  ('rita',  '00000000-0000-4000-d000-0000000000c1'),
  ('sam',   '00000000-0000-4000-d000-0000000000c2'),
  ('tom',   '00000000-0000-4000-d000-0000000000c3'),
  ('una',   '00000000-0000-4000-d000-0000000000c4');
create function pg_temp.id(n text) returns uuid language sql stable as $$ select id from ids where name = n $$;

insert into auth.users (id, phone) select id, '1555300' || row_number() over () from ids;

do $$
declare n text;
begin
  foreach n in array array['alice', 'bob', 'rita', 'sam', 'tom', 'una'] loop
    perform pg_temp.login(pg_temp.id(n));
    insert into public.profiles (id, display_name) values (pg_temp.id(n), initcap(n));
  end loop;
  perform pg_temp.login(pg_temp.id('alice'));
  insert into public.bartenders (id, schedule_visibility) values (pg_temp.id('alice'), 'public');
  perform pg_temp.login(pg_temp.id('bob'));
  insert into public.bartenders (id, schedule_visibility) values (pg_temp.id('bob'), 'public');

  perform pg_temp.admin();
  insert into public.connections (bartender_id, regular_id, source) values
    (pg_temp.id('alice'), pg_temp.id('rita'), 'code'),
    (pg_temp.id('alice'), pg_temp.id('tom'),  'code'),
    (pg_temp.id('alice'), pg_temp.id('bob'),  'code'),
    (pg_temp.id('bob'),   pg_temp.id('una'),  'code');
end $$;

-- ---------- Writing your own details ----------
do $$
begin
  perform pg_temp.login(pg_temp.id('rita'));
  insert into public.regular_details (id, photo_path, usual, birthday_month, birthday_day)
    values (pg_temp.id('rita'), pg_temp.id('rita') || '/me.webp', 'Mezcal Negroni, up', 3, 14);
  perform pg_temp.ok((select usual from public.regular_details where id = pg_temp.id('rita')) = 'Mezcal Negroni, up', 'regular can save and read their own details');

  perform pg_temp.fails(format('insert into public.regular_details (id, usual) values (%L, %L)', pg_temp.id('sam'), 'x'),
    'cannot create details for someone else');
  perform pg_temp.fails(format('update public.regular_details set photo_path = %L where id = %L', pg_temp.id('sam') || '/x.webp', pg_temp.id('rita')),
    'photo path must be in your own folder');
  perform pg_temp.fails(format('update public.regular_details set usual = %L where id = %L', repeat('x', 61), pg_temp.id('rita')),
    'usual is at most 60 characters');
  perform pg_temp.fails(format('update public.regular_details set birthday_month = 13 where id = %L', pg_temp.id('rita')), 'month 13 refused');
  perform pg_temp.fails(format('update public.regular_details set birthday_month = 2, birthday_day = 30 where id = %L', pg_temp.id('rita')), 'February 30 refused');
  perform pg_temp.fails(format('update public.regular_details set birthday_month = 4, birthday_day = 31 where id = %L', pg_temp.id('rita')), 'April 31 refused');
  perform pg_temp.fails(format('update public.regular_details set birthday_day = null where id = %L', pg_temp.id('rita')), 'month without day refused');
  perform pg_temp.fails(format('update public.regular_details set id = %L where id = %L', pg_temp.id('sam'), pg_temp.id('rita')), 'id is not updatable');

  perform pg_temp.login(pg_temp.id('tom'));
  insert into public.regular_details (id, usual, birthday_month, birthday_day) values (pg_temp.id('tom'), 'Lager', 2, 29);
  perform pg_temp.ok((select birthday_day from public.regular_details where id = pg_temp.id('tom')) = 29, 'February 29 allowed');

  perform pg_temp.login(pg_temp.id('bob'));
  insert into public.regular_details (id, photo_path, usual) values (pg_temp.id('bob'), pg_temp.id('bob') || '/me.webp', 'Fernet');

  perform pg_temp.admin();
  insert into storage.objects (bucket_id, name) values
    ('regular-photos', pg_temp.id('rita') || '/me.webp'),
    ('regular-photos', pg_temp.id('bob')  || '/me.webp');
end $$;

-- ---------- Who sees a regular's details ----------
do $$
begin
  perform pg_temp.login(pg_temp.id('alice'));
  perform pg_temp.ok((select count(*) from public.regular_details where id = pg_temp.id('rita')) = 1, 'bartender sees her regular''s details');
  perform pg_temp.ok((select count(*) from storage.objects where bucket_id = 'regular-photos' and name like pg_temp.id('rita') || '/%') = 1, '…and their photo');
  update public.regular_details set usual = 'hacked' where id = pg_temp.id('rita');
  perform pg_temp.login(pg_temp.id('rita'));
  perform pg_temp.ok((select usual from public.regular_details where id = pg_temp.id('rita')) = 'Mezcal Negroni, up', 'bartender cannot change a regular''s details');

  perform pg_temp.login(pg_temp.id('sam'));
  perform pg_temp.ok((select count(*) from public.regular_details) = 0, 'stranger sees no one''s details');
  perform pg_temp.ok((select count(*) from storage.objects where bucket_id = 'regular-photos') = 0, 'stranger sees no regular photos');

  perform pg_temp.login(pg_temp.id('bob'));
  perform pg_temp.ok((select count(*) from public.regular_details where id = pg_temp.id('rita')) = 0, 'another bartender cannot see rita''s details');
  perform pg_temp.ok((select count(*) from storage.objects where bucket_id = 'regular-photos' and name like pg_temp.id('rita') || '/%') = 0, '…or her photo');

  perform pg_temp.login(pg_temp.id('rita'));
  perform pg_temp.ok((select count(*) from public.regular_details) = 1, 'a regular sees only their own details, not other regulars''');
  perform pg_temp.ok((select count(*) from storage.objects where bucket_id = 'regular-photos') = 1, '…and only their own photo');

  -- Bob is both a bartender and alice's regular.
  perform pg_temp.login(pg_temp.id('alice'));
  perform pg_temp.ok((select usual from public.regular_details where id = pg_temp.id('bob')) = 'Fernet', 'bartender sees a bartender-regular''s details');
  perform pg_temp.login(pg_temp.id('una'));
  perform pg_temp.ok((select count(*) from public.profiles where id = pg_temp.id('bob')) = 1, 'una can see her bartender bob''s name');
  perform pg_temp.ok((select count(*) from public.regular_details where id = pg_temp.id('bob')) = 0, '…but not bob''s own regular details');
  perform pg_temp.ok((select count(*) from storage.objects where bucket_id = 'regular-photos') = 0, '…or his regular photo');

  perform pg_temp.anon();
  perform pg_temp.fails('select * from public.regular_details', 'anon cannot read details');
  perform pg_temp.fails('select * from public.regular_notes', 'anon cannot read notes');
  perform pg_temp.fails('select * from public.my_regulars()', 'anon cannot call my_regulars');
end $$;

-- ---------- Photo uploads ----------
do $$
begin
  perform pg_temp.login(pg_temp.id('rita'));
  perform pg_temp.fails(format('insert into storage.objects (bucket_id, name) values (%L, %L)', 'regular-photos', pg_temp.id('sam') || '/x.webp'),
    'cannot upload into someone else''s folder');
  insert into storage.objects (bucket_id, name) values ('regular-photos', pg_temp.id('rita') || '/new.webp');
  perform pg_temp.ok((select count(*) from storage.objects where bucket_id = 'regular-photos') = 2, 'can upload into own folder');

  perform pg_temp.login(pg_temp.id('alice'));
  delete from storage.objects where bucket_id = 'regular-photos' and name like pg_temp.id('rita') || '/%';
  perform pg_temp.login(pg_temp.id('rita'));
  perform pg_temp.ok((select count(*) from storage.objects where bucket_id = 'regular-photos') = 2, 'bartender cannot delete a regular''s photo');
  delete from storage.objects where bucket_id = 'regular-photos' and name = pg_temp.id('rita') || '/new.webp';
  perform pg_temp.ok((select count(*) from storage.objects where bucket_id = 'regular-photos') = 1, 'regular can delete their own photo');
end $$;

-- ---------- Bartender notes ----------
do $$
begin
  perform pg_temp.login(pg_temp.id('alice'));
  insert into public.regular_notes (bartender_id, regular_id, body) values (pg_temp.id('alice'), pg_temp.id('rita'), 'Allergic to citrus. Tips well.');
  perform pg_temp.ok((select body from public.regular_notes where regular_id = pg_temp.id('rita')) = 'Allergic to citrus. Tips well.', 'bartender can save and read a note');
  update public.regular_notes set body = 'Allergic to citrus.' where regular_id = pg_temp.id('rita');
  perform pg_temp.ok((select body from public.regular_notes where regular_id = pg_temp.id('rita')) = 'Allergic to citrus.', 'bartender can edit her note');

  perform pg_temp.fails(format('insert into public.regular_notes (bartender_id, regular_id, body) values (%L, %L, %L)', pg_temp.id('alice'), pg_temp.id('sam'), 'x'),
    'cannot write a note about someone who is not your regular');
  perform pg_temp.fails(format('insert into public.regular_notes (bartender_id, regular_id, body) values (%L, %L, %L)', pg_temp.id('alice'), pg_temp.id('alice'), 'x'),
    'cannot write a note about yourself');
  perform pg_temp.fails(format('insert into public.regular_notes (bartender_id, regular_id, body) values (%L, %L, %L)', pg_temp.id('alice'), pg_temp.id('tom'), '   '),
    'empty note refused');
  perform pg_temp.fails(format('insert into public.regular_notes (bartender_id, regular_id, body) values (%L, %L, %L)', pg_temp.id('alice'), pg_temp.id('tom'), repeat('x', 501)),
    'note is at most 500 characters');
  perform pg_temp.fails(format('update public.regular_notes set updated_at = now() - interval %L where regular_id = %L', '1 year', pg_temp.id('rita')),
    'updated_at is not client-writable');
  perform pg_temp.fails(format('update public.regular_notes set regular_id = %L where regular_id = %L', pg_temp.id('tom'), pg_temp.id('rita')),
    'a note cannot be moved to another regular');

  perform pg_temp.login(pg_temp.id('rita'));
  perform pg_temp.ok((select count(*) from public.regular_notes) = 0, 'regular cannot see notes about them');
  perform pg_temp.fails(format('insert into public.regular_notes (bartender_id, regular_id, body) values (%L, %L, %L)', pg_temp.id('rita'), pg_temp.id('alice'), 'x'),
    'non-bartender cannot write notes');

  perform pg_temp.login(pg_temp.id('bob'));
  perform pg_temp.ok((select count(*) from public.regular_notes) = 0, 'another bartender cannot see alice''s notes');
  update public.regular_notes set body = 'hacked' where bartender_id = pg_temp.id('alice');
  delete from public.regular_notes where bartender_id = pg_temp.id('alice');
  perform pg_temp.fails(format('insert into public.regular_notes (bartender_id, regular_id, body) values (%L, %L, %L)', pg_temp.id('alice'), pg_temp.id('rita'), 'x'),
    'cannot write a note as another bartender');
  insert into public.regular_notes (bartender_id, regular_id, body) values (pg_temp.id('bob'), pg_temp.id('una'), 'Bob''s note about Una');

  perform pg_temp.login(pg_temp.id('alice'));
  perform pg_temp.ok((select body from public.regular_notes where regular_id = pg_temp.id('rita')) = 'Allergic to citrus.', 'other bartender could not change or delete alice''s note');
  perform pg_temp.ok((select count(*) from public.regular_notes) = 1, 'alice sees only her own notes');

  perform pg_temp.login(pg_temp.id('una'));
  perform pg_temp.ok((select count(*) from public.regular_notes) = 0, 'una cannot see bob''s note about her');
end $$;

-- ---------- my_regulars ----------
do $$
declare r record;
begin
  perform pg_temp.login(pg_temp.id('alice'));
  select * into r from public.my_regulars() where regular_id = pg_temp.id('rita');
  perform pg_temp.ok(r.usual = 'Mezcal Negroni, up' and r.birthday_month = 3 and r.birthday_day = 14
                     and r.photo_path = pg_temp.id('rita') || '/me.webp' and r.note = 'Allergic to citrus.',
                     'my_regulars returns usual, birthday, photo and note');
  perform pg_temp.ok((select usual from public.my_regulars() where regular_id = pg_temp.id('bob')) = 'Fernet', 'my_regulars includes bartender-regulars');
  perform pg_temp.ok((select count(*) from public.my_regulars()) = 3, 'my_regulars lists all three regulars');

  perform pg_temp.login(pg_temp.id('bob'));
  perform pg_temp.ok((select count(*) from public.my_regulars()) = 1, 'bob''s my_regulars has only una');
  perform pg_temp.ok((select note from public.my_regulars()) = 'Bob''s note about Una', '…with his note');
  perform pg_temp.ok((select usual from public.my_regulars()) = '', '…and an empty usual when she set none');

  perform pg_temp.login(pg_temp.id('rita'));
  perform pg_temp.ok((select count(*) from public.my_regulars()) = 0, 'a non-bartender gets an empty list');
end $$;

-- ---------- Blocking and unfollowing ----------
do $$
begin
  perform pg_temp.login(pg_temp.id('alice'));
  perform public.block_regular(pg_temp.id('tom'));
  perform pg_temp.ok((select count(*) from public.regular_details where id = pg_temp.id('tom')) = 1, 'bartender still recognises someone she blocked');
  perform pg_temp.ok((select blocked and usual = 'Lager' from public.my_regulars() where regular_id = pg_temp.id('tom')), 'my_regulars shows blocked people with their details');
  insert into public.regular_notes (bartender_id, regular_id, body) values (pg_temp.id('alice'), pg_temp.id('tom'), 'Why I blocked him');
  perform pg_temp.ok((select count(*) from public.regular_notes where regular_id = pg_temp.id('tom')) = 1, 'bartender can keep a note on someone she blocked');

  perform pg_temp.login(pg_temp.id('tom'));
  perform pg_temp.ok((select count(*) from public.regular_details) = 1, 'blocked person still sees their own details');
  perform pg_temp.ok((select count(*) from public.regular_notes) = 0, 'blocked person cannot see the note');

  perform pg_temp.login(pg_temp.id('alice'));
  perform public.unblock_regular(pg_temp.id('tom'));
  perform pg_temp.ok((select count(*) from public.regular_details where id = pg_temp.id('tom')) = 0, 'after unblock (no reconnection) the details are hidden');
  update public.regular_notes set body = 'edited' where regular_id = pg_temp.id('tom');
  perform pg_temp.ok((select body from public.regular_notes where regular_id = pg_temp.id('tom')) = 'edited', 'old note is kept and still editable by its owner');

  perform pg_temp.login(pg_temp.id('rita'));
  delete from public.connections where bartender_id = pg_temp.id('alice') and regular_id = pg_temp.id('rita');
  perform pg_temp.login(pg_temp.id('alice'));
  perform pg_temp.ok((select count(*) from public.regular_details where id = pg_temp.id('rita')) = 0, 'regular unfollows: bartender loses their details');
  perform pg_temp.ok((select count(*) from storage.objects where bucket_id = 'regular-photos' and name like pg_temp.id('rita') || '/%') = 0, '…and their photo');
  perform pg_temp.fails(format('insert into public.regular_notes (bartender_id, regular_id, body) values (%L, %L, %L)', pg_temp.id('alice'), pg_temp.id('rita'), 'x'),
    '…and cannot start a new note about them');
end $$;

select pg_temp.admin();
do $$ begin raise notice 'ALL REGULAR PROFILE TESTS PASSED'; end $$;
rollback;
