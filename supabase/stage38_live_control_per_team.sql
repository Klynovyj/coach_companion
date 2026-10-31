-- stage38: Live-Erfassung pro Seite (eigene Mannschaft / Gegner) uebernehmbar.
-- Ergaenzt die Cloud-Tabelle matches um einen zweiten Controller fuer die
-- Gegner-Erfassung. live_controller steuert weiterhin die eigene Mannschaft +
-- Uhr/Phasen. Im Supabase SQL-Editor ausfuehren (idempotent).

alter table public.matches
  add column if not exists live_controller_opp text,
  add column if not exists live_controller_opp_name text;
