-- The Usual — 0011: one pinned update per bartender
--
-- A pinned post stays at the top of the bartender's page, and its first line
-- shows on their card on the regular home screen, until the bartender pins
-- another post, unpins it, or deletes it. Who can see it is unchanged: the
-- post's own visibility and RLS (0003, 0007) still decide.

alter table public.posts add column pinned_at timestamptz;

-- At most one pinned post per bartender.
create unique index posts_one_pinned_idx on public.posts (bartender_id) where pinned_at is not null;

-- Pin a post (unpinning any other), or pass null to unpin. Own posts only;
-- anything else is a silent no-op.
create or replace function public.pin_post(p_post uuid)
returns void
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if not exists (select 1 from public.bartenders where id = v_uid) then
    raise exception 'not_a_bartender' using errcode = '42501';
  end if;
  if p_post is not null and not exists (select 1 from public.posts where id = p_post and bartender_id = v_uid) then
    return;
  end if;
  update public.posts set pinned_at = null where bartender_id = v_uid and pinned_at is not null and id is distinct from p_post;
  if p_post is not null then
    update public.posts set pinned_at = now() where id = p_post and pinned_at is null;
  end if;
end
$$;

revoke all on function public.pin_post(uuid) from public, anon;
grant execute on function public.pin_post(uuid) to authenticated;
