-- myCoach – Stufe 20: Spielerbewertung wieder EINE geteilte Note je Spiel/Spieler
-- (macht Stufe 18 fuer player_ratings rueckgaengig; match_ratings bleibt pro Benutzer).
-- Nach den vorherigen Stufen im Supabase SQL-Editor ausfuehren.

-- 1) Doppelte Zeilen entfernen: pro (match_id, player_id) die neueste behalten.
delete from public.player_ratings pr
where exists (
  select 1 from public.player_ratings p2
  where p2.match_id = pr.match_id
    and p2.player_id = pr.player_id
    and (coalesce(p2.created_at, '') > coalesce(pr.created_at, '')
         or (coalesce(p2.created_at, '') = coalesce(pr.created_at, '')
             and p2.ctid > pr.ctid))
);

-- 2) Unique je Benutzer entfernen, Unique je (Spiel, Spieler) setzen.
drop index if exists public.player_ratings_match_player_user;

create unique index if not exists player_ratings_match_player
  on public.player_ratings (match_id, player_id);

-- 3) Schreibrecht: jeder Trainer des Teams (geteilte Note, nicht mehr nur eigene).
drop policy if exists "own write player_ratings" on public.player_ratings;
drop policy if exists "trainer write player_ratings" on public.player_ratings;
create policy "trainer write player_ratings" on public.player_ratings
  for all
  using (public.is_team_trainer(team_id))
  with check (public.is_team_trainer(team_id));
