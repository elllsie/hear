-- Store stable bilingual definitions for podcast difficult words.
-- Safe to run repeatedly before regenerating AI insights with prompt v2.

begin;

alter table public.episode_difficult_words
  add column if not exists meaning_zh text,
  add column if not exists meaning_en text;

update public.episode_difficult_words
set meaning_zh = meaning
where meaning_zh is null or btrim(meaning_zh) = '';

commit;
