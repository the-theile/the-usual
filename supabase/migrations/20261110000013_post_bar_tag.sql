-- The Usual — 0013: tag a bar on a post
--
-- A post can name one of the bartender's own bars ("The Garage · 2h ago").
-- The composite FK means a bartender can only tag their own bars. Deleting a
-- bar clears the tag (bar_id only; bartender_id stays) and keeps the post.
-- The tag is set when posting and is not client-updatable afterwards.

alter table public.posts add column bar_id uuid;

alter table public.posts
  add constraint posts_bar_fkey foreign key (bar_id, bartender_id)
  references public.bars (id, bartender_id) on delete set null (bar_id);

create index posts_bar_idx on public.posts (bar_id) where bar_id is not null;

grant insert (bar_id) on public.posts to authenticated;
