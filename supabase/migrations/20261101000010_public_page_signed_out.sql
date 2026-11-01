-- The Usual — 0010: signed-out visitors can see a public page
--
-- When a bartender's schedule is "Anyone with my link", people who open their
-- page link without signing in see a read-only preview: name, photo, bio, bars,
-- the next two weeks of shifts and the updates marked Public.
--
-- Signed-out visitors get NO table access. Everything comes from one function
-- that needs the page's public_id, so nobody can list or scrape all public
-- pages without the link. Never returned: regulars-only posts, reactions,
-- replies, who follows whom, phone numbers.
--
-- Blocking can't apply to someone who isn't signed in; a bartender who wants
-- to hide from a blocked person can switch back to "Only my regulars".

-- ===== Helper =====

create or replace function private.is_public_page(b uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (select 1 from public.bartenders where id = b and schedule_visibility = 'public')
$$;

revoke execute on function private.is_public_page(uuid) from public;
grant execute on function private.is_public_page(uuid) to anon, authenticated;

-- ===== The page =====

create or replace function public.public_page(p_public_id text)
returns json
language plpgsql stable security definer
set search_path = ''
as $$
declare
  b public.bartenders;
  today date;
begin
  select * into b from public.bartenders
   where public_id = p_public_id and schedule_visibility = 'public';
  if not found then return null; end if;

  today := private.bar_day(b.timezone);

  return json_build_object(
    'public_id',    b.public_id,
    'display_name', (select display_name from public.profiles where id = b.id),
    'bio',          b.bio,
    'photo_path',   b.photo_path,
    'today',        today,
    'bars', coalesce((
      select json_agg(json_build_object('name', x.name, 'area', x.area) order by x.sort, x.created_at)
        from public.bars x where x.bartender_id = b.id), '[]'::json),
    'shifts', coalesce((
      select json_agg(json_build_object(
               'occurrence_date', s.occurrence_date, 'bar_name', s.bar_name,
               'start_time', s.start_time, 'end_time', s.end_time, 'note', s.note)
             order by s.occurrence_date, s.start_time)
        from public.get_schedule(array[b.id], today, today + 13) s
       where not s.cancelled), '[]'::json),
    'posts', coalesce((
      select json_agg(json_build_object(
               'id', p.id, 'body', p.body, 'photo_path', p.photo_path, 'created_at', p.created_at)
             order by p.created_at desc)
        from (select * from public.posts
               where bartender_id = b.id and visibility = 'public'
               order by created_at desc limit 20) p), '[]'::json)
  );
end
$$;

revoke execute on function public.public_page(text) from public, authenticated;
grant execute on function public.public_page(text) to anon;

-- ===== Photos =====
-- File names are random, so these only open photos the page above links to.

create policy "usual: signed-out view public avatars" on storage.objects for select to anon
  using (bucket_id = 'avatars'
         and private.is_public_page(private.try_uuid((storage.foldername(name))[1])));

create or replace function private.is_public_post_photo(p_path text)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.posts
    where photo_path = p_path and visibility = 'public'
      and private.is_public_page(bartender_id)
  )
$$;

revoke execute on function private.is_public_post_photo(text) from public;
grant execute on function private.is_public_post_photo(text) to anon;

create policy "usual: signed-out view public post photos" on storage.objects for select to anon
  using (bucket_id = 'post-photos' and private.is_public_post_photo(name));
