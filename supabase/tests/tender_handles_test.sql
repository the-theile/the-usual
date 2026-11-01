-- The Usual — custom page link (handle) test suite (migration 0010).
-- Runs in one transaction and ROLLS BACK, so it is safe on a real project:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/tender_handles_test.sql
-- Any failure raises "FAIL: ..." and aborts. Success ends with "ALL HANDLE TESTS PASSED".

begin;

create function pg_temp.ok(c boolean, msg text) returns void language plpgsql as $$
begin
  if c is not true then raise exception 'FAIL: %', msg; end if;
  raise notice 'ok - %', msg;
end $$;

-- Passes only if stmt fails with an error message containing want.
create function pg_temp.fails(stmt text, want text, msg text) returns void language plpgsql as $$
begin
  begin
    execute stmt;
  exception when others then
    if position(want in sqlerrm) = 0 then
      raise exception 'FAIL: % — wanted "%", got "%"', msg, want, sqlerrm;
    end if;
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

--  alice = bartender, public schedule; bob = bartender, regulars-only schedule
--  rita  = bob's regular; tom = bob's regular who gets blocked; sam = signed-in stranger
create temp table ids (name text primary key, id uuid);
grant select on ids to authenticated, anon;
insert into ids values
  ('alice', '00000000-0000-4000-e000-00000000000a'),
  ('bob',   '00000000-0000-4000-e000-00000000000b'),
  ('rita',  '00000000-0000-4000-e000-0000000000c1'),
  ('sam',   '00000000-0000-4000-e000-0000000000c2'),
  ('tom',   '00000000-0000-4000-e000-0000000000c3');
create function pg_temp.id(n text) returns uuid language sql stable as $$ select id from ids where name = n $$;
create function pg_temp.pid(n text) returns text language sql stable security definer as $$
  select public_id from public.bartenders where id = pg_temp.id(n) $$;
grant execute on function pg_temp.pid(text) to authenticated, anon;

insert into auth.users (id, phone) select id, '1555400' || row_number() over () from ids;

do $$
declare n text;
begin
  foreach n in array array['alice', 'bob', 'rita', 'sam', 'tom'] loop
    perform pg_temp.login(pg_temp.id(n));
    insert into public.profiles (id, display_name) values (pg_temp.id(n), initcap(n));
  end loop;
  perform pg_temp.login(pg_temp.id('alice'));
  insert into public.bartenders (id, schedule_visibility) values (pg_temp.id('alice'), 'public');
  perform pg_temp.login(pg_temp.id('bob'));
  insert into public.bartenders (id, schedule_visibility) values (pg_temp.id('bob'), 'regulars');

  perform pg_temp.admin();
  insert into public.connections (bartender_id, regular_id, source) values
    (pg_temp.id('bob'), pg_temp.id('rita'), 'code'),
    (pg_temp.id('bob'), pg_temp.id('tom'),  'code');
end $$;

-- ---------- Setting a handle ----------
do $$
begin
  perform pg_temp.login(pg_temp.id('alice'));
  perform pg_temp.ok(public.set_handle('  Alice-Pours ') = 'alice-pours', 'handle is trimmed and lowercased');
  perform pg_temp.ok((select handle from public.bartenders where id = pg_temp.id('alice')) = 'alice-pours', '…and stored');
  perform pg_temp.ok(public.set_handle('alice-pours') = 'alice-pours', 'setting the same handle again is a no-op');

  perform pg_temp.fails($q$update public.bartenders set handle = 'sneaky' where id = auth.uid()$q$, 'permission denied',
    'handle cannot be written directly');
  perform pg_temp.fails($q$update public.bartenders set handle_changed_at = null where id = auth.uid()$q$, 'permission denied',
    'change date cannot be written directly');

  perform pg_temp.login(pg_temp.id('bob'));
  perform pg_temp.fails($q$select public.set_handle('ab')$q$, 'handle_invalid', 'too short refused');
  perform pg_temp.fails(format('select public.set_handle(%L)', repeat('a', 31)), 'handle_invalid', 'too long refused');
  perform pg_temp.fails($q$select public.set_handle('-bob')$q$, 'handle_invalid', 'leading hyphen refused');
  perform pg_temp.fails($q$select public.set_handle('bob-')$q$, 'handle_invalid', 'trailing hyphen refused');
  perform pg_temp.fails($q$select public.set_handle('bo--b')$q$, 'handle_invalid', 'double hyphen refused');
  perform pg_temp.fails($q$select public.set_handle('bob_b')$q$, 'handle_invalid', 'underscore refused');
  perform pg_temp.fails($q$select public.set_handle('bób')$q$, 'handle_invalid', 'non-ASCII refused');
  perform pg_temp.fails($q$select public.set_handle('bob/x')$q$, 'handle_invalid', 'slash refused');
  perform pg_temp.fails($q$select public.set_handle('Admin')$q$, 'handle_reserved', 'reserved word refused');
  perform pg_temp.fails($q$select public.set_handle('the-usual')$q$, 'handle_reserved', 'brand name refused');
  perform pg_temp.fails($q$select public.set_handle('ALICE-pours')$q$, 'handle_taken', 'someone else''s handle refused (any case)');
  perform pg_temp.ok(public.set_handle('bob') = 'bob', 'three characters is enough');

  perform pg_temp.login(pg_temp.id('sam'));
  perform pg_temp.fails($q$select public.set_handle('sam-the-man')$q$, 'not_a_bartender', 'regulars cannot set a handle');
  perform pg_temp.anon();
  perform pg_temp.fails($q$select public.set_handle('ghost')$q$, 'permission denied', 'signed-out callers cannot set a handle');
  perform pg_temp.fails($q$select * from public.resolve_handle('bob')$q$, 'permission denied', '…or resolve one');
end $$;

-- ---------- Who a handle resolves for ----------
do $$
begin
  perform pg_temp.login(pg_temp.id('sam'));
  perform pg_temp.ok((select public_id from public.resolve_handle('alice-pours')) = pg_temp.pid('alice'), 'public schedule: a stranger can open the link');
  perform pg_temp.ok((select public_id from public.resolve_handle('ALICE-POURS')) = pg_temp.pid('alice'), '…in any case');
  perform pg_temp.ok((select count(*) from public.resolve_handle('bob')) = 0, 'regulars-only schedule: a stranger gets nothing');
  perform pg_temp.ok((select count(*) from public.resolve_handle('nobody-here')) = 0, 'unknown handle gets nothing');
  perform pg_temp.ok((select count(*) from public.bartenders where handle = 'bob') = 0, 'stranger cannot find a private page by its handle column');

  perform pg_temp.login(pg_temp.id('rita'));
  perform pg_temp.ok((select public_id from public.resolve_handle('bob')) = pg_temp.pid('bob'), 'regular can open a regulars-only page by handle');
  perform pg_temp.login(pg_temp.id('bob'));
  perform pg_temp.ok((select public_id from public.resolve_handle('bob')) = pg_temp.pid('bob'), 'bartender can open their own page by handle');

  perform public.block_regular(pg_temp.id('tom'));
  perform pg_temp.login(pg_temp.id('tom'));
  perform pg_temp.ok((select count(*) from public.resolve_handle('bob')) = 0, 'blocked person gets nothing');

  perform pg_temp.login(pg_temp.id('alice'));
  update public.bartenders set schedule_visibility = 'regulars' where id = auth.uid();
  perform pg_temp.login(pg_temp.id('sam'));
  perform pg_temp.ok((select count(*) from public.resolve_handle('alice-pours')) = 0, 'making the schedule private hides the link from strangers');
  perform pg_temp.login(pg_temp.id('alice'));
  update public.bartenders set schedule_visibility = 'public' where id = auth.uid();
end $$;

-- ---------- Changing a handle: old ones stay reserved and keep working ----------
do $$
begin
  perform pg_temp.admin();
  update public.bartenders set handle_changed_at = now() - interval '31 days' where id = pg_temp.id('alice');

  perform pg_temp.login(pg_temp.id('alice'));
  perform pg_temp.ok(public.set_handle('alice') = 'alice', 'can change after 30 days');
  perform pg_temp.fails($q$select public.set_handle('alice-2')$q$, 'handle_cooldown', 'cannot change again within 30 days');
  perform pg_temp.ok(public.set_handle(null) is null, 'can remove the handle any time');
  perform pg_temp.fails($q$select public.set_handle('alice-2')$q$, 'handle_cooldown', 'removing does not reset the 30 days');
  perform pg_temp.ok(public.set_handle('alice-pours') = 'alice-pours', 'can take back an old handle any time');
  perform pg_temp.ok(public.set_handle('') is null, 'empty string removes too');
  perform pg_temp.ok(public.set_handle('alice') = 'alice', '…and take back the other one');

  perform pg_temp.login(pg_temp.id('sam'));
  perform pg_temp.ok((select public_id from public.resolve_handle('alice-pours')) = pg_temp.pid('alice'), 'old handle still opens the page');
  perform pg_temp.ok((select handle from public.resolve_handle('alice-pours')) = 'alice', '…and reports the current handle');

  perform pg_temp.login(pg_temp.id('bob'));
  perform pg_temp.admin();
  update public.bartenders set handle_changed_at = null where id = pg_temp.id('bob');
  perform pg_temp.login(pg_temp.id('bob'));
  perform pg_temp.fails($q$select public.set_handle('alice-pours')$q$, 'handle_taken', 'someone else''s old handle cannot be claimed');

  perform pg_temp.admin();
  perform pg_temp.ok((select count(*) from private.handle_history where bartender_id = pg_temp.id('alice')) = 1, 'history holds only the retired handle');
end $$;

-- ---------- Privacy of the history table ----------
do $$
begin
  perform pg_temp.login(pg_temp.id('alice'));
  perform pg_temp.fails('select * from private.handle_history', 'permission denied', 'nobody can read handle history directly');
  perform pg_temp.fails($q$insert into private.handle_history values ('squat', auth.uid())$q$, 'permission denied', '…or write it');
end $$;

-- ---------- Deleting the account frees the handles ----------
do $$
begin
  perform pg_temp.login(pg_temp.id('alice'));
  perform public.delete_my_account();
  perform pg_temp.admin();
  perform pg_temp.ok((select count(*) from private.handle_history where handle in ('alice', 'alice-pours')) = 0, 'deleted account leaves no handle history');
  perform pg_temp.login(pg_temp.id('bob'));
  perform pg_temp.ok(public.set_handle('alice-pours') = 'alice-pours', 'a deleted account''s handle can be taken');
end $$;

select pg_temp.admin();
do $$ begin raise notice 'ALL HANDLE TESTS PASSED'; end $$;
rollback;
