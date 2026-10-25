-- myCoach – Stufe 18: Bewertungen pro Benutzer + Spiel-Gesamtnote/Abwesenheit
-- Nach den vorherigen Stufen im Supabase SQL-Editor ausführen.

-- 1) player_ratings: Benutzer-Spalte + Unique je (Spiel, Spieler, Benutzer)
alter table public.player_ratings
  add column if not exists user_id text;

do $$
begin
  -- altes Unique (match_id, player_id) entfernen, falls vorhanden
  if exists (select 1 from pg_constraint
             where conname = 'player_ratings_match_id_player_id_key') then
    alter table public.player_ratings
      drop constraint player_ratings_match_id_player_id_key;
  end if;
exception when others then null;
end $$;

create unique index if not exists player_ratings_match_player_user
  on public.player_ratings (match_id, player_id, user_id);

-- Schreiben nur die EIGENE Zeile (user_id = auth.uid()); Lesen = Team-Mitglied.
drop policy if exists "trainer write player_ratings" on public.player_ratings;
create policy "own write player_ratings" on public.player_ratings
  for all
  using (public.is_team_trainer(team_id) and user_id = auth.uid()::text)
  with check (public.is_team_trainer(team_id) and user_id = auth.uid()::text);

-- 2) match_ratings: Spiel-Gesamtnote + Abwesenheit je Benutzer
create table if not exists public.match_ratings (
  id text primary key,
  team_id uuid not null references public.teams(id) on delete cascade,
  match_id text not null,
  user_id text,
  rating double precision,
  abstained int not null default 0,
  note text,
  created_at text,
  unique (match_id, user_id)
);

alter table public.match_ratings enable row level security;

drop policy if exists "read match_ratings" on public.match_ratings;
create policy "read match_ratings" on public.match_ratings
  for select using (public.is_team_member(team_id));

drop policy if exists "own write match_ratings" on public.match_ratings;
create policy "own write match_ratings" on public.match_ratings
  for all
  using (public.is_team_trainer(team_id) and user_id = auth.uid()::text)
  with check (public.is_team_trainer(team_id) and user_id = auth.uid()::text);

do $$
begin
  alter publication supabase_realtime add table public.match_ratings;
exception when duplicate_object then null;
end $$;
