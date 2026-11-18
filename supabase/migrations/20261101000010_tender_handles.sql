-- The Usual — 0010: custom page links (gettheusual.bar/tender/<handle>)
--
-- A handle is an optional, bartender-chosen second name for the page at
-- #/b/<public_id>. It grants nothing: resolve_handle() applies the same
-- visibility check as the page itself, so a handle is only a nicer link for
-- people who could already see the page (regulars, or anyone signed in when the
-- schedule is public). Strangers get "not found" either way.
--
-- Old handles stay reserved for the bartender who used them and keep pointing at
-- their page, so a handle printed on cards or in a bio can't be taken over by
-- someone else. They are freed only when the account is deleted (cascade).
--
-- Clients cannot write handle columns directly (no column grant); set_handle()
-- checks format, reserved words, uniqueness and the 30-day change limit.

alter table public.bartenders
  add column handle            text unique
    check (handle ~ '^[a-z0-9][a-z0-9-]{1,28}[a-z0-9]$' and handle !~ '--'),
  add column handle_changed_at timestamptz;

create table private.handle_history (
  handle       text primary key,
  bartender_id uuid not null references public.bartenders (id) on delete cascade,
  retired_at   timestamptz not null default now()
);
create index handle_history_bartender_idx on private.handle_history (bartender_id);
revoke all on private.handle_history from anon, authenticated, public;

-- Words that would look official or clash with app routes.
create or replace function private.is_reserved_handle(p text)
returns boolean
language sql immutable
set search_path = ''
as $$
  select p = any (array[
    'about', 'abuse', 'account', 'admin', 'administrator', 'api', 'app', 'bar', 'bars',
    'bartender', 'bartenders', 'billing', 'code', 'contact', 'edit', 'gettheusual', 'help',
    'home', 'info', 'invite', 'join', 'login', 'logout', 'me', 'mod', 'moderator', 'new',
    'null', 'official', 'onboarding', 'post', 'press', 'privacy', 'profile', 'regular',
    'regulars', 'root', 'schedule', 'security', 'settings', 'signin', 'signup', 'staff',
    'support', 'team', 'tender', 'terms', 'the-usual', 'theusual', 'undefined', 'usual',
    'welcome', 'www'
  ])
$$;

-- Set, change or remove (null / '') the caller's handle. Returns the stored handle.
-- Errors: handle_invalid, handle_reserved, handle_taken, handle_cooldown.
create or replace function public.set_handle(p_handle text)
returns text
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_new     text := nullif(lower(btrim(coalesce(p_handle, ''))), '');
  v_old     text;
  v_changed timestamptz;
begin
  if v_uid is null then
    raise exception 'not_signed_in' using errcode = '42501';
  end if;
  select handle, handle_changed_at into v_old, v_changed
    from public.bartenders where id = v_uid for update;
  if not found then
    raise exception 'not_a_bartender' using errcode = '42501';
  end if;
  if v_new is not distinct from v_old then
    return v_old;
  end if;

  if v_new is not null then
    if v_new !~ '^[a-z0-9][a-z0-9-]{1,28}[a-z0-9]$' or v_new ~ '--' then
      raise exception 'handle_invalid' using errcode = '22023';
    end if;
    if private.is_reserved_handle(v_new) then
      raise exception 'handle_reserved' using errcode = '22023';
    end if;
    if exists (select 1 from public.bartenders where handle = v_new)
       or exists (select 1 from private.handle_history where handle = v_new and bartender_id <> v_uid) then
      raise exception 'handle_taken' using errcode = '23505';
    end if;
    -- Taking back one of your own old handles is always allowed.
    if v_changed > now() - interval '30 days'
       and not exists (select 1 from private.handle_history where handle = v_new and bartender_id = v_uid) then
      raise exception 'handle_cooldown' using errcode = '22023';
    end if;
  end if;

  if v_old is not null then
    insert into private.handle_history (handle, bartender_id) values (v_old, v_uid)
      on conflict (handle) do update set retired_at = now();
  end if;
  if v_new is not null then
    delete from private.handle_history where handle = v_new;
  end if;
  -- Removing a handle doesn't reset the clock, so remove + re-add can't skip the limit.
  update public.bartenders
     set handle = v_new,
         handle_changed_at = case when v_new is null then handle_changed_at else now() end
   where id = v_uid;
  return v_new;
exception
  when unique_violation then  -- two people claiming the same new handle at once
    raise exception 'handle_taken' using errcode = '23505';
end
$$;

-- Current or old handle → the page, only if the caller may see that page.
-- Returns the current handle too, so old links can show the new one.
create or replace function public.resolve_handle(p_handle text)
returns table (public_id text, handle text)
language sql stable security definer
set search_path = ''
as $$
  select b.public_id, b.handle
    from public.bartenders b
   where b.id = coalesce(
           (select x.id from public.bartenders x where x.handle = lower(btrim(p_handle))),
           (select hh.bartender_id from private.handle_history hh where hh.handle = lower(btrim(p_handle))))
     and private.can_view_schedule(b.id)
$$;

revoke all on function public.set_handle(text), public.resolve_handle(text) from public, anon;
revoke all on function private.is_reserved_handle(text) from public, anon, authenticated;
grant execute on function public.set_handle(text), public.resolve_handle(text) to authenticated;
