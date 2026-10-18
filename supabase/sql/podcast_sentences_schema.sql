-- 听会儿 · timed Podcast transcript sentences
-- Run in Supabase SQL Editor. Safe to run repeatedly.

begin;

create table if not exists public.episode_sentences (
  id uuid primary key default gen_random_uuid(),
  episode_id uuid not null references public.episodes(id) on delete cascade,
  sequence integer not null,
  start_ms integer not null,
  end_ms integer not null,
  english text not null,
  chinese text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint episode_sentences_episode_sequence_unique unique (episode_id, sequence),
  constraint episode_sentences_sequence_nonnegative check (sequence >= 0),
  constraint episode_sentences_time_valid check (start_ms >= 0 and end_ms > start_ms),
  constraint episode_sentences_english_not_blank check (length(btrim(english)) > 0)
);

create index if not exists episode_sentences_episode_time_idx
  on public.episode_sentences (episode_id, start_ms, end_ms);

drop trigger if exists episode_sentences_set_updated_at on public.episode_sentences;
create trigger episode_sentences_set_updated_at
before update on public.episode_sentences
for each row execute function public.set_podcast_content_updated_at();

alter table public.episode_sentences enable row level security;
drop policy if exists "episode_sentences_read_published" on public.episode_sentences;
create policy "episode_sentences_read_published"
on public.episode_sentences for select to anon, authenticated
using (
  exists (
    select 1 from public.episodes e
    join public.podcasts p on p.id = e.podcast_id
    where e.id = episode_sentences.episode_id
      and e.editorial_status = 'published'
      and p.is_active = true
      and p.rights_status = 'approved'
  )
);

grant select on table public.episode_sentences to anon, authenticated;
revoke insert, update, delete, truncate, references, trigger
  on table public.episode_sentences from anon, authenticated;

commit;
