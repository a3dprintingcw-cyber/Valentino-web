-- Valentino The Barber: two-way sync with Fresha
-- Run after schema.sql. Safe to run again.
--
-- Fresha -> site: the fresha-sync function reads Fresha's calendar export link every 5 minutes
--                 and stores those times here, so the website shows them as taken.
-- Site -> Fresha: the calendar-feed function publishes website bookings and blocks as a calendar
--                 link, which Fresha imports as blocked time.

create table if not exists public.external_busy (
  uid        text primary key,
  source     text not null default 'fresha',
  starts_at  timestamptz not null,
  ends_at    timestamptz not null check (ends_at > starts_at),
  title      text not null default '',
  updated_at timestamptz not null default now()
);
create index if not exists external_busy_start_idx on public.external_busy (starts_at);

alter table public.external_busy enable row level security;
drop policy if exists external_admin on public.external_busy;
create policy external_admin on public.external_busy for select using (public.is_admin());
grant select on public.external_busy to authenticated;

-- replaces all rows of one source in one go (called by the sync function with the service key)
create or replace function public.replace_external_busy(p_source text, p_rows jsonb)
returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  delete from public.external_busy where source = p_source;
  insert into public.external_busy (uid, source, starts_at, ends_at, title)
  select r->>'uid', p_source, (r->>'starts_at')::timestamptz, (r->>'ends_at')::timestamptz, coalesce(r->>'title','')
    from jsonb_array_elements(coalesce(p_rows,'[]'::jsonb)) r
   where (r->>'ends_at')::timestamptz > (r->>'starts_at')::timestamptz
  on conflict (uid) do update set starts_at = excluded.starts_at, ends_at = excluded.ends_at,
                                  title = excluded.title, updated_at = now();
  get diagnostics n = row_count;
  return n;
end;
$$;
revoke all on function public.replace_external_busy(text, jsonb) from public, anon, authenticated;
grant execute on function public.replace_external_busy(text, jsonb) to service_role;

-- website availability now also excludes Fresha appointments
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
   where k.starts_at < r.b and k.ends_at > r.a
  union all
  select x.starts_at, x.ends_at from public.external_busy x, r
   where x.starts_at < r.b and x.ends_at > r.a;
$$;

-- booking check: refuse times taken in Fresha too
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

  perform pg_advisory_xact_lock(4242);

  if exists (select 1 from public.blocks k where k.starts_at < v_end and k.ends_at > p_start)
     or exists (select 1 from public.external_busy x where x.starts_at < v_end and x.ends_at > p_start) then
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
revoke all on function public.book_appointment(text[], timestamptz, text, text, text, text) from public;
grant execute on function public.book_appointment(text[], timestamptz, text, text, text, text) to anon, authenticated;
revoke all on function public.get_busy(date, date) from public;
grant execute on function public.get_busy(date, date) to anon, authenticated;

-- ---------- sync settings (private schema, not reachable from the website API) ----------

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table if not exists private.sync_config (
  id            int primary key default 1 check (id = 1),
  fresha_url    text,
  feed_token    text not null default replace(gen_random_uuid()::text, '-', ''),
  sync_secret   text not null default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
  last_sync_at  timestamptz,
  last_sync_count int,
  last_error    text
);
insert into private.sync_config (id) values (1) on conflict do nothing;

-- for the edge functions (service key only)
create or replace function public.get_sync_config()
returns json language sql stable security definer set search_path = public, private as $$
  select json_build_object('fresha_url', fresha_url, 'feed_token', feed_token, 'sync_secret', sync_secret)
    from private.sync_config where id = 1;
$$;
create or replace function public.set_sync_status(p_count int, p_error text)
returns void language sql security definer set search_path = public, private as $$
  update private.sync_config set last_sync_at = now(), last_sync_count = p_count, last_error = p_error where id = 1;
$$;
revoke all on function public.get_sync_config() from public, anon, authenticated;
revoke all on function public.set_sync_status(int, text) from public, anon, authenticated;
grant execute on function public.get_sync_config() to service_role;
grant execute on function public.set_sync_status(int, text) to service_role;

-- for the admin page (Valentino only)
create or replace function public.admin_sync_settings()
returns json language plpgsql stable security definer set search_path = public, private as $$
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  return (select json_build_object('fresha_url', fresha_url, 'feed_token', feed_token,
                                   'last_sync_at', last_sync_at, 'last_sync_count', last_sync_count, 'last_error', last_error)
            from private.sync_config where id = 1);
end; $$;
create or replace function public.admin_set_fresha_url(p_url text)
returns void language plpgsql security definer set search_path = public, private as $$
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  if p_url is not null and p_url <> '' and p_url !~* '^(https|webcal)://' then
    raise exception 'That does not look like a calendar link.' using errcode = 'P0001';
  end if;
  update private.sync_config set fresha_url = nullif(trim(p_url), ''), last_error = null where id = 1;
  if coalesce(trim(p_url), '') = '' then delete from public.external_busy where source = 'fresha'; end if;
  perform private.run_fresha_sync();
end; $$;
revoke all on function public.admin_sync_settings() from public, anon;
revoke all on function public.admin_set_fresha_url(text) from public, anon;
grant execute on function public.admin_sync_settings() to authenticated;
grant execute on function public.admin_set_fresha_url(text) to authenticated;

-- ---------- run the Fresha sync every 5 minutes ----------

create extension if not exists pg_cron;
create extension if not exists pg_net;

create or replace function private.run_fresha_sync()
returns void language plpgsql security definer set search_path = public, private as $$
declare c private.sync_config;
begin
  select * into c from private.sync_config where id = 1;
  if c.fresha_url is null then return; end if;
  perform net.http_post(
    url := 'https://jvvcfefyxcgbnybhqldz.supabase.co/functions/v1/fresha-sync',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-sync-secret', c.sync_secret),
    body := '{}'::jsonb);
end; $$;

select cron.unschedule('fresha-sync') where exists (select 1 from cron.job where jobname = 'fresha-sync');
select cron.schedule('fresha-sync', '*/5 * * * *', 'select private.run_fresha_sync()');
