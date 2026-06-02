create table if not exists public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.learning_progress (
  user_id uuid not null references auth.users(id) on delete cascade,
  book_id text not null,
  last_index integer not null default 0,
  updated_at timestamptz not null default now(),
  primary key (user_id, book_id)
);

create table if not exists public.favorite_words (
  user_id uuid not null references auth.users(id) on delete cascade,
  book_id text not null,
  word_id text not null,
  updated_at timestamptz not null default now(),
  primary key (user_id, book_id, word_id)
);

alter table public.profiles enable row level security;
alter table public.learning_progress enable row level security;
alter table public.favorite_words enable row level security;

drop policy if exists "profiles_select_own" on public.profiles;
create policy "profiles_select_own"
on public.profiles for select
using (auth.uid() = user_id);

drop policy if exists "profiles_insert_own" on public.profiles;
create policy "profiles_insert_own"
on public.profiles for insert
with check (auth.uid() = user_id);

drop policy if exists "profiles_update_own" on public.profiles;
create policy "profiles_update_own"
on public.profiles for update
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

drop policy if exists "profiles_delete_own" on public.profiles;
create policy "profiles_delete_own"
on public.profiles for delete
using (auth.uid() = user_id);

drop policy if exists "learning_progress_select_own" on public.learning_progress;
create policy "learning_progress_select_own"
on public.learning_progress for select
using (auth.uid() = user_id);

drop policy if exists "learning_progress_insert_own" on public.learning_progress;
create policy "learning_progress_insert_own"
on public.learning_progress for insert
with check (auth.uid() = user_id);

drop policy if exists "learning_progress_update_own" on public.learning_progress;
create policy "learning_progress_update_own"
on public.learning_progress for update
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

drop policy if exists "learning_progress_delete_own" on public.learning_progress;
create policy "learning_progress_delete_own"
on public.learning_progress for delete
using (auth.uid() = user_id);

drop policy if exists "favorite_words_select_own" on public.favorite_words;
create policy "favorite_words_select_own"
on public.favorite_words for select
using (auth.uid() = user_id);

drop policy if exists "favorite_words_insert_own" on public.favorite_words;
create policy "favorite_words_insert_own"
on public.favorite_words for insert
with check (auth.uid() = user_id);

drop policy if exists "favorite_words_update_own" on public.favorite_words;
create policy "favorite_words_update_own"
on public.favorite_words for update
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

drop policy if exists "favorite_words_delete_own" on public.favorite_words;
create policy "favorite_words_delete_own"
on public.favorite_words for delete
using (auth.uid() = user_id);
