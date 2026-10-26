-- myCoach – Stufe 27: Aufstellungs-Vorschläge zulassen.
-- Die Eindeutigkeit „eine Aufstellung je Trainer" gilt nur fuer echte
-- Aufstellungen (suggestion_of IS NULL), nicht fuer Vorschlaege.
-- Im Supabase SQL-Editor ausfuehren (nach stage26).

drop index if exists public.lineups_match_team_creator;

create unique index if not exists lineups_match_team_creator
  on public.lineups (match_id, team_id, created_by)
  where suggestion_of is null;
