-- myCoach – Stufe 33: Persönlicher Posteingang (Benachrichtigungen je Trainer).
-- Pro Empfaenger adressiert (nicht team-weit wie activities). Im Supabase
-- SQL-Editor ausfuehren.

create table if not exists public.inbox (
  id uuid primary key,
  team_id uuid not null references public.teams(id) on delete cascade,
  recipient_id uuid not null references auth.users(id) on delete cascade,
  actor_id uuid,
  actor_name text,
  type text,
  title text not null,
  subtitle text,
  link_type text,
  link_id text,
  created_at timestamptz not null default now(),
  read_at timestamptz
);

create index if not exists idx_inbox_recipient
  on public.inbox(recipient_id, created_at desc);

alter table public.inbox enable row level security;

-- Lesen: nur die eigenen Eintraege.
drop policy if exists "read own inbox" on public.inbox;
create policy "read own inbox" on public.inbox
  for select using (recipient_id = auth.uid());

-- Einfuegen: Ausloeser ist Mitglied des Teams. (Der Empfaenger ist in der Praxis
-- immer ein Teamkollege; Lesen bleibt ohnehin auf den Empfaenger beschraenkt.)
drop policy if exists "insert inbox for team member" on public.inbox;
create policy "insert inbox for team member" on public.inbox
  for insert with check (
    exists (
      select 1 from public.team_members m
      where m.team_id = inbox.team_id and m.user_id = auth.uid()
    )
  );

-- Aktualisieren: nur die eigene Zeile (read_at setzen).
drop policy if exists "update own inbox" on public.inbox;
create policy "update own inbox" on public.inbox
  for update using (recipient_id = auth.uid())
  with check (recipient_id = auth.uid());

-- Loeschen: nur die eigenen Eintraege (Aufraeumen).
drop policy if exists "delete own inbox" on public.inbox;
create policy "delete own inbox" on public.inbox
  for delete using (recipient_id = auth.uid());

-- Realtime aktivieren (idempotent).
do $$ begin
  alter publication supabase_realtime add table public.inbox;
exception when duplicate_object then null; end $$;
