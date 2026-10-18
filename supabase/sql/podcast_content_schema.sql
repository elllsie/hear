-- 听会儿 · English Podcast Phase 1
-- Purpose: RSS metadata storage only (Podcast + Episode).
-- Safe to run repeatedly in Supabase SQL Editor.
-- This migration does not download audio or start transcript processing.

begin;

-- ---------------------------------------------------------------------------
-- 1. Podcast sources maintained by the developer
-- ---------------------------------------------------------------------------

create table if not exists public.podcasts (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  description text not null default '',
  rss_url text not null,
  website_url text,
  cover_url text,
  language text not null default 'en',
  category text not null,
  host text,
  region text,
  level text,
  rights_status text not null default 'unknown',
  is_active boolean not null default true,
  last_synced_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint podcasts_rss_url_unique unique (rss_url),
  constraint podcasts_name_not_blank check (length(btrim(name)) > 0),
  constraint podcasts_rss_url_not_blank check (length(btrim(rss_url)) > 0),
  constraint podcasts_language_check check (language in ('en')),
  constraint podcasts_category_check check (
    category in ('easy', 'thinking', 'world', 'future')
  ),
  constraint podcasts_rights_status_check check (
    rights_status in ('unknown', 'reviewed', 'approved', 'rejected')
  ),
  constraint podcasts_level_check check (
    level is null or level in ('A1', 'A2', 'B1', 'B2', 'C1', 'C2', 'B1-C1', 'B2-C1')
  )
);

comment on table public.podcasts is
  'Curated English Podcast sources. RSS metadata only; rights approval is explicit.';

comment on column public.podcasts.rights_status is
  'unknown/reviewed/approved/rejected. Public clients can only read approved sources.';

-- ---------------------------------------------------------------------------
-- 2. Episode metadata collected from RSS
-- ---------------------------------------------------------------------------

create table if not exists public.episodes (
  id uuid primary key default gen_random_uuid(),
  podcast_id uuid not null references public.podcasts(id) on delete cascade,
  guid text not null,
  title text not null,
  description text not null default '',
  audio_url text not null,
  source_url text,
  cover_url text,
  duration_seconds integer,
  publish_date timestamptz,
  transcript_status text not null default 'none',
  editorial_status text not null default 'imported',
  audio_fingerprint text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint episodes_podcast_guid_unique unique (podcast_id, guid),
  constraint episodes_guid_not_blank check (length(btrim(guid)) > 0),
  constraint episodes_title_not_blank check (length(btrim(title)) > 0),
  constraint episodes_audio_url_not_blank check (length(btrim(audio_url)) > 0),
  constraint episodes_duration_nonnegative check (
    duration_seconds is null or duration_seconds >= 0
  ),
  constraint episodes_transcript_status_check check (
    transcript_status in ('none', 'processing', 'ready', 'failed')
  ),
  constraint episodes_editorial_status_check check (
    editorial_status in ('imported', 'selected', 'published', 'archived')
  )
);

comment on table public.episodes is
  'RSS Episode metadata. audio_url points to the publisher media URL; MP3 is not stored here.';

comment on column public.episodes.guid is
  'RSS guid, or Collector-generated stable fallback hash when the feed has no guid.';

comment on column public.episodes.transcript_status is
  'none/processing/ready/failed. RSS collection always creates episodes as none.';

-- ---------------------------------------------------------------------------
-- 3. Query and deduplication indexes
-- ---------------------------------------------------------------------------

create index if not exists podcasts_active_category_idx
  on public.podcasts (is_active, category);

create index if not exists episodes_podcast_publish_date_idx
  on public.episodes (podcast_id, publish_date desc);

create index if not exists episodes_editorial_publish_date_idx
  on public.episodes (editorial_status, publish_date desc);

create index if not exists episodes_transcript_status_idx
  on public.episodes (transcript_status);

-- ---------------------------------------------------------------------------
-- 4. Keep updated_at correct without trusting clients
-- ---------------------------------------------------------------------------

create or replace function public.set_podcast_content_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists podcasts_set_updated_at on public.podcasts;
create trigger podcasts_set_updated_at
before update on public.podcasts
for each row execute function public.set_podcast_content_updated_at();

drop trigger if exists episodes_set_updated_at on public.episodes;
create trigger episodes_set_updated_at
before update on public.episodes
for each row execute function public.set_podcast_content_updated_at();

-- ---------------------------------------------------------------------------
-- 5. Row Level Security
--
-- Collector uses the Supabase service-role key on the backend and can bypass
-- these policies. The iOS app uses the publishable/anon key and is read-only.
-- ---------------------------------------------------------------------------

alter table public.podcasts enable row level security;
alter table public.episodes enable row level security;

drop policy if exists "podcasts_read_approved" on public.podcasts;
create policy "podcasts_read_approved"
on public.podcasts
for select
to anon, authenticated
using (
  is_active = true
  and rights_status = 'approved'
);

drop policy if exists "episodes_read_published" on public.episodes;
create policy "episodes_read_published"
on public.episodes
for select
to anon, authenticated
using (
  editorial_status = 'published'
  and exists (
    select 1
    from public.podcasts p
    where p.id = episodes.podcast_id
      and p.is_active = true
      and p.rights_status = 'approved'
  )
);

-- Explicit API privileges. There are deliberately no insert/update/delete
-- grants for anon or authenticated roles in Phase 1.
grant usage on schema public to anon, authenticated;
grant select on table public.podcasts to anon, authenticated;
grant select on table public.episodes to anon, authenticated;

revoke insert, update, delete, truncate, references, trigger
  on table public.podcasts from anon, authenticated;
revoke insert, update, delete, truncate, references, trigger
  on table public.episodes from anon, authenticated;

commit;

-- ---------------------------------------------------------------------------
-- Verification queries (run manually after the migration)
-- ---------------------------------------------------------------------------

-- Confirm both tables exist:
-- select table_name
-- from information_schema.tables
-- where table_schema = 'public'
--   and table_name in ('podcasts', 'episodes')
-- order by table_name;

-- Confirm constraints and indexes:
-- select indexname, indexdef
-- from pg_indexes
-- where schemaname = 'public'
--   and tablename in ('podcasts', 'episodes')
-- order by tablename, indexname;

-- After Collector import, inspect counts:
-- select p.name, count(e.id) as episode_count, max(e.publish_date) as latest_episode
-- from public.podcasts p
-- left join public.episodes e on e.podcast_id = p.id
-- group by p.id, p.name
-- order by p.name;

-- To expose one approved test Podcast and selected Episodes to the iOS app,
-- review rights first, then run explicit updates such as:
-- update public.podcasts
-- set rights_status = 'approved'
-- where id = '<podcast-uuid>';
--
-- update public.episodes
-- set editorial_status = 'published'
-- where id in ('<episode-uuid-1>', '<episode-uuid-2>');

