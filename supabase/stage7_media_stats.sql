-- myCoach – Stufe 7: Medien (Fotos/Logos) + Statistik in der Cloud
-- Nach schema.sql / stage2_players.sql im Supabase SQL-Editor ausführen.
--
-- Fotos & Logos werden (bewusst) als Data-URL direkt in Textspalten gespeichert
-- (kein Storage). So laufen sie über den normalen Sync mit.

alter table public.players add column if not exists photo text;         -- Spielerfoto (Data-URL)
alter table public.teams   add column if not exists logo text;          -- eigenes Vereinslogo
alter table public.matches add column if not exists opponent_logo text; -- Gegner-Logo

-- Spieler-Saison-Statistik (geteilt, aus FuPa)
create table if not exists public.player_stats (
  id text primary key,
  team_id uuid not null references public.teams(id) on delete cascade,
  external_id text,
  first_name text,
  last_name text,
  matches int not null default 0,
  goals int not null default 0,
  assists int not null default 0,
  yellow_cards int not null default 0,
  yellow_red_cards int not null default 0,
  red_cards int not null default 0,
  minutes int not null default 0,
  top_eleven int not null default 0
);

alter table public.player_stats enable row level security;

drop policy if exists "read player_stats" on public.player_stats;
create policy "read player_stats" on public.player_stats
  for select using (public.is_team_member(team_id));

drop policy if exists "trainer write player_stats" on public.player_stats;
create policy "trainer write player_stats" on public.player_stats
  for all using (public.is_team_trainer(team_id))
  with check (public.is_team_trainer(team_id));

do $$ begin
  alter publication supabase_realtime add table public.player_stats;
exception when duplicate_object then null; end $$;
