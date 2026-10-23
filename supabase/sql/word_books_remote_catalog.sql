-- Versioned, backend-managed word-book catalog.
-- Apply once in the Supabase SQL editor before using publish_word_book.py.

create table if not exists public.word_books (
    book_id text primary key,
    title text not null check (length(trim(title)) > 0),
    language text not null check (language in ('english', 'german')),
    content_version text not null check (length(trim(content_version)) > 0),
    data_url text not null check (data_url like 'https://%'),
    audio_path_prefix text,
    sort_order integer not null default 0,
    is_active boolean not null default false,
    updated_at timestamptz not null default now(),
    check (audio_path_prefix is null or (
        audio_path_prefix not like '/%' and audio_path_prefix not like '%..%'
    ))
);

alter table public.word_books enable row level security;

drop policy if exists "Public can read active word books" on public.word_books;
create policy "Public can read active word books"
on public.word_books for select
to anon, authenticated
using (is_active = true);

grant select on public.word_books to anon, authenticated;

create or replace function public.touch_word_books_updated_at()
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

drop trigger if exists word_books_touch_updated_at on public.word_books;
create trigger word_books_touch_updated_at
before update on public.word_books
for each row execute function public.touch_word_books_updated_at();

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('word-book-content', 'word-book-content', true, 26214400, array['application/json'])
on conflict (id) do update set
    public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "Public can read word book content" on storage.objects;
create policy "Public can read word book content"
on storage.objects for select
to anon, authenticated
using (bucket_id = 'word-book-content');

