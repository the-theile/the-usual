-- The Usual — 0014: App Store review safety (guideline 1.2, user-generated content)
--
-- Lessons from RaveFAM's review, applied before The Usual is submitted:
--
-- 1. Blocking tells the moderators. Every block (either direction) opens a
--    report with reason 'blocked', so a moderator can look at the blocked person.
--    The blocked person is still never told.
-- 2. Regulars can block a bartender (until now only bartenders could block).
--    Blocking unfollows, hides the bartender's page, schedule, updates and photos
--    from the regular, stops the bartender seeing the regular's profile, and
--    stops codes and links reconnecting them until the regular unblocks.
--    To the bartender it looks exactly like an unfollow.
-- 3. A blocked-terms filter rejects user text containing slurs before it is
--    saved (whole-word match, case-insensitive, plus a simple leetspeak pass).
--    Rejections raise 'content_not_allowed' (SQLSTATE P0001, DETAIL = column);
--    src/lib/toast.js turns that into a friendly message.
--
-- Moderators manage the term list in the SQL editor:
--   insert into private.blocked_terms (term) values ('someword');

-- ===== 1. Content filter =====

create table private.blocked_terms (
  term       text primary key check (term ~ '^[a-z0-9]+( [a-z0-9]+)*$'),
  created_at timestamptz not null default now()
);
revoke all on private.blocked_terms from anon, authenticated, public;

create or replace function private.text_has_blocked_term(p_text text)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select p_text is not null and btrim(p_text) <> '' and exists (
    select 1
      from private.blocked_terms t,
           (select lower(p_text) as plain,
                   translate(lower(p_text), '013457@$', 'oieastas') as leet) s
     where s.plain ~ ('\m' || t.term || '\M')
        or s.leet  ~ ('\m' || t.term || '\M')
  )
$$;

-- Trigger body: TG_ARGV lists the text columns to check. On UPDATE only changed
-- columns are checked, so an old row never blocks an unrelated edit.
create or replace function private.reject_blocked_terms()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  col   text;
  v_new text;
begin
  foreach col in array TG_ARGV loop
    v_new := to_jsonb(NEW) ->> col;
    continue when v_new is null;
    continue when TG_OP = 'UPDATE' and v_new is not distinct from (to_jsonb(OLD) ->> col);
    if private.text_has_blocked_term(v_new) then
      raise exception 'content_not_allowed' using errcode = 'P0001', detail = col;
    end if;
  end loop;
  return NEW;
end
$$;

create trigger profiles_content_filter before insert or update on public.profiles
  for each row execute function private.reject_blocked_terms('display_name');
create trigger bartenders_content_filter before insert or update on public.bartenders
  for each row execute function private.reject_blocked_terms('bio', 'handle');
create trigger bars_content_filter before insert or update on public.bars
  for each row execute function private.reject_blocked_terms('name', 'area');
create trigger posts_content_filter before insert or update on public.posts
  for each row execute function private.reject_blocked_terms('body');
create trigger post_replies_content_filter before insert or update on public.post_replies
  for each row execute function private.reject_blocked_terms('body');
create trigger regular_details_content_filter before insert or update on public.regular_details
  for each row execute function private.reject_blocked_terms('usual');
create trigger shifts_content_filter before insert or update on public.shifts
  for each row execute function private.reject_blocked_terms('note');
create trigger shift_patterns_content_filter before insert or update on public.shift_patterns
  for each row execute function private.reject_blocked_terms('note');
create trigger shift_exceptions_content_filter before insert or update on public.shift_exceptions
  for each row execute function private.reject_blocked_terms('note');

-- Starter list (same as RaveFAM's): slurs that are never acceptable here.
insert into private.blocked_terms (term) values
  ('nigger'), ('niggers'), ('nigga'), ('niggas'),
  ('faggot'), ('faggots'), ('fag'), ('fags'),
  ('kike'), ('kikes'), ('spic'), ('spics'),
  ('chink'), ('chinks'), ('gook'), ('gooks'),
  ('wetback'), ('wetbacks'), ('beaner'), ('beaners'),
  ('raghead'), ('ragheads'), ('towelhead'), ('towelheads'),
  ('tranny'), ('trannies'), ('retard'), ('retards')
on conflict (term) do nothing;

-- ===== 2. Blocks open a moderator report =====

-- Not a reason people can pick in the Report dialog (public.report() checks its
-- own list); only these triggers use it.
alter table private.reports drop constraint reports_reason_check;
alter table private.reports add constraint reports_reason_check
  check (reason in ('spam', 'harassment', 'inappropriate', 'impersonation', 'safety', 'other', 'blocked'));

-- p_blocker blocked p_blocked. Re-blocking while the report is open does nothing
-- (reports_one_open).
create or replace function private.flag_block(p_blocker uuid, p_blocked uuid)
returns void
language sql volatile security definer
set search_path = ''
as $$
  insert into private.reports (reporter_id, reported_user_id, kind, target_id, reason,
                               reported_name, snapshot_body)
  values (p_blocker, p_blocked, 'person', p_blocked, 'blocked',
          coalesce((select display_name from public.profiles where id = p_blocked), ''),
          coalesce((select bio from public.bartenders where id = p_blocked), ''))
  on conflict (reporter_id, kind, target_id) where status = 'open' do nothing
$$;

create or replace function private.blocks_flag_trigger()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  perform private.flag_block(NEW.bartender_id, NEW.regular_id);
  return null;
end
$$;

create trigger blocks_flag after insert on public.blocks
  for each row execute function private.blocks_flag_trigger();

-- ===== 3. Regulars block bartenders =====

create table public.regular_blocks (
  regular_id   uuid not null references public.profiles (id) on delete cascade,
  bartender_id uuid not null references public.bartenders (id) on delete cascade,
  created_at   timestamptz not null default now(),
  primary key (regular_id, bartender_id),
  check (regular_id <> bartender_id)
);
create index regular_blocks_bartender_idx on public.regular_blocks (bartender_id);

-- Writes go through the functions below. Only the regular who blocked sees the row.
revoke all on public.regular_blocks from anon, authenticated;
grant select on public.regular_blocks to authenticated;
grant select, insert, update, delete on public.regular_blocks to service_role;
alter table public.regular_blocks enable row level security;
create policy regular_blocks_select on public.regular_blocks for select to authenticated
  using (regular_id = (select auth.uid()));

create or replace function private.regular_blocks_flag_trigger()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  perform private.flag_block(NEW.regular_id, NEW.bartender_id);
  return null;
end
$$;

create trigger regular_blocks_flag after insert on public.regular_blocks
  for each row execute function private.regular_blocks_flag_trigger();

-- "Blocked" now means either direction, as seen by the caller (the regular):
-- the bartender blocked me, or I blocked the bartender. can_view_bartender,
-- can_view_schedule and connections_select all go through this, so a regular
-- who blocks a bartender loses their page, schedule, updates and photos at once.
create or replace function private.is_blocked(b uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.blocks
    where bartender_id = b and regular_id = (select auth.uid())
  ) or exists (
    select 1 from public.regular_blocks
    where bartender_id = b and regular_id = (select auth.uid())
  )
$$;

-- No path may reconnect a regular to a bartender they blocked. redeem_invite
-- surfaces this as an error the app explains ("unblock them first").
create or replace function private.connections_reject_blocked()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if exists (select 1 from public.regular_blocks
              where regular_id = NEW.regular_id and bartender_id = NEW.bartender_id) then
    raise exception 'you_blocked_them' using errcode = 'P0001';
  end if;
  return NEW;
end
$$;

create trigger connections_reject_blocked before insert on public.connections
  for each row execute function private.connections_reject_blocked();

-- Block a bartender I follow or whose page I can see. Unfollows too.
-- Anything else is a silent no-op.
create or replace function public.block_bartender(p_bartender uuid)
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
  if p_bartender is null or p_bartender = v_uid
     or not exists (select 1 from public.profiles where id = v_uid)
     or not (private.can_view_schedule(p_bartender)
             or exists (select 1 from public.regular_blocks where regular_id = v_uid and bartender_id = p_bartender)) then
    return;
  end if;
  insert into public.regular_blocks (regular_id, bartender_id) values (v_uid, p_bartender)
  on conflict do nothing;
  delete from public.connections where bartender_id = p_bartender and regular_id = v_uid;
end
$$;

-- Unblocking does not reconnect; they would need a fresh code.
create or replace function public.unblock_bartender(p_bartender uuid)
returns void
language sql volatile security definer
set search_path = ''
as $$
  delete from public.regular_blocks where regular_id = (select auth.uid()) and bartender_id = p_bartender
$$;

-- The bartenders I blocked, with their names (their profile is hidden from me now).
create or replace function public.my_blocked_bartenders()
returns table (bartender_id uuid, display_name text, blocked_at timestamptz)
language sql stable security definer
set search_path = ''
as $$
  select rb.bartender_id, p.display_name, rb.created_at
    from public.regular_blocks rb join public.profiles p on p.id = rb.bartender_id
   where rb.regular_id = (select auth.uid())
   order by p.display_name
$$;

revoke all on function public.block_bartender(uuid), public.unblock_bartender(uuid),
                       public.my_blocked_bartenders() from public, anon;
grant execute on function public.block_bartender(uuid), public.unblock_bartender(uuid),
                          public.my_blocked_bartenders() to authenticated;
