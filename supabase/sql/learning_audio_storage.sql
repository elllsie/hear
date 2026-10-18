-- Public immutable learning audio. Subscription checks should protect premium
-- features and manifests; common pronunciation files benefit from CDN caching.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('learning-audio', 'learning-audio', true, 10485760, array['audio/mpeg', 'audio/mp4', 'audio/x-m4a'])
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "learning audio public read" on storage.objects;
create policy "learning audio public read"
on storage.objects for select
to anon, authenticated
using (bucket_id = 'learning-audio');
