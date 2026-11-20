-- Valentino The Barber: booking database
-- Run this whole file once in Supabase: SQL Editor > New query > paste > Run.
-- Times are stored as timestamptz and checked in Curaçao time (America/Curacao, UTC-4).

create extension if not exists btree_gist;
create extension if not exists pgcrypto;

-- ---------- tables ----------

create table if not exists public.services (
  id          text primary key,
  name        text not null,
  description text not null default '',
  category    text not null default 'Haircuts',
  minutes     int  not null check (minutes between 5 and 240),
  price       numeric(8,2) not null check (price >= 0),
  sort        int  not null default 0,
  active      boolean not null default true
);

-- opening hours per weekday (0 = Sunday ... 6 = Saturday)
-- windows: [["09:00","12:00"],["14:00","18:00"]]; empty array = closed
create table if not exists public.hours (
  dow     int primary key check (dow between 0 and 6),
  windows jsonb not null default '[]'::jsonb
);

-- time Valentino is unavailable (day off, vacation, house call, lunch overrun)
create table if not exists public.blocks (
  id         uuid primary key default gen_random_uuid(),
  starts_at  timestamptz not null,
  ends_at    timestamptz not null check (ends_at > starts_at),
  reason     text not null default '',
  created_at timestamptz not null default now()
);

create table if not exists public.bookings (
  id           uuid primary key default gen_random_uuid(),
  starts_at    timestamptz not null,
  ends_at      timestamptz not null check (ends_at > starts_at),
  items        jsonb not null default '[]'::jsonb,   -- snapshot: [{id,name,minutes,price}]
  total        numeric(8,2) not null default 0,
  name         text not null,
  phone        text not null,
  email        text,
  notes        text,
  status       text not null default 'booked' check (status in ('booked','cancelled','done','no_show')),
  source       text not null default 'online' check (source in ('online','admin')),
  cancel_token uuid not null default gen_random_uuid(),
  created_at   timestamptz not null default now(),
  -- the database itself refuses two active bookings that overlap
  constraint no_double_booking exclude using gist (tstzrange(starts_at, ends_at) with &&) where (status = 'booked')
);
create index if not exists bookings_start_idx on public.bookings (starts_at);

create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);

-- ---------- helpers ----------

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

-- ---------- API access (row level security below decides what each role really sees) ----------

grant usage on schema public to anon, authenticated;
grant select on public.services, public.hours to anon;
grant select, insert, update, delete on public.services, public.hours, public.blocks, public.bookings to authenticated;
grant select on public.admins to authenticated;

-- ---------- row level security ----------

alter table public.services enable row level security;
alter table public.hours    enable row level security;
alter table public.blocks   enable row level security;
alter table public.bookings enable row level security;
alter table public.admins   enable row level security;

drop policy if exists services_read  on public.services;
drop policy if exists services_admin on public.services;
create policy services_read  on public.services for select using (active or public.is_admin());
create policy services_admin on public.services for all using (public.is_admin()) with check (public.is_admin());

drop policy if exists hours_read  on public.hours;
drop policy if exists hours_admin on public.hours;
create policy hours_read  on public.hours for select using (true);
create policy hours_admin on public.hours for all using (public.is_admin()) with check (public.is_admin());

drop policy if exists blocks_admin on public.blocks;
create policy blocks_admin on public.blocks for all using (public.is_admin()) with check (public.is_admin());

-- customers never read the bookings table directly; they use the functions below
drop policy if exists bookings_admin on public.bookings;
create policy bookings_admin on public.bookings for all using (public.is_admin()) with check (public.is_admin());

drop policy if exists admins_self on public.admins;
create policy admins_self on public.admins for select using (user_id = auth.uid());

-- ---------- public functions (called from the website) ----------

-- busy time ranges between two dates, without any customer details
create or replace function public.get_busy(p_from date, p_to date)
returns table (starts_at timestamptz, ends_at timestamptz)
language sql stable security definer set search_path = public as $$
  with r as (
    select (p_from::timestamp at time zone 'America/Curacao') as a,
           ((p_to + 1)::timestamp at time zone 'America/Curacao') as b
  )
  select b.starts_at, b.ends_at from public.bookings b, r
   where b.status = 'booked' and b.starts_at < r.b and b.ends_at > r.a
  union all
  select k.starts_at, k.ends_at from public.blocks k, r
   where k.starts_at < r.b and k.ends_at > r.a;
$$;

create or replace function public.book_appointment(
  p_services text[], p_start timestamptz, p_name text, p_phone text,
  p_email text default null, p_notes text default null)
returns json
language plpgsql security definer set search_path = public as $$
declare
  v_items   jsonb;
  v_minutes int;
  v_total   numeric;
  v_count   int;
  v_end     timestamptz;
  v_local   timestamp;
  v_dow     int;
  v_windows jsonb;
  v_ok      boolean := false;
  w         jsonb;
  v_digits  text := regexp_replace(coalesce(p_phone,''), '\D', '', 'g');
  v_row     public.bookings;
begin
  if coalesce(trim(p_name),'') = '' or length(v_digits) < 7 then
    raise exception 'Please enter your name and a valid phone number.' using errcode = 'P0001';
  end if;
  if length(p_name) > 80 or length(coalesce(p_notes,'')) > 500 or length(coalesce(p_email,'')) > 120 then
    raise exception 'Some details are too long.' using errcode = 'P0001';
  end if;
  if p_services is null or array_length(p_services,1) is null or array_length(p_services,1) > 4 then
    raise exception 'Pick between one and four services.' using errcode = 'P0001';
  end if;

  select jsonb_agg(jsonb_build_object('id',s.id,'name',s.name,'minutes',s.minutes,'price',s.price) order by s.sort),
         sum(s.minutes), sum(s.price), count(*)
    into v_items, v_minutes, v_total, v_count
    from public.services s
   where s.id = any(p_services) and s.active;
  if v_count is distinct from (select count(distinct x) from unnest(p_services) x) then
    raise exception 'One of the services is no longer available.' using errcode = 'P0001';
  end if;

  v_end   := p_start + make_interval(mins => v_minutes);
  v_local := p_start at time zone 'America/Curacao';

  if p_start < now() + interval '30 minutes' then
    raise exception 'That time has already passed. Please pick a later time.' using errcode = 'P0001';
  end if;
  if p_start > now() + interval '45 days' then
    raise exception 'You can book up to 45 days ahead.' using errcode = 'P0001';
  end if;
  if extract(minute from v_local)::int % 15 <> 0 then
    raise exception 'Please pick one of the listed times.' using errcode = 'P0001';
  end if;

  v_dow := extract(dow from v_local)::int;
  select windows into v_windows from public.hours where dow = v_dow;
  for w in select * from jsonb_array_elements(coalesce(v_windows,'[]'::jsonb)) loop
    if v_local::time >= (w->>0)::time and (v_end at time zone 'America/Curacao')::time <= (w->>1)::time
       and (v_end at time zone 'America/Curacao')::date = v_local::date then
      v_ok := true;
    end if;
  end loop;
  if not v_ok then
    raise exception 'The shop is not open for that whole appointment. Please pick another time.' using errcode = 'P0001';
  end if;

  -- one booking at a time, so two people can't grab the same slot
  perform pg_advisory_xact_lock(4242);

  if exists (select 1 from public.blocks k where k.starts_at < v_end and k.ends_at > p_start) then
    raise exception 'Sorry, that time was just taken. Please pick another.' using errcode = 'P0001';
  end if;

  if (select count(*) from public.bookings b
       where b.status = 'booked' and b.starts_at > now()
         and regexp_replace(b.phone, '\D', '', 'g') = v_digits) >= 2 then
    raise exception 'You already have two upcoming bookings. Please call the shop to book more.' using errcode = 'P0001';
  end if;

  begin
    insert into public.bookings (starts_at, ends_at, items, total, name, phone, email, notes)
    values (p_start, v_end, v_items, v_total, trim(p_name), trim(p_phone), nullif(trim(p_email),''), nullif(trim(p_notes),''))
    returning * into v_row;
  exception when exclusion_violation then
    raise exception 'Sorry, that time was just taken. Please pick another.' using errcode = 'P0001';
  end;

  return json_build_object('id', v_row.id, 'token', v_row.cancel_token,
                           'starts_at', v_row.starts_at, 'ends_at', v_row.ends_at,
                           'items', v_row.items, 'total', v_row.total);
end;
$$;

create or replace function public.get_booking(p_token uuid)
returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('starts_at', starts_at, 'ends_at', ends_at, 'items', items,
                           'total', total, 'name', name, 'status', status)
    from public.bookings where cancel_token = p_token;
$$;

create or replace function public.cancel_booking(p_token uuid)
returns json
language plpgsql security definer set search_path = public as $$
declare v_row public.bookings;
begin
  update public.bookings set status = 'cancelled'
   where cancel_token = p_token and status = 'booked' and starts_at > now() + interval '1 hour'
  returning * into v_row;
  if v_row.id is null then
    raise exception 'This booking can''t be cancelled online anymore. Please call the shop.' using errcode = 'P0001';
  end if;
  return json_build_object('ok', true);
end;
$$;

revoke all on function public.book_appointment(text[], timestamptz, text, text, text, text) from public;
revoke all on function public.get_busy(date, date) from public;
revoke all on function public.get_booking(uuid) from public;
revoke all on function public.cancel_booking(uuid) from public;
grant execute on function public.book_appointment(text[], timestamptz, text, text, text, text) to anon, authenticated;
grant execute on function public.get_busy(date, date) to anon, authenticated;
grant execute on function public.get_booking(uuid) to anon, authenticated;
grant execute on function public.cancel_booking(uuid) to anon, authenticated;

-- ---------- starting data (from his Fresha menu) ----------

insert into public.services (id, name, description, category, minutes, price, sort) values
  ('adult',       'Adult haircut',             'Cut and style, no beard', 'Haircuts',          30, 30, 1),
  ('cutbeard',    'Haircut and beard',         'Includes beard oil',      'Haircuts',          30, 30, 2),
  ('kids',        'Kids haircut',              'Under 15 years',          'Kids',              30, 20, 3),
  ('teens',       'Kids 15+',                  '15 years and up',         'Kids',              30, 25, 4),
  ('lineup',      'Shave: line up',            'Haircut not included',    'Shave and details', 15, 10, 5),
  ('lineupbeard', 'Shave: line up and beard',  'Haircut not included',    'Shave and details', 20, 16, 6),
  ('brows',       'Brows fix',                 'Clean up the eyebrows',   'Shave and details', 10,  5, 7)
on conflict (id) do nothing;

insert into public.hours (dow, windows) values
  (0, '[]'), (1, '[]'),
  (2, '[["09:00","12:00"],["14:00","18:00"]]'),
  (3, '[["09:00","12:00"],["14:00","18:00"]]'),
  (4, '[["09:00","12:00"],["14:00","18:00"]]'),
  (5, '[["09:00","12:00"],["14:00","18:00"]]'),
  (6, '[["09:00","12:00"],["14:00","18:00"]]')
on conflict (dow) do nothing;
