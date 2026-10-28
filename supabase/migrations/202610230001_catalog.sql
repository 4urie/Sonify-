-- Run once in the SQL editor of your existing Supabase project.
begin;

create table public.songs (
  id uuid primary key default gen_random_uuid(),
  title text not null check (length(btrim(title)) > 0),
  artist text not null check (length(btrim(artist)) > 0),
  album text not null default '',
  audio_path text not null check (length(btrim(audio_path)) > 0),
  artwork_path text,
  duration_ms integer check (duration_ms > 0),
  created_at timestamptz not null default now()
);
create index songs_created_at_id_idx on public.songs (created_at desc, id);
alter table public.songs enable row level security;
revoke all on public.songs from anon, authenticated;
grant select on public.songs to anon, authenticated;
create policy "Public catalog reads" on public.songs for select to anon, authenticated using (true);

-- strpos performs literal substring search: %, commas, quotes, and parentheses
-- in user input are ordinary characters, not filter syntax or wildcards.
create function public.search_songs(search_term text default '', page_offset integer default 0, page_size integer default 50)
returns setof public.songs
language sql stable security invoker set search_path = ''
as $$
  select * from public.songs
  where strpos(lower(title), lower(coalesce(search_term, ''))) > 0
     or strpos(lower(artist), lower(coalesce(search_term, ''))) > 0
  order by created_at desc, id
  limit least(greatest(page_size, 1), 50)
  offset greatest(page_offset, 0);
$$;
revoke all on function public.search_songs(text, integer, integer) from public;
grant execute on function public.search_songs(text, integer, integer) to anon, authenticated;

-- Fail on conflicting bucket names instead of changing access for existing data.
insert into storage.buckets (id, name, public, allowed_mime_types)
values ('music', 'music', true, array['audio/mpeg', 'audio/mp4', 'audio/aac', 'audio/ogg', 'audio/flac', 'audio/wav', 'audio/x-wav']),
       ('artwork', 'artwork', true, array['image/jpeg', 'image/png', 'image/webp']);
-- No client INSERT/UPDATE/DELETE policies are granted for storage.objects.
-- Dashboard administrators upload files; public buckets serve downloads.
-- Restrictive guards also protect these buckets if this existing project has
-- permissive object-write policies intended for unrelated buckets.
create policy "Sonify blocks client uploads" on storage.objects as restrictive
  for insert to anon, authenticated with check (bucket_id not in ('music', 'artwork'));
create policy "Sonify blocks client object updates" on storage.objects as restrictive
  for update to anon, authenticated using (bucket_id not in ('music', 'artwork'))
  with check (bucket_id not in ('music', 'artwork'));
create policy "Sonify blocks client object deletes" on storage.objects as restrictive
  for delete to anon, authenticated using (bucket_id not in ('music', 'artwork'));
commit;
