-- Podcast multi-source V1 pipeline metadata. Safe to run repeatedly.
begin;

alter table public.episodes
  add column if not exists audio_status text not null default 'unchecked',
  add column if not exists audio_mime_type text,
  add column if not exists audio_content_length bigint,
  add column if not exists resolved_audio_url text,
  add column if not exists audio_checked_at timestamptz,
  add column if not exists audio_error text,
  add column if not exists transcript_url text,
  add column if not exists transcript_format text,
  add column if not exists validation_status text not null default 'pending',
  add column if not exists validation_error text,
  add column if not exists capability_snapshot jsonb not null default '{}'::jsonb;

alter table public.episodes drop constraint if exists episodes_audio_status_check;
alter table public.episodes add constraint episodes_audio_status_check check (
  audio_status in ('unchecked', 'available', 'unavailable', 'requires_auth', 'unsupported')
);

alter table public.episodes drop constraint if exists episodes_transcript_format_check;
alter table public.episodes add constraint episodes_transcript_format_check check (
  transcript_format is null or transcript_format in ('vtt', 'srt', 'stt')
);

alter table public.episodes drop constraint if exists episodes_validation_status_check;
alter table public.episodes add constraint episodes_validation_status_check check (
  validation_status in ('pending', 'passed', 'failed')
);

alter table public.episode_sentences
  add column if not exists speaker text,
  add column if not exists source text not null default 'unknown',
  add column if not exists timing_quality text not null default 'unknown',
  add column if not exists alignment_confidence double precision;

alter table public.episode_sentences drop constraint if exists episode_sentences_timing_quality_check;
alter table public.episode_sentences add constraint episode_sentences_timing_quality_check check (
  timing_quality in ('exact', 'approximate', 'unknown')
);

alter table public.episode_sentences drop constraint if exists episode_sentences_alignment_confidence_check;
alter table public.episode_sentences add constraint episode_sentences_alignment_confidence_check check (
  alignment_confidence is null or alignment_confidence between 0 and 1
);

create index if not exists episodes_audio_pipeline_idx
  on public.episodes (audio_status, transcript_status, editorial_status);

commit;
