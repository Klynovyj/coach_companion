-- myCoach – Stufe 24: Spielerbewertung wieder PRO TRAINER (jeder bewertet
-- eigenstaendig, angezeigt wird der Schnitt ueber alle Trainer).
-- Macht Stufe 20 (geteilte Note) rueckgaengig. Im Supabase SQL-Editor ausfuehren.

-- 1) Verwaiste Zeilen ohne Benutzer entfernen (verfaelschen sonst den Schnitt).
delete from public.player_ratings where user_id is null or user_id = '';

-- 2) Unique je (Spiel, Spieler) entfernen, Unique je (Spiel, Spieler, Benutzer).
drop index if exists public.player_ratings_match_player;

create unique index if not exists player_ratings_match_player_user
  on public.player_ratings (match_id, player_id, user_id);

-- 3) Schreibrecht: jeder Trainer nur die EIGENE Zeile (user_id = auth.uid()).
drop policy if exists "trainer write player_ratings" on public.player_ratings;
drop policy if exists "own write player_ratings" on public.player_ratings;
create policy "own write player_ratings" on public.player_ratings
  for all
  using (public.is_team_trainer(team_id) and user_id = auth.uid()::text)
  with check (public.is_team_trainer(team_id) and user_id = auth.uid()::text);
