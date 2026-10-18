-- Add German Podcast support without changing existing English content.
begin;

alter table public.podcasts
  drop constraint if exists podcasts_language_check;

alter table public.podcasts
  add constraint podcasts_language_check
  check (language in ('en', 'de'));

alter table public.podcasts
  drop constraint if exists podcasts_level_check;

alter table public.podcasts
  add constraint podcasts_level_check check (
    level is null or level in ('A1', 'A2', 'A1-A2', 'B1', 'B2', 'C1', 'C2', 'B1-C1', 'B2-C1')
  );

create index if not exists podcasts_language_active_category_idx
  on public.podcasts (language, is_active, category);

comment on table public.podcasts is
  'Curated multilingual Podcast sources. Public visibility still requires explicit rights approval.';

commit;
