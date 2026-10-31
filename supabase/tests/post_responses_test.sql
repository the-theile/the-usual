-- The Usual — reactions & replies test suite (migration 0006).
-- Runs in one transaction and ROLLS BACK, so it is safe on a real project:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/post_responses_test.sql
-- Any failure raises "FAIL: ..." and aborts. Success ends with "ALL RESPONSE TESTS PASSED".

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
--  sam   = signed-in stranger
create temp table ids (name text primary key, id uuid);
grant select on ids to authenticated, anon;
insert into ids values
  ('alice', '00000000-0000-4000-b000-00000000000a'),
  ('rita',  '00000000-0000-4000-b000-0000000000c1'),
  ('sam',   '00000000-0000-4000-b000-0000000000c2'),
  ('tom',   '00000000-0000-4000-b000-0000000000c3');
create function pg_temp.id(n text) returns uuid language sql stable as $$ select id from ids where name = n $$;

create temp table t (k text primary key, v uuid);
grant select, insert, update on t to authenticated;
grant select on t to anon;
create function pg_temp.v(k text) returns uuid language sql stable as $$ select v from t where t.k = $1 $$;

insert into auth.users (id, phone) select id, '1555100' || row_number() over () from ids;

do $$
declare v jsonb;
begin
  foreach v in array array[
    jsonb_build_object('n','alice','d','Alice'), jsonb_build_object('n','rita','d','Rita'),
    jsonb_build_object('n','sam','d','Sam'),     jsonb_build_object('n','tom','d','Tom')]
  loop
    perform pg_temp.login(pg_temp.id(v->>'n'));
    insert into public.profiles (id, display_name) values (pg_temp.id(v->>'n'), v->>'d');
  end loop;

  perform pg_temp.login(pg_temp.id('alice'));
  insert into public.bartenders (id, timezone, schedule_visibility)
    values (pg_temp.id('alice'), 'America/New_York', 'public');
  insert into public.posts (bartender_id, body) values (pg_temp.id('alice'), 'Fresh post');
  insert into public.posts (bartender_id, body) values (pg_temp.id('alice'), 'Old post');

  perform pg_temp.admin();
  insert into t select 'post', id from public.posts where body = 'Fresh post';
  insert into t select 'old',  id from public.posts where body = 'Old post';
  update public.posts set created_at = now() - interval '8 days' where id = pg_temp.v('old');
  insert into public.connections (bartender_id, regular_id, source) values
    (pg_temp.id('alice'), pg_temp.id('rita'), 'code'),
    (pg_temp.id('alice'), pg_temp.id('tom'),  'code');
end $$;

-- ---------- Reactions ----------
do $$
begin
  perform pg_temp.login(pg_temp.id('rita'));
  perform public.react_to_post(pg_temp.v('post'), 'cheers');
  perform public.react_to_post(pg_temp.v('post'), 'love');      -- change
  perform pg_temp.fails(format('select public.react_to_post(%L, %L)', pg_temp.v('post'), 'poop'), 'reaction outside the fixed set refused');
  perform pg_temp.fails(format('select public.react_to_post(%L, %L)', pg_temp.v('old'), 'love'), 'reacting to a post older than 7 days refused');
  perform pg_temp.fails(format('insert into public.post_reactions (post_id, bartender_id, regular_id, reaction) values (%L, %L, %L, %L)',
    pg_temp.v('post'), pg_temp.id('alice'), pg_temp.id('rita'), 'fire'), 'regular cannot insert reactions directly');
  perform pg_temp.fails(format('update public.post_reactions set reaction = %L', 'fire'), 'regular cannot update reactions directly');

  perform pg_temp.login(pg_temp.id('tom'));
  perform public.react_to_post(pg_temp.v('post'), 'cheers');

  perform pg_temp.login(pg_temp.id('sam'));
  perform pg_temp.fails(format('select public.react_to_post(%L, %L)', pg_temp.v('post'), 'love'), 'stranger cannot react (even with a public schedule)');
  perform pg_temp.ok((select count(*) from public.post_reaction_counts(array[pg_temp.v('post')])) = 0, 'stranger sees no reaction counts');

  perform pg_temp.login(pg_temp.id('alice'));
  perform pg_temp.fails(format('select public.react_to_post(%L, %L)', pg_temp.v('post'), 'love'), 'bartender cannot react to own post');
  perform pg_temp.ok((select count(*) from public.post_reactions) = 2, 'bartender sees every reaction (with who)');

  perform pg_temp.login(pg_temp.id('rita'));
  perform pg_temp.ok((select count(*) from public.post_reactions) = 1, 'regular sees only their own reaction row');
  perform pg_temp.ok((select reaction from public.post_reactions) = 'love', 'changed reaction stored');
  perform pg_temp.ok((select n from public.post_reaction_counts(array[pg_temp.v('post')]) where reaction = 'love' and mine) = 1, 'counts mark my reaction');
  perform pg_temp.ok((select n from public.post_reaction_counts(array[pg_temp.v('post')]) where reaction = 'cheers' and not mine) = 1, 'counts include others, without names');
  perform pg_temp.ok((select count(*) from public.post_reaction_counts(array[pg_temp.v('post')])) = 2, 'two reaction kinds counted');
end $$;

-- ---------- Replies ----------
do $$
declare i int;
begin
  perform pg_temp.login(pg_temp.id('rita'));
  insert into t values ('rita1', public.send_reply(pg_temp.v('post'), '  See you tonight!  '));
  perform pg_temp.ok((select body from public.post_replies where id = pg_temp.v('rita1')) = 'See you tonight!', 'reply stored, trimmed');
  perform pg_temp.fails(format('select public.send_reply(%L, %L)', pg_temp.v('post'), '   '), 'empty reply refused');
  perform pg_temp.fails(format('select public.send_reply(%L, %L)', pg_temp.v('post'), repeat('x', 501)), '501-char reply refused');
  perform pg_temp.fails(format('select public.send_reply(%L, %L)', pg_temp.v('old'), 'hi'), 'reply to a post older than 7 days refused');
  perform pg_temp.fails(format('insert into public.post_replies (post_id, bartender_id, regular_id, author_id, body) values (%L, %L, %L, %L, %L)',
    pg_temp.v('post'), pg_temp.id('alice'), pg_temp.id('rita'), pg_temp.id('rita'), 'x'), 'regular cannot insert replies directly');
  -- p_regular is ignored for regulars: rita can't write into tom's conversation.
  perform public.send_reply(pg_temp.v('post'), 'sneaky', pg_temp.id('tom'));
  perform pg_temp.ok((select regular_id from public.post_replies where body = 'sneaky') = pg_temp.id('rita'), 'regular always writes in their own conversation');

  perform pg_temp.login(pg_temp.id('tom'));
  perform public.send_reply(pg_temp.v('post'), 'Tom here');
  perform pg_temp.ok((select count(*) from public.post_replies) = 1, 'regular sees only their own conversation');

  perform pg_temp.login(pg_temp.id('sam'));
  perform pg_temp.fails(format('select public.send_reply(%L, %L)', pg_temp.v('post'), 'hi'), 'stranger cannot reply');
  perform pg_temp.ok((select count(*) from public.post_replies) = 0, 'stranger sees no replies');

  perform pg_temp.login(pg_temp.id('alice'));
  perform pg_temp.ok((select count(*) from public.post_replies) = 3, 'bartender sees all conversations');
  insert into t values ('alice1', public.send_reply(pg_temp.v('post'), 'Saving you a seat', pg_temp.id('rita')));
  perform pg_temp.fails(format('select public.send_reply(%L, %L)', pg_temp.v('post'), 'hi'), 'bartender must name the regular');
  perform pg_temp.fails(format('select public.send_reply(%L, %L, %L)', pg_temp.v('post'), 'hi', pg_temp.id('sam')), 'bartender cannot message a non-regular');

  perform pg_temp.login(pg_temp.id('rita'));
  perform pg_temp.ok((select count(*) from public.post_replies) = 3, 'regular sees the bartender''s answer');

  -- Edit / delete
  perform public.edit_reply(pg_temp.v('rita1'), 'See you at 9!');
  perform pg_temp.ok((select body = 'See you at 9!' and edited_at is not null from public.post_replies where id = pg_temp.v('rita1')), 'regular edits own reply');
  perform pg_temp.fails(format('select public.edit_reply(%L, %L)', pg_temp.v('alice1'), 'hacked'), 'regular cannot edit the bartender''s message');
  perform pg_temp.fails(format('select public.edit_reply(%L, %L)', pg_temp.v('rita1'), ''), 'edit to empty refused');
  perform pg_temp.fails(format('update public.post_replies set body = %L', 'x'), 'regular cannot update replies directly');
  perform public.delete_reply(pg_temp.v('alice1'));
  perform pg_temp.ok(exists (select 1 from public.post_replies where id = pg_temp.v('alice1')), 'regular cannot delete the bartender''s message');
  perform public.delete_reply((select id from public.post_replies where body = 'sneaky'));
  perform pg_temp.ok(not exists (select 1 from public.post_replies where body = 'sneaky'), 'regular deletes own reply');

  -- Cap: 20 messages per conversation (rita has 2 now).
  for i in 1..18 loop perform public.send_reply(pg_temp.v('post'), 'msg ' || i); end loop;
  perform pg_temp.fails(format('select public.send_reply(%L, %L)', pg_temp.v('post'), 'one too many'), '21st message in a conversation refused');
  perform pg_temp.login(pg_temp.id('alice'));
  perform pg_temp.fails(format('select public.send_reply(%L, %L, %L)', pg_temp.v('post'), 'me too', pg_temp.id('rita')), 'cap applies to the bartender too');
end $$;

-- ---------- Bartender activity / "new" badge ----------
do $$
declare a record;
begin
  perform pg_temp.login(pg_temp.id('alice'));
  select * into a from public.my_post_activity(array[pg_temp.v('post')]);
  perform pg_temp.ok(a.reactions = 2 and a.replies = 20, 'activity totals (regulars'' messages only)');
  perform pg_temp.ok(a.unread = 22, 'everything is new before first open');
  perform public.mark_post_seen(pg_temp.v('post'));
  perform pg_temp.ok((select unread from public.my_post_activity(array[pg_temp.v('post')])) = 0, 'opening clears the badge');

  -- now() is frozen inside this transaction: move the past back a little.
  perform pg_temp.admin();
  update public.post_reactions set created_at = created_at - interval '2 minutes';
  update public.post_replies   set created_at = created_at - interval '2 minutes';
  update private.post_reads    set seen_at    = seen_at    - interval '1 minute';

  perform pg_temp.login(pg_temp.id('tom'));
  perform public.react_to_post(pg_temp.v('post'), 'fire');
  perform pg_temp.login(pg_temp.id('alice'));
  perform pg_temp.ok((select unread from public.my_post_activity(array[pg_temp.v('post')])) = 1, 'changed reaction shows as new');

  perform pg_temp.login(pg_temp.id('rita'));
  perform pg_temp.ok((select count(*) from public.my_post_activity(array[pg_temp.v('post')])) = 0, 'regular gets no activity for someone else''s post');
  perform public.mark_post_seen(pg_temp.v('post'));   -- silent no-op
  perform pg_temp.fails('select * from private.post_reads', 'read markers are not readable through the API');
end $$;

-- ---------- Blocking and unfollowing ----------
do $$
begin
  perform pg_temp.login(pg_temp.id('alice'));
  perform public.block_regular(pg_temp.id('tom'));
  perform pg_temp.ok(not exists (select 1 from public.post_reactions where regular_id = pg_temp.id('tom')), 'bartender no longer sees blocked person''s reactions');
  perform pg_temp.ok(not exists (select 1 from public.post_replies where regular_id = pg_temp.id('tom')), 'bartender no longer sees blocked person''s replies');
  perform pg_temp.fails(format('select public.send_reply(%L, %L, %L)', pg_temp.v('post'), 'hi', pg_temp.id('tom')), 'bartender cannot answer a blocked person');

  perform pg_temp.login(pg_temp.id('tom'));
  perform pg_temp.ok((select count(*) from public.post_replies) = 0, 'blocked person loses their conversation');
  perform pg_temp.ok((select count(*) from public.post_reactions) = 0, 'blocked person loses their reaction');
  perform pg_temp.fails(format('select public.react_to_post(%L, %L)', pg_temp.v('post'), 'love'), 'blocked person cannot react');
  perform pg_temp.fails(format('select public.send_reply(%L, %L)', pg_temp.v('post'), 'hi'), 'blocked person cannot reply');

  perform pg_temp.login(pg_temp.id('rita'));
  perform pg_temp.ok((select coalesce(sum(n), 0) from public.post_reaction_counts(array[pg_temp.v('post')])) = 1, 'counts drop the blocked person');

  delete from public.connections where bartender_id = pg_temp.id('alice') and regular_id = pg_temp.id('rita');
  perform pg_temp.login(pg_temp.id('alice'));
  perform pg_temp.ok(not exists (select 1 from public.post_replies where regular_id = pg_temp.id('rita')), 'unfollowed regular''s conversation hidden from bartender');
  perform pg_temp.ok((select reactions from public.my_post_activity(array[pg_temp.v('post')])) = 0, 'unfollowed regular dropped from totals');
end $$;

-- ---------- anon ----------
do $$
begin
  perform pg_temp.anon();
  perform pg_temp.fails('select * from public.post_reactions', 'anon cannot read reactions');
  perform pg_temp.fails('select * from public.post_replies', 'anon cannot read replies');
  perform pg_temp.fails(format('select public.post_reaction_counts(array[%L]::uuid[])', pg_temp.v('post')), 'anon cannot read counts');
  perform pg_temp.fails(format('select public.react_to_post(%L, %L)', pg_temp.v('post'), 'love'), 'anon cannot react');
end $$;

select pg_temp.admin();
do $$ begin raise notice 'ALL RESPONSE TESTS PASSED'; end $$;
rollback;
