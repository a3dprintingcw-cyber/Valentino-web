-- Fresha side-by-side sync. Run once after schema.sql.
-- Fresha appointments are copied into public.blocks with source = 'fresha',
-- so customers on the website can't book over them.

alter table public.blocks add column if not exists source text not null default 'manual';
create index if not exists blocks_source_idx on public.blocks (source);

-- Replaces all future Fresha blocks with the current list from Fresha's calendar feed.
-- Called only by the fresha-sync function (service role).
create or replace function public.replace_fresha_blocks(p_events jsonb)
returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  delete from public.blocks where source = 'fresha' and ends_at > now() - interval '1 day';
  insert into public.blocks (starts_at, ends_at, reason, source)
  select (e->>'s')::timestamptz, (e->>'e')::timestamptz, coalesce(e->>'t','Fresha booking'), 'fresha'
    from jsonb_array_elements(p_events) e
   where (e->>'e')::timestamptz > now() - interval '1 day'
     and (e->>'e')::timestamptz > (e->>'s')::timestamptz;
  get diagnostics n = row_count;
  return n;
end;
$$;
revoke all on function public.replace_fresha_blocks(jsonb) from public, anon, authenticated;
