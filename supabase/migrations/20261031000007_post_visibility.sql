-- The Usual — 0007: per-post visibility
--
-- Each post is 'regulars' (default) or 'public'. A public post is shown on the
-- bartender's page to anyone who can see that page, i.e. only while the
-- bartender's schedule is "Anyone with my link" (private.can_view_schedule):
-- signed-in users only, never blocked people. Non-regulars can read a public
-- post and see its reaction counts; reacting and replying stay regulars-only.

alter table public.posts
  add column visibility text not null default 'regulars' check (visibility in ('regulars', 'public'));

create index posts_photo_path_idx on public.posts (photo_path) where photo_path is not null;

-- ===== Privileges + RLS =====

grant insert (visibility), update (visibility) on public.posts to authenticated;

drop policy posts_select on public.posts;
create policy posts_select on public.posts for select to authenticated
  using (private.can_view_bartender(bartender_id)
         or (visibility = 'public' and private.can_view_schedule(bartender_id)));

-- Only the visibility column is client-updatable (column grant above).
create policy posts_update on public.posts for update to authenticated
  using (bartender_id = (select auth.uid()))
  with check (bartender_id = (select auth.uid()));

-- ===== Photos on public posts =====

create or replace function private.can_view_public_post_photo(p_path text)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.posts
    where photo_path = p_path and visibility = 'public'
      and private.can_view_schedule(bartender_id)
  )
$$;

create policy "usual: view public post photos" on storage.objects for select to authenticated
  using (bucket_id = 'post-photos' and private.can_view_public_post_photo(name));

-- ===== Reaction counts: also for viewers of a public post =====

create or replace function public.post_reaction_counts(p_posts uuid[])
returns table (post_id uuid, reaction text, n int, mine boolean)
language sql stable security definer
set search_path = ''
as $$
  select r.post_id, r.reaction, count(*)::int, bool_or(r.regular_id = (select auth.uid()))
    from public.post_reactions r
    join public.posts p on p.id = r.post_id
    join public.connections c on c.bartender_id = r.bartender_id and c.regular_id = r.regular_id
   where r.post_id = any(p_posts[1:100])
     and (private.can_view_bartender(p.bartender_id)
          or (p.visibility = 'public' and private.can_view_schedule(p.bartender_id)))
   group by r.post_id, r.reaction
$$;

revoke execute on function public.post_reaction_counts(uuid[]) from public, anon;
grant execute on function public.post_reaction_counts(uuid[]) to authenticated;
