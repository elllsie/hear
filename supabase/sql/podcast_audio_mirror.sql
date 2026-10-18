-- Stable Podcast audio delivery through a public Supabase Storage bucket.
-- Run once in Supabase SQL Editor before mirror_podcast_audio.py.
begin;

alter table public.episodes
  add column if not exists original_audio_url text,
  add column if not exists audio_storage_path text,
  add column if not exists audio_mirrored_at timestamptz;

update public.episodes
set original_audio_url = audio_url
where original_audio_url is null;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'podcast-audio',
  'podcast-audio',
  true,
  262144000,
  array['audio/mpeg', 'audio/mp3', 'audio/mp4', 'audio/x-m4a', 'audio/aac', 'audio/ogg', 'application/octet-stream']
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "podcast_audio_public_read" on storage.objects;
create policy "podcast_audio_public_read"
on storage.objects for select
to anon, authenticated
using (bucket_id = 'podcast-audio');

comment on column public.episodes.original_audio_url is
  'Publisher enclosure URL retained when audio_url points to the mirrored Storage object.';
comment on column public.episodes.audio_storage_path is
  'Object path inside the podcast-audio Storage bucket.';

commit;
