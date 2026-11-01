-- The Usual — 0012: "I'm coming tonight"
--
-- A regular taps "I'm coming tonight" on the page of a bartender they follow,
-- on a bar day that bartender is working. The bartender sees who is coming
-- (with faces and usual drinks, from my_regulars). Other regulars of that
-- bartender see only a count ("3 others are coming"), never names.
-- A check-in belongs to one bar day (5am → 5am in the bartender's time zone),
-- so it resets on its own.

create table public.checkins (
  bartender_id uuid not null references public.bartenders (id) on delete cascade,
  regular_id   uuid not null references public.profiles (id) on delete cascade,
  bar_day      date not null,
  created_at   timestamptz not null default now(),
  primary key (bartender_id, regular_id, bar_day),
  check (bartender_id <> regular_id)
);
create index checkins_regular_idx on public.checkins (regular_id);

-- Writes go through check_in(); reads: your own check-ins, or check-ins from
-- your current regulars if you are the bartender.
revoke all on public.checkins from anon, authenticated;
grant select on public.checkins to authenticated;
alter table public.checkins enable row level security;
create policy checkins_select on public.checkins for select to authenticated
  using (regular_id = (select auth.uid())
         or (bartender_id = (select auth.uid())
             and exists (select 1 from public.connections c
                          where c.bartender_id = checkins.bartender_id and c.regular_id = checkins.regular_id)));

-- Say you're coming tonight (p_coming = true) or take it back (false).
-- Only for a bartender you follow (not blocked), and only on a bar day they're working.
create or replace function public.check_in(p_bartender uuid, p_coming boolean)
returns boolean
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_day date;
begin
  if v_uid is null then
    raise exception 'not_signed_in' using errcode = '42501';
  end if;
  if not (private.is_connected(p_bartender) and not private.is_blocked(p_bartender)) then
    return false;
  end if;
  select private.bar_day(timezone) into v_day from public.bartenders where id = p_bartender;

  if not p_coming then
    delete from public.checkins where bartender_id = p_bartender and regular_id = v_uid and bar_day = v_day;
    return true;
  end if;

  if not exists (select 1 from public.get_schedule(array[p_bartender], v_day, v_day) o where not o.cancelled) then
    return false;   -- not working tonight
  end if;
  insert into public.checkins (bartender_id, regular_id, bar_day) values (p_bartender, v_uid, v_day)
  on conflict do nothing;

  -- Keep the table small: old nights aren't needed.
  delete from public.checkins where bar_day < v_day - 7;
  return true;
end
$$;

-- For the regular's screens: per bartender tonight, how many OTHER current
-- regulars are coming, and whether you are. Only bartenders you follow.
create or replace function public.tonight_checkins(p_bartenders uuid[])
returns table (bartender_id uuid, others int, me boolean)
language sql stable security definer
set search_path = ''
as $$
  select b.id,
         (select count(*)::int from public.checkins k
            join public.connections c on c.bartender_id = k.bartender_id and c.regular_id = k.regular_id
           where k.bartender_id = b.id and k.bar_day = private.bar_day(b.timezone)
             and k.regular_id <> (select auth.uid())),
         exists (select 1 from public.checkins k
                  where k.bartender_id = b.id and k.bar_day = private.bar_day(b.timezone)
                    and k.regular_id = (select auth.uid()))
    from public.bartenders b
   where b.id = any (p_bartenders)
     and private.is_connected(b.id) and not private.is_blocked(b.id)
$$;

revoke all on function public.check_in(uuid, boolean) from public, anon;
revoke all on function public.tonight_checkins(uuid[]) from public, anon;
grant execute on function public.check_in(uuid, boolean), public.tonight_checkins(uuid[]) to authenticated;
