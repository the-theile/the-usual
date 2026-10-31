-- The Usual — 0001: tables
-- Phone numbers live only in auth.users (never exposed through the API).
-- Every public table gets RLS in 0003.

create schema if not exists private;

-- ===== Small helpers used by defaults / checks =====

-- Cryptographically random int in [0, n). gen_random_uuid() uses pg_strong_random;
-- the first 8 hex chars of a v4 UUID are fully random.
create or replace function private.random_int(n int)
returns int
language sql volatile
set search_path = ''
as $$
  select ((('x' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8))::bit(32)::bigint) % n)::int
$$;

-- 32 hex chars, 122 random bits. Used for QR / link tokens.
create or replace function private.random_token()
returns text
language sql volatile
set search_path = ''
as $$
  select replace(gen_random_uuid()::text, '-', '')
$$;

-- 10 chars from an unambiguous alphabet (~49 bits). Used in profile URLs
-- instead of auth user ids.
create or replace function private.random_public_id()
returns text
language plpgsql volatile
set search_path = ''
as $$
declare
  alphabet constant text := 'abcdefghjkmnpqrstuvwxyz23456789';
  result text := '';
begin
  for i in 1..10 loop
    result := result || substr(alphabet, private.random_int(length(alphabet)) + 1, 1);
  end loop;
  return result;
end
$$;

create or replace function private.is_valid_timezone(tz text)
returns boolean
language sql stable
set search_path = ''
as $$
  select exists (select 1 from pg_catalog.pg_timezone_names where name = tz)
$$;

-- ===== People =====

create table public.profiles (
  id           uuid primary key references auth.users (id) on delete cascade,
  display_name text not null check (char_length(btrim(display_name)) between 1 and 40),
  created_at   timestamptz not null default now()
);

create table public.bartenders (
  id                  uuid primary key references public.profiles (id) on delete cascade,
  public_id           text not null unique default private.random_public_id(),
  bio                 text not null default '' check (char_length(bio) <= 300),
  photo_path          text,
  timezone            text not null default 'America/Los_Angeles'
                        check (private.is_valid_timezone(timezone)),
  schedule_visibility text not null default 'regulars'
                        check (schedule_visibility in ('public', 'regulars')),
  created_at          timestamptz not null default now()
);

create table public.bars (
  id           uuid primary key default gen_random_uuid(),
  bartender_id uuid not null references public.bartenders (id) on delete cascade,
  name         text not null check (char_length(btrim(name)) between 1 and 60),
  area         text not null default '' check (char_length(area) <= 60),
  sort         int  not null default 0,
  created_at   timestamptz not null default now(),
  unique (id, bartender_id)          -- target for composite FKs below
);
create index bars_bartender_idx on public.bars (bartender_id);

-- ===== Relationships =====

create table public.connections (
  bartender_id      uuid not null references public.bartenders (id) on delete cascade,
  regular_id        uuid not null references public.profiles (id) on delete cascade,
  source            text not null check (source in ('qr', 'code', 'link')),
  created_at        timestamptz not null default now(),
  -- Reserved for later versions (unused in V1, not client-writable):
  messaging_enabled boolean not null default false,  -- bartender turns DMs on per regular
  notify            boolean not null default false,  -- regular opts in to the bell
  primary key (bartender_id, regular_id),
  check (bartender_id <> regular_id)
);
create index connections_regular_idx on public.connections (regular_id);

create table public.blocks (
  bartender_id uuid not null references public.bartenders (id) on delete cascade,
  regular_id   uuid not null references public.profiles (id) on delete cascade,
  created_at   timestamptz not null default now(),
  primary key (bartender_id, regular_id),
  check (bartender_id <> regular_id)
);
create index blocks_regular_idx on public.blocks (regular_id);

-- ===== Invites =====
-- kind 'daily': sayable code + QR token, valid for one bar day (rolls over 5am local).
-- kind 'link' : token only, valid 7 days.

create table public.invites (
  id           uuid primary key default gen_random_uuid(),
  bartender_id uuid not null references public.bartenders (id) on delete cascade,
  kind         text not null check (kind in ('daily', 'link')),
  code         text,                -- display form, e.g. TIKI-MOON-42
  code_norm    text,                -- normalised: TIKIMOON42
  token        text not null unique default private.random_token(),
  bar_day      date,
  valid_from   timestamptz not null default now(),
  expires_at   timestamptz not null,
  revoked_at   timestamptz,
  created_at   timestamptz not null default now(),
  check ((kind = 'daily') = (code is not null and code_norm is not null and bar_day is not null))
);
create unique index invites_one_daily_per_day
  on public.invites (bartender_id, bar_day)
  where kind = 'daily' and revoked_at is null;
create index invites_code_norm_idx on public.invites (code_norm) where kind = 'daily';
create index invites_bartender_idx on public.invites (bartender_id, created_at desc);

-- Rate limiting for code entry. Private schema: not reachable through the API.
create table private.invite_attempts (
  id           bigint generated always as identity primary key,
  user_id      uuid not null,
  ip           text,
  ok           boolean not null,
  attempted_at timestamptz not null default now()
);
create index invite_attempts_user_idx on private.invite_attempts (user_id, attempted_at desc);
create index invite_attempts_ip_idx   on private.invite_attempts (ip, attempted_at desc) where ip is not null;

-- ===== Posts =====

create table public.posts (
  id           uuid primary key default gen_random_uuid(),
  bartender_id uuid not null references public.bartenders (id) on delete cascade,
  body         text not null default '' check (char_length(body) <= 500),
  photo_path   text,
  created_at   timestamptz not null default now(),
  check (char_length(btrim(body)) > 0 or photo_path is not null)
);
create index posts_bartender_idx on public.posts (bartender_id, created_at desc);

-- ===== Schedule =====
-- Times are local to the bartender's timezone. end_time null = "until close".
-- end_time < start_time means the shift runs past midnight.

create table public.shifts (
  id           uuid primary key default gen_random_uuid(),
  bartender_id uuid not null references public.bartenders (id) on delete cascade,
  bar_id       uuid not null,
  shift_date   date not null,
  start_time   time not null,
  end_time     time,
  note         text not null default '' check (char_length(note) <= 80),
  created_at   timestamptz not null default now(),
  foreign key (bar_id, bartender_id) references public.bars (id, bartender_id) on delete cascade
);
create index shifts_bartender_date_idx on public.shifts (bartender_id, shift_date);

create table public.shift_patterns (
  id           uuid primary key default gen_random_uuid(),
  bartender_id uuid not null references public.bartenders (id) on delete cascade,
  bar_id       uuid not null,
  weekdays     smallint[] not null
                 check (cardinality(weekdays) between 1 and 7 and weekdays <@ '{1,2,3,4,5,6,7}'::smallint[]),
  start_time   time not null,
  end_time     time,
  note         text not null default '' check (char_length(note) <= 80),
  starts_on    date not null default current_date,
  ends_on      date,
  created_at   timestamptz not null default now(),
  unique (id, bartender_id),
  foreign key (bar_id, bartender_id) references public.bars (id, bartender_id) on delete cascade,
  check (ends_on is null or ends_on >= starts_on)
);
create index shift_patterns_bartender_idx on public.shift_patterns (bartender_id);

-- One row per changed/cancelled occurrence. When not cancelled, the row holds the
-- full replacement values (end_time null still means "until close").
create table public.shift_exceptions (
  pattern_id      uuid not null,
  bartender_id    uuid not null,
  occurrence_date date not null,
  cancelled       boolean not null default false,
  bar_id          uuid,
  start_time      time,
  end_time        time,
  note            text not null default '' check (char_length(note) <= 80),
  created_at      timestamptz not null default now(),
  primary key (pattern_id, occurrence_date),
  foreign key (pattern_id, bartender_id) references public.shift_patterns (id, bartender_id) on delete cascade,
  foreign key (bar_id, bartender_id) references public.bars (id, bartender_id) on delete cascade,
  check (cancelled or (bar_id is not null and start_time is not null))
);
