-- Read-only client access for pre-generated Podcast AI learning content.
-- Safe to run repeatedly after creating episode_ai_insights and
-- episode_difficult_words.

begin;

alter table public.episode_ai_insights enable row level security;
alter table public.episode_difficult_words enable row level security;

drop policy if exists "episode_ai_insights_read_published" on public.episode_ai_insights;
create policy "episode_ai_insights_read_published"
on public.episode_ai_insights for select to anon, authenticated
using (
  exists (
    select 1 from public.episodes e
    join public.podcasts p on p.id = e.podcast_id
    where e.id = episode_ai_insights.episode_id
      and e.editorial_status = 'published'
      and p.is_active = true
      and p.rights_status = 'approved'
  )
);

drop policy if exists "episode_difficult_words_read_published" on public.episode_difficult_words;
create policy "episode_difficult_words_read_published"
on public.episode_difficult_words for select to anon, authenticated
using (
  exists (
    select 1 from public.episodes e
    join public.podcasts p on p.id = e.podcast_id
    where e.id = episode_difficult_words.episode_id
      and e.editorial_status = 'published'
      and p.is_active = true
      and p.rights_status = 'approved'
  )
);

grant select on table public.episode_ai_insights to anon, authenticated;
grant select on table public.episode_difficult_words to anon, authenticated;
revoke insert, update, delete, truncate, references, trigger
  on table public.episode_ai_insights from anon, authenticated;
revoke insert, update, delete, truncate, references, trigger
  on table public.episode_difficult_words from anon, authenticated;

commit;
