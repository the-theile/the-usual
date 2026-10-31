-- The Usual — 0005: photo storage
-- Private buckets; files live at {bartender_id}/{uuid}.webp|jpg.
-- Reads use the same visibility rules as the rows, so a blocked user loses photos too.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('avatars',     'avatars',     false, 5242880, array['image/webp', 'image/jpeg']),
  ('post-photos', 'post-photos', false, 5242880, array['image/webp', 'image/jpeg'])
on conflict (id) do nothing;

create policy "usual: upload own photos" on storage.objects for insert to authenticated
  with check (bucket_id in ('avatars', 'post-photos')
              and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy "usual: delete own photos" on storage.objects for delete to authenticated
  using (bucket_id in ('avatars', 'post-photos')
         and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy "usual: view avatars" on storage.objects for select to authenticated
  using (bucket_id = 'avatars'
         and private.can_view_schedule(private.try_uuid((storage.foldername(name))[1])));

create policy "usual: view post photos" on storage.objects for select to authenticated
  using (bucket_id = 'post-photos'
         and private.can_view_bartender(private.try_uuid((storage.foldername(name))[1])));
