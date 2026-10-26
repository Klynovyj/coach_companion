-- myCoach – Stufe A: Konto ↔ Spieler-Verknüpfung (n:m)
-- Ein Konto kann mit EINEM ODER MEHREREN Spielerprofilen verknüpft werden.
-- Grundlage für „Spieler sehen nur eigene Gespräche" und die Sichtbarkeits-
-- Regeln (Stufe B). Nach den bisherigen Stages im SQL-Editor ausführen.

create table if not exists public.member_players (
  team_id    uuid not null references public.teams(id)   on delete cascade,
  user_id    uuid not null references auth.users(id)     on delete cascade,
  player_id  uuid not null references public.players(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (team_id, user_id, player_id)
);

create index if not exists idx_member_players_team
  on public.member_players(team_id);
create index if not exists idx_member_players_user
  on public.member_players(team_id, user_id);

alter table public.member_players enable row level security;

-- Lesen: Trainer des Teams sehen alle Zuordnungen; jeder sieht seine eigene.
drop policy if exists "read member_players" on public.member_players;
create policy "read member_players" on public.member_players
  for select using (
    public.is_team_trainer(team_id) or user_id = auth.uid()
  );

-- Anlegen/Ändern/Löschen: nur Trainer des Teams.
drop policy if exists "trainer insert member_players" on public.member_players;
create policy "trainer insert member_players" on public.member_players
  for insert with check (public.is_team_trainer(team_id));

drop policy if exists "trainer delete member_players" on public.member_players;
create policy "trainer delete member_players" on public.member_players
  for delete using (public.is_team_trainer(team_id));

-- Realtime, damit Zuordnungen sofort auf anderen Geräten ankommen.
alter publication supabase_realtime add table public.member_players;
