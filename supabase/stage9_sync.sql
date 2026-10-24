-- Stufe 9: Team-Zeile teilen (Kurzname/Name/Logo) + Ball-/Materialdienst
-- synchronisieren + Realtime für ALLE Bereichstabellen absichern.
--
-- Im Supabase SQL-Editor ausführen. Idempotent (mehrfach ausführbar).

-- 1) Ball-/Materialdienst-Konfiguration (JSON) je Team.
alter table public.teams add column if not exists material_duty text;

-- 2) Realtime für die Team-Zeile selbst (Kurzname/Name/Logo/Materialdienst).
--    teams hat keine team_id-Spalte; die App abonniert per id-Filter.
--    Die Lese-Policy "read teams" (is_team_member(id)) existiert bereits, damit
--    Mitglieder die Realtime-Änderungen empfangen dürfen.
do $$ begin
  alter publication supabase_realtime add table public.teams;
exception when duplicate_object then null; end $$;

-- 3) Sicherstellen, dass ALLE Bereichstabellen in der Realtime-Publication sind
--    (falls eine ältere Stufe eingespielt wurde). So erscheinen Spielergespräche,
--    Aufgaben, Notizen, Kategorien, Abwesenheiten, Bewertungen usw. sofort bei
--    allen Trainern. Idempotent.
do $$
declare t text;
  tables text[] := array[
    'matches','players','match_events','event_mentions',
    'lineups','lineup_entries','match_nominations','card_entries',
    'player_notes','note_categories','player_ratings','todos',
    'todo_topics','player_talks','player_absences','player_stats',
    'opponent_teams','opponent_players'
  ];
begin
  foreach t in array tables loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null;
    end;
  end loop;
end $$;
