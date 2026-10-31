-- The Usual — 0008: regular profiles (photo, "my usual", birthday) + bartender notes
--
-- A regular's extra details live in their own table, not on public.profiles,
-- because profiles rows are also readable by a bartender's regulars. Someone who
-- is both a bartender and a regular must not leak their personal photo/drink to
-- their own regulars. regular_details is readable only by the person themselves
-- and by bartenders they follow (or who blocked them).
--
-- regular_notes are private notes a bartender keeps about one of their regulars.
-- Only that bartender can read or write them; the regular never sees them.

-- ===== Visibility helper =====

-- The caller is a bartender this person follows, or a bartender who blocked them.
create or replace function private.can_see_regular(r uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select r is not null and (
    r = (select auth.uid())
    or exists (select 1 from public.connections c
               where c.bartender_id = (select auth.uid()) and c.regular_id = r)
    or exists (select 1 from public.blocks bl
               where bl.bartender_id = (select auth.uid()) and bl.regular_id = r)
  )
$$;

-- Notes may only be started about your own regulars (connected or blocked).
create or replace function private.is_my_regular(r uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select r is not null and r <> (select auth.uid()) and private.can_see_regular(r)
$$;

create or replace function private.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end
$$;

grant execute on function private.can_see_regular(uuid), private.is_my_regular(uuid) to anon, authenticated;

-- ===== Tables =====

create table public.regular_details (
  id             uuid primary key references public.profiles (id) on delete cascade,
  photo_path     text,
  usual          text not null default '' check (char_length(usual) <= 60),
  birthday_month smallint check (birthday_month between 1 and 12),
  birthday_day   smallint check (birthday_day between 1 and 31),
  created_at     timestamptz not null default now(),
  check ((birthday_month is null) = (birthday_day is null)),
  check (birthday_day is null or birthday_day <= case
           when birthday_month = 2 then 29
           when birthday_month in (4, 6, 9, 11) then 30
           else 31 end)
);

create table public.regular_notes (
  bartender_id uuid not null references public.bartenders (id) on delete cascade,
  regular_id   uuid not null references public.profiles (id) on delete cascade,
  body         text not null check (char_length(btrim(body)) between 1 and 500),
  updated_at   timestamptz not null default now(),
  primary key (bartender_id, regular_id),
  check (bartender_id <> regular_id)
);
create index regular_notes_regular_idx on public.regular_notes (regular_id);

create trigger regular_notes_touch before update on public.regular_notes
  for each row execute function private.touch_updated_at();

-- ===== Privileges + RLS =====

revoke all on public.regular_details, public.regular_notes from anon, authenticated;

grant select on public.regular_details to authenticated;
grant insert (id, photo_path, usual, birthday_month, birthday_day),
      update (photo_path, usual, birthday_month, birthday_day)
  on public.regular_details to authenticated;

grant select, delete on public.regular_notes to authenticated;
grant insert (bartender_id, regular_id, body), update (body) on public.regular_notes to authenticated;

alter table public.regular_details enable row level security;
alter table public.regular_notes   enable row level security;

create policy regular_details_select on public.regular_details for select to authenticated
  using (private.can_see_regular(id));
create policy regular_details_insert on public.regular_details for insert to authenticated
  with check (id = (select auth.uid())
              and (photo_path is null or photo_path like (select auth.uid())::text || '/%'));
create policy regular_details_update on public.regular_details for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid())
              and (photo_path is null or photo_path like (select auth.uid())::text || '/%'));

create policy regular_notes_select on public.regular_notes for select to authenticated
  using (bartender_id = (select auth.uid()));
create policy regular_notes_insert on public.regular_notes for insert to authenticated
  with check (bartender_id = (select auth.uid()) and private.is_my_regular(regular_id));
create policy regular_notes_update on public.regular_notes for update to authenticated
  using (bartender_id = (select auth.uid()))
  with check (bartender_id = (select auth.uid()));
create policy regular_notes_delete on public.regular_notes for delete to authenticated
  using (bartender_id = (select auth.uid()));

-- ===== Photo storage =====
-- Files live at regular-photos/{regular_id}/{uuid}.webp|jpg.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('regular-photos', 'regular-photos', false, 5242880, array['image/webp', 'image/jpeg'])
on conflict (id) do nothing;

create policy "usual: upload own regular photo" on storage.objects for insert to authenticated
  with check (bucket_id = 'regular-photos'
              and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy "usual: delete own regular photo" on storage.objects for delete to authenticated
  using (bucket_id = 'regular-photos'
         and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy "usual: view regular photos" on storage.objects for select to authenticated
  using (bucket_id = 'regular-photos'
         and private.can_see_regular(private.try_uuid((storage.foldername(name))[1])));

-- ===== my_regulars: now with photo, usual, birthday and the bartender's note =====
-- SECURITY INVOKER: RLS on regular_details / regular_notes still applies.

drop function public.my_regulars();
create function public.my_regulars()
returns table (
  regular_id uuid, display_name text, since timestamptz, blocked boolean,
  photo_path text, usual text, birthday_month smallint, birthday_day smallint, note text
)
language sql stable
set search_path = ''
as $$
  select x.regular_id, p.display_name, x.since, x.blocked,
         d.photo_path, coalesce(d.usual, ''), d.birthday_month, d.birthday_day, n.body
    from (
      select c.regular_id, c.created_at as since, false as blocked
        from public.connections c where c.bartender_id = (select auth.uid())
      union all
      select b.regular_id, b.created_at, true
        from public.blocks b where b.bartender_id = (select auth.uid())
    ) x
    join public.profiles p on p.id = x.regular_id
    left join public.regular_details d on d.id = x.regular_id
    left join public.regular_notes n on n.bartender_id = (select auth.uid()) and n.regular_id = x.regular_id
   order by x.blocked, p.display_name
$$;

revoke execute on function public.my_regulars() from public, anon;
grant execute on function public.my_regulars() to authenticated;
