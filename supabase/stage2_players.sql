-- myCoach – Stufe 2a: Kader in der Cloud
-- Im Supabase SQL-Editor ausführen (nach schema.sql).

create table if not exists public.players (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.teams(id) on delete cascade,
  first_name text,
  last_name text,
  number int,
  position text,
  created_at timestamptz not null default now()
);
create index if not exists idx_players_team on public.players(team_id);

alter table public.players enable row level security;

drop policy if exists "read players" on public.players;
create policy "read players" on public.players
  for select using (public.is_team_member(team_id));
drop policy if exists "trainer write players" on public.players;
create policy "trainer write players" on public.players
  for insert with check (public.is_team_trainer(team_id));
drop policy if exists "trainer update players" on public.players;
create policy "trainer update players" on public.players
  for update using (public.is_team_trainer(team_id));
drop policy if exists "trainer delete players" on public.players;
create policy "trainer delete players" on public.players
  for delete using (public.is_team_trainer(team_id));

-- Ereignis kann einen echten Spieler referenzieren (Name bleibt zusätzlich).
alter table public.match_events
  add column if not exists player_id uuid references public.players(id);
