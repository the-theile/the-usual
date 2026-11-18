-- The Usual — 0012: how long moderation records are kept
--
-- * Closed reports are deleted 12 months after they were closed. Open reports
--   stay until a moderator handles them. This applies whether or not the people
--   involved still have accounts.
-- * Moderator log entries and ended suspensions are deleted after 12 months too.
-- * Runs nightly with pg_cron, and also whenever a moderator resolves a report.
-- * Removing a reported post also deletes its photo (the moderator tools do this
--   through the Storage API, which this policy allows), so reports only ever keep
--   a copy of the text.

create or replace function private.purge_old_moderation()
returns void
language sql volatile security definer
set search_path = ''
as $$
  delete from private.reports     where status <> 'open' and resolved_at < now() - interval '12 months';
  delete from private.mod_actions where created_at < now() - interval '12 months';
  delete from private.suspensions where until < now() - interval '12 months';
$$;

revoke all on function private.purge_old_moderation() from public, anon, authenticated;

-- Moderators may delete the photo of a post they removed after a report.
create policy "usual: moderators delete reported photos" on storage.objects for delete to authenticated
  using (bucket_id = 'post-photos' and private.is_moderator() and private.is_reported_photo(name));

-- Run the clean-up when a report is resolved, as well as nightly.
create or replace function private.purge_after_resolve()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  perform private.purge_old_moderation();
  return null;
end
$$;

create trigger reports_purge_after_resolve
  after update of status on private.reports
  for each statement execute function private.purge_after_resolve();

-- Nightly at 04:17 UTC. Skipped where pg_cron isn't available (e.g. a local test database).
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron with schema pg_catalog;
    perform cron.schedule('the-usual-purge-moderation', '17 4 * * *', 'select private.purge_old_moderation()');
  end if;
end
$$;
