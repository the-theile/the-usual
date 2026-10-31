-- The Usual — 0003: privileges + Row Level Security
-- Default-deny: revoke everything, then grant only what the app needs.
-- Writes that must keep invariants (connections, blocks, invites) go through
-- SECURITY DEFINER functions in 0004 — clients cannot write those tables directly.

grant usage on schema private to anon, authenticated;
revoke all on all tables in schema private from anon, authenticated, public;
grant execute on all functions in schema private to anon, authenticated;

revoke all on all tables in schema public from anon, authenticated;

grant select on public.profiles, public.bartenders, public.bars, public.connections,
                public.blocks, public.invites, public.posts, public.shifts,
                public.shift_patterns, public.shift_exceptions
  to authenticated;

grant insert (id, display_name), update (display_name) on public.profiles to authenticated;
grant insert (id, bio, photo_path, timezone, schedule_visibility),
      update (bio, photo_path, timezone, schedule_visibility)
  on public.bartenders to authenticated;               -- public_id is never client-set
grant insert, update, delete on public.bars, public.shifts, public.shift_patterns,
                                public.shift_exceptions to authenticated;
grant insert (bartender_id, body, photo_path), delete on public.posts to authenticated;
grant delete on public.connections to authenticated;   -- a regular can unfollow

alter table public.profiles         enable row level security;
alter table public.bartenders       enable row level security;
alter table public.bars             enable row level security;
alter table public.connections      enable row level security;
alter table public.blocks           enable row level security;
alter table public.invites          enable row level security;
alter table public.posts            enable row level security;
alter table public.shifts           enable row level security;
alter table public.shift_patterns   enable row level security;
alter table public.shift_exceptions enable row level security;

-- ===== profiles =====
create policy profiles_select on public.profiles for select to authenticated
  using (private.can_see_profile(id));
create policy profiles_insert on public.profiles for insert to authenticated
  with check (id = (select auth.uid()));
create policy profiles_update on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

-- ===== bartenders =====
create policy bartenders_select on public.bartenders for select to authenticated
  using (private.can_view_schedule(id));
create policy bartenders_insert on public.bartenders for insert to authenticated
  with check (id = (select auth.uid())
              and (photo_path is null or photo_path like (select auth.uid())::text || '/%'));
create policy bartenders_update on public.bartenders for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid())
              and (photo_path is null or photo_path like (select auth.uid())::text || '/%'));

-- ===== bars / shifts / patterns / exceptions (schedule visibility) =====
create policy bars_select on public.bars for select to authenticated
  using (private.can_view_schedule(bartender_id));
create policy bars_write on public.bars for all to authenticated
  using (bartender_id = (select auth.uid())) with check (bartender_id = (select auth.uid()));

create policy shifts_select on public.shifts for select to authenticated
  using (private.can_view_schedule(bartender_id));
create policy shifts_write on public.shifts for all to authenticated
  using (bartender_id = (select auth.uid())) with check (bartender_id = (select auth.uid()));

create policy shift_patterns_select on public.shift_patterns for select to authenticated
  using (private.can_view_schedule(bartender_id));
create policy shift_patterns_write on public.shift_patterns for all to authenticated
  using (bartender_id = (select auth.uid())) with check (bartender_id = (select auth.uid()));

create policy shift_exceptions_select on public.shift_exceptions for select to authenticated
  using (private.can_view_schedule(bartender_id));
create policy shift_exceptions_write on public.shift_exceptions for all to authenticated
  using (bartender_id = (select auth.uid())) with check (bartender_id = (select auth.uid()));

-- ===== posts (connected regulars only, never public) =====
create policy posts_select on public.posts for select to authenticated
  using (private.can_view_bartender(bartender_id));
create policy posts_insert on public.posts for insert to authenticated
  with check (bartender_id = (select auth.uid())
              and (photo_path is null or photo_path like (select auth.uid())::text || '/%'));
create policy posts_delete on public.posts for delete to authenticated
  using (bartender_id = (select auth.uid()));

-- ===== connections =====
-- A regular never sees a connection to someone who blocked them (belt and braces:
-- blocking also deletes the row).
create policy connections_select on public.connections for select to authenticated
  using (bartender_id = (select auth.uid())
         or (regular_id = (select auth.uid()) and not private.is_blocked(bartender_id)));
create policy connections_delete_by_regular on public.connections for delete to authenticated
  using (regular_id = (select auth.uid()));

-- ===== blocks: only the bartender who blocked can see them =====
create policy blocks_select on public.blocks for select to authenticated
  using (bartender_id = (select auth.uid()));

-- ===== invites: owner only (codes/tokens are secrets) =====
create policy invites_select on public.invites for select to authenticated
  using (bartender_id = (select auth.uid()));
