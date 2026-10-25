-- Stufe 14: Push-Benachrichtigungen (FCM) – Geräte-Tokens.
--
-- Jedes Gerät registriert hier sein FCM-Token. Die Edge-Function „notify-live"
-- liest die Tokens der Team-Mitglieder (per service_role) und schickt die Push.
--
-- Im Supabase SQL-Editor ausführen. Idempotent.

create table if not exists public.device_tokens (
  token text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  platform text,
  updated_at timestamptz not null default now()
);

alter table public.device_tokens enable row level security;

-- Jeder verwaltet nur seine eigenen Tokens.
drop policy if exists "own device_tokens" on public.device_tokens;
create policy "own device_tokens" on public.device_tokens
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());
