-- myCoach – Stufe 32: Zeitstempel der letzten Bearbeitung einer Spiel-Bewertung
-- / eines Spielberichts. Damit sieht jeder Trainer, wann ein Bericht geschrieben
-- oder zuletzt bearbeitet wurde. Im Supabase SQL-Editor ausfuehren.

alter table public.match_ratings
  add column if not exists updated_at timestamptz;

-- Altzeilen: vorhandenen Anlagezeitpunkt uebernehmen (sonst bleibt null und die
-- App zeigt ersatzweise created_at an). created_at ist Text (ISO-String),
-- updated_at timestamptz -> Cast noetig.
update public.match_ratings
  set updated_at = created_at::timestamptz
  where updated_at is null;
