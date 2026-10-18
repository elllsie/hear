-- 听会儿 · cross-device user state
-- Run once in the Supabase SQL Editor. Safe to run repeatedly.

begin;

create table if not exists public.user_app_state (
  user_id uuid not null references auth.users(id) on delete cascade,
  state_key text not null,
  value jsonb not null,
  updated_at timestamptz not null default now(),
  primary key (user_id, state_key),
  constraint user_app_state_key_not_blank check (length(btrim(state_key)) > 0)
);

comment on table public.user_app_state is
  'Per-account app state such as context words, podcast words, and preferences.';

create or replace function public.set_user_app_state_updated_at()
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

drop trigger if exists user_app_state_set_updated_at on public.user_app_state;
create trigger user_app_state_set_updated_at
before update on public.user_app_state
for each row execute function public.set_user_app_state_updated_at();

alter table public.user_app_state enable row level security;

drop policy if exists "users_read_own_app_state" on public.user_app_state;
create policy "users_read_own_app_state"
on public.user_app_state for select to authenticated
using (auth.uid() = user_id);

drop policy if exists "users_insert_own_app_state" on public.user_app_state;
create policy "users_insert_own_app_state"
on public.user_app_state for insert to authenticated
with check (auth.uid() = user_id);

drop policy if exists "users_update_own_app_state" on public.user_app_state;
create policy "users_update_own_app_state"
on public.user_app_state for update to authenticated
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

drop policy if exists "users_delete_own_app_state" on public.user_app_state;
create policy "users_delete_own_app_state"
on public.user_app_state for delete to authenticated
using (auth.uid() = user_id);

grant select, insert, update, delete on table public.user_app_state to authenticated;
revoke all on table public.user_app_state from anon;

commit;
