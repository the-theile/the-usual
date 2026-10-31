-- The Usual — 0006: reactions and private replies on posts
--
-- * Reactions: one per regular per post, from a fixed set. Regulars see counts
--   only; the bartender sees who reacted.
-- * Replies: a private conversation between one regular and the bartender under a
--   post. Regulars never see each other's replies. The regular starts it; the
--   bartender can answer. Capped at 20 messages per conversation.
-- * Both are open for 7 days after the post goes up.
-- * Only current regulars count: a regular who unfollows or is blocked disappears
--   from counts and conversations (rows are kept, so re-following restores them).
-- * All writes go through SECURITY DEFINER functions; clients can only SELECT.

-- ===== Tables =====

-- Target for the composite FKs below, so a response's bartender_id always
-- matches its post's bartender.
alter table public.posts add constraint posts_id_bartender_key unique (id, bartender_id);

create table public.post_reactions (
  post_id      uuid not null,
  bartender_id uuid not null,
  regular_id   uuid not null references public.profiles (id) on delete cascade,
  reaction     text not null check (reaction in ('cheers', 'love', 'laugh', 'fire', 'eyes', 'clap')),
  created_at   timestamptz not null default now(),   -- reset when the reaction changes
  primary key (post_id, regular_id),
  foreign key (post_id, bartender_id) references public.posts (id, bartender_id) on delete cascade,
  check (bartender_id <> regular_id)
);
create index post_reactions_bartender_idx on public.post_reactions (bartender_id, created_at desc);
create index post_reactions_regular_idx   on public.post_reactions (regular_id);

create table public.post_replies (
  id           uuid primary key default gen_random_uuid(),
  post_id      uuid not null,
  bartender_id uuid not null,
  regular_id   uuid not null references public.profiles (id) on delete cascade,  -- whose conversation
  author_id    uuid not null references public.profiles (id) on delete cascade,
  body         text not null check (char_length(btrim(body)) between 1 and 500),
  created_at   timestamptz not null default now(),
  edited_at    timestamptz,
  foreign key (post_id, bartender_id) references public.posts (id, bartender_id) on delete cascade,
  check (bartender_id <> regular_id),
  check (author_id in (bartender_id, regular_id))
);
create index post_replies_thread_idx    on public.post_replies (post_id, regular_id, created_at);
create index post_replies_bartender_idx on public.post_replies (bartender_id, created_at desc);
create index post_replies_regular_idx   on public.post_replies (regular_id);

-- When the bartender last opened a post's responses (drives the "new" badge).
-- Private schema so regulars can't see when their bartender last looked.
create table private.post_reads (
  post_id uuid primary key references public.posts (id) on delete cascade,
  seen_at timestamptz not null
);

-- ===== Helpers =====

create or replace function private.post_is_open(p_created timestamptz)
returns boolean
language sql stable
set search_path = ''
as $$
  select p_created > now() - interval '7 days'
$$;

-- Is r currently a regular of b? Blocking deletes the connection, so this is
-- also false for blocked people.
create or replace function private.is_current_regular(b uuid, r uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (select 1 from public.connections where bartender_id = b and regular_id = r)
$$;

-- ===== Privileges + RLS =====

revoke all on public.post_reactions, public.post_replies from anon, authenticated;
grant select on public.post_reactions, public.post_replies to authenticated;
revoke all on private.post_reads from anon, authenticated, public;

alter table public.post_reactions enable row level security;
alter table public.post_replies   enable row level security;

-- A regular sees only their own rows; the bartender sees rows from current regulars.
create policy post_reactions_select on public.post_reactions for select to authenticated
  using ((regular_id = (select auth.uid()) and private.can_view_bartender(bartender_id))
         or (bartender_id = (select auth.uid()) and private.is_current_regular(bartender_id, regular_id)));

create policy post_replies_select on public.post_replies for select to authenticated
  using ((regular_id = (select auth.uid()) and private.can_view_bartender(bartender_id))
         or (bartender_id = (select auth.uid()) and private.is_current_regular(bartender_id, regular_id)));

-- ===== Functions =====

-- Set, change (p_reaction = another value) or remove (p_reaction = null) my reaction.
create or replace function public.react_to_post(p_post uuid, p_reaction text)
returns void
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_b uuid;
  v_created timestamptz;
begin
  select bartender_id, created_at into v_b, v_created from public.posts where id = p_post;
  if v_b is null or v_b = v_uid or not private.can_view_bartender(v_b) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if p_reaction is null then
    delete from public.post_reactions where post_id = p_post and regular_id = v_uid;
    return;
  end if;
  if not private.post_is_open(v_created) then
    raise exception 'closed' using errcode = 'P0001';
  end if;
  insert into public.post_reactions (post_id, bartender_id, regular_id, reaction)
  values (p_post, v_b, v_uid, p_reaction)
  on conflict (post_id, regular_id)
  do update set reaction = excluded.reaction, created_at = now()
  where public.post_reactions.reaction is distinct from excluded.reaction;
end
$$;

-- Reaction totals for posts the caller can see. Counts only current regulars.
create or replace function public.post_reaction_counts(p_posts uuid[])
returns table (post_id uuid, reaction text, n int, mine boolean)
language sql stable security definer
set search_path = ''
as $$
  select r.post_id, r.reaction, count(*)::int, bool_or(r.regular_id = (select auth.uid()))
    from public.post_reactions r
    join public.connections c on c.bartender_id = r.bartender_id and c.regular_id = r.regular_id
   where r.post_id = any(p_posts[1:100])
     and private.can_view_bartender(r.bartender_id)
   group by r.post_id, r.reaction
$$;

-- A regular writes in their own conversation (p_regular ignored); the bartender
-- answers a conversation a current regular has started (p_regular required).
create or replace function public.send_reply(p_post uuid, p_body text, p_regular uuid default null)
returns uuid
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_body text := btrim(coalesce(p_body, ''));
  v_b uuid;
  v_created timestamptz;
  v_regular uuid;
  v_id uuid;
begin
  select bartender_id, created_at into v_b, v_created from public.posts where id = p_post;
  if v_b is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  if v_uid = v_b then
    v_regular := p_regular;
    if v_regular is null
       or not private.is_current_regular(v_b, v_regular)
       or not exists (select 1 from public.post_replies
                       where post_id = p_post and regular_id = v_regular and author_id = v_regular) then
      raise exception 'not_found' using errcode = 'P0002';
    end if;
  else
    if not private.can_view_bartender(v_b) then
      raise exception 'not_found' using errcode = 'P0002';
    end if;
    v_regular := v_uid;
  end if;

  if not private.post_is_open(v_created) then
    raise exception 'closed' using errcode = 'P0001';
  end if;
  if char_length(v_body) not between 1 and 500 then
    raise exception 'invalid_body' using errcode = '22023';
  end if;

  -- Serialise writers to one conversation so the cap holds.
  perform pg_advisory_xact_lock(hashtextextended('reply:' || p_post::text || ':' || v_regular::text, 0));
  if (select count(*) from public.post_replies where post_id = p_post and regular_id = v_regular) >= 20 then
    raise exception 'thread_full' using errcode = 'P0001';
  end if;

  insert into public.post_replies (post_id, bartender_id, regular_id, author_id, body)
  values (p_post, v_b, v_regular, v_uid, v_body)
  returning id into v_id;
  return v_id;
end
$$;

-- Edit my own message while the post is open and I can still see the conversation.
create or replace function public.edit_reply(p_reply uuid, p_body text)
returns void
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_body text := btrim(coalesce(p_body, ''));
  r public.post_replies;
begin
  select * into r from public.post_replies where id = p_reply and author_id = v_uid;
  if r.id is null
     or (v_uid = r.regular_id and not private.can_view_bartender(r.bartender_id))
     or (v_uid = r.bartender_id and not private.is_current_regular(r.bartender_id, r.regular_id)) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if not private.post_is_open((select created_at from public.posts where id = r.post_id)) then
    raise exception 'closed' using errcode = 'P0001';
  end if;
  if char_length(v_body) not between 1 and 500 then
    raise exception 'invalid_body' using errcode = '22023';
  end if;
  update public.post_replies set body = v_body, edited_at = now()
   where id = p_reply and body is distinct from v_body;
end
$$;

-- Delete my own message, any time. Unknown ids are a silent no-op.
create or replace function public.delete_reply(p_reply uuid)
returns void
language sql volatile security definer
set search_path = ''
as $$
  delete from public.post_replies where id = p_reply and author_id = (select auth.uid())
$$;

-- Bartender: totals and "new since last opened" for their own posts.
create or replace function public.my_post_activity(p_posts uuid[])
returns table (post_id uuid, reactions int, replies int, unread int)
language sql stable security definer
set search_path = ''
as $$
  with mine as (
    select p.id, coalesce(pr.seen_at, '-infinity'::timestamptz) as seen_at
      from public.posts p
      left join private.post_reads pr on pr.post_id = p.id
     where p.id = any(p_posts[1:100]) and p.bartender_id = (select auth.uid())
  ),
  rx as (
    select r.post_id, r.created_at
      from public.post_reactions r
      join public.connections c on c.bartender_id = r.bartender_id and c.regular_id = r.regular_id
     where r.post_id in (select id from mine)
  ),
  rp as (  -- messages from regulars only
    select r.post_id, r.created_at
      from public.post_replies r
      join public.connections c on c.bartender_id = r.bartender_id and c.regular_id = r.regular_id
     where r.post_id in (select id from mine) and r.author_id = r.regular_id
  )
  select m.id,
         (select count(*) from rx where rx.post_id = m.id)::int,
         (select count(*) from rp where rp.post_id = m.id)::int,
         ((select count(*) from rx where rx.post_id = m.id and rx.created_at > m.seen_at)
          + (select count(*) from rp where rp.post_id = m.id and rp.created_at > m.seen_at))::int
    from mine m
$$;

-- Bartender opened a post's responses: clear its "new" badge.
create or replace function public.mark_post_seen(p_post uuid)
returns void
language sql volatile security definer
set search_path = ''
as $$
  insert into private.post_reads (post_id, seen_at)
  select id, now() from public.posts where id = p_post and bartender_id = (select auth.uid())
  on conflict (post_id) do update set seen_at = excluded.seen_at
$$;

-- ===== Function privileges =====
revoke execute on function
  public.react_to_post(uuid, text), public.post_reaction_counts(uuid[]),
  public.send_reply(uuid, text, uuid), public.edit_reply(uuid, text), public.delete_reply(uuid),
  public.my_post_activity(uuid[]), public.mark_post_seen(uuid)
  from public, anon;
grant execute on function
  public.react_to_post(uuid, text), public.post_reaction_counts(uuid[]),
  public.send_reply(uuid, text, uuid), public.edit_reply(uuid, text), public.delete_reply(uuid),
  public.my_post_activity(uuid[]), public.mark_post_seen(uuid)
  to authenticated;
