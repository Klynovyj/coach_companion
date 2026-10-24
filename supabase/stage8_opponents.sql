-- myCoach – Stufe 8: Gegner-Kader (Teams + Spieler) teilen
-- Nach schema.sql / stage2_players.sql im Supabase SQL-Editor ausführen.
--
-- Gegner sind lokal eigene teams/players; in der Cloud werden sie dem OWNER-
-- Team zugeordnet (team_id = eigenes Cloud-Team), damit das ganze Trainerteam
-- denselben Gegnerkader sieht. Fotos/Logos als Data-URL.

create table if not exists public.opponent_teams (
  id text primary key,
  team_id uuid not null references public.teams(id) on delete cascade, -- Owner
  name text not null,
  short_name text,
  logo text,
  fupa_url text
);

create table if not exists public.opponent_players (
  id text primary key,
  team_id uuid not null references public.teams(id) on delete cascade, -- Owner
  opponent_team_id text not null,
  first_name text,
  last_name text,
  number int,
  position text,
  photo text
);
create index if not exists idx_opp_players_opp
  on public.opponent_players(opponent_team_id);

-- Verknüpfung Spiel → Gegner-Team (geteilt).
alter table public.matches add column if not exists opponent_team_id text;

do $$
declare t text;
begin
  foreach t in array array['opponent_teams','opponent_players'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists "read %1$s" on public.%1$I', t);
    execute format(
      'create policy "read %1$s" on public.%1$I for select using (public.is_team_member(team_id))',
      t);
    execute format('drop policy if exists "trainer write %1$s" on public.%1$I', t);
    execute format(
      'create policy "trainer write %1$s" on public.%1$I for all '
      'using (public.is_team_trainer(team_id)) '
      'with check (public.is_team_trainer(team_id))',
      t);
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null;
    end;
  end loop;
end $$;
