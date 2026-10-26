-- myCoach – Stufe B: Sichtbarkeit für Spieler einschränken.
-- Spieler (Rolle 'spieler') dürfen Bewertungen, Nominierung, Aufstellung und
-- Trainer-Notizen NICHT mehr lesen. Gespräche nur die eigenen (verknüpften
-- Spieler über member_players). Trainer/Admin sehen alles wie bisher.
-- Nach stage28 im SQL-Editor ausführen.

-- Nur-Trainer-Lesen für sensible Bereiche (Bewertungen/Nominierung/Aufstellung/
-- Trainer-Notizen). Spieler-des-Monats bleibt bewusst für alle sichtbar.
do $$
declare t text;
begin
  foreach t in array array[
    'player_ratings','match_ratings',
    'match_nominations','lineups','lineup_entries',
    'player_notes','note_categories'
  ] loop
    execute format('drop policy if exists "read %1$s" on public.%1$I', t);
    execute format(
      'create policy "read %1$s" on public.%1$I for select '
      'using (public.is_team_trainer(team_id))', t);
  end loop;
end $$;

-- Gespräche: Trainer sehen alles; Spieler nur Gespräche ihrer verknüpften
-- Spielerprofile (member_players). Cast auf text, da die Bereichs-IDs als Text
-- gespiegelt werden, member_players.player_id aber uuid ist.
drop policy if exists "read player_talks" on public.player_talks;
create policy "read player_talks" on public.player_talks
  for select using (
    public.is_team_trainer(team_id)
    or exists (
      select 1 from public.member_players mp
      where mp.team_id = player_talks.team_id
        and mp.user_id = auth.uid()
        and mp.player_id::text = player_talks.player_id::text
    )
  );
