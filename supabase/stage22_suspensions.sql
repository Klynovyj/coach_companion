-- myCoach – Stufe 22: Sperren-Zaehler am Spieler (noch abzusitzende Spiele).
-- Im Supabase SQL-Editor ausfuehren.

alter table public.players
  add column if not exists suspended_games int not null default 0;
