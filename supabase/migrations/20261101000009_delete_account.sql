-- The Usual — 0009: delete my account
--
-- Deleting the auth.users row cascades through profiles → bartenders → bars,
-- shifts, posts, invites, connections (both sides), blocks (both sides),
-- reactions, replies, regular_details and regular_notes (both sides).
--
-- Photos: Supabase blocks deleting storage.objects with SQL, so the app removes
-- the caller's files ({uid}/… in avatars, post-photos, regular-photos) through
-- the Storage API first, then calls this function.
--
-- The invite rate-limit log has no foreign key, so it is cleared here too.

create or replace function public.delete_my_account()
returns void
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'not_signed_in' using errcode = '42501';
  end if;
  delete from private.invite_attempts where user_id = v_uid;
  delete from auth.users where id = v_uid;
end
$$;

revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
