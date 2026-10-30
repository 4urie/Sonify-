-- Add a restricted, concurrency-safe insert operation for the sync job.
-- Existing duplicate paths are left untouched.
begin;
create or replace function public.sync_insert_song(
  p_title text, p_artist text, p_album text, p_audio_path text,
  p_artwork_path text, p_duration_ms integer
) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_audio_path, 0));
  if exists (select 1 from public.songs where audio_path = p_audio_path) then
    return false;
  end if;
  insert into public.songs (title, artist, album, audio_path, artwork_path, duration_ms)
  values (p_title, p_artist, p_album, p_audio_path, p_artwork_path, p_duration_ms);
  return true;
end;
$$;
revoke all on function public.sync_insert_song(text, text, text, text, text, integer) from public, anon, authenticated;
grant execute on function public.sync_insert_song(text, text, text, text, text, integer) to service_role;
commit;
