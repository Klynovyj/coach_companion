-- stage39: Live-Steuerung per Anfrage & Genehmigung.
-- Ergaenzt die Cloud-Tabelle matches um eine offene Uebernahme-Anfrage:
-- live_request_by (User-ID), live_request_by_name, live_request_scope
-- ('own' = eigene + Uhr, 'opp' = Gegner, 'both' = beide). Der Haupt-Ticker
-- genehmigt/lehnt ab. Im Supabase SQL-Editor ausfuehren (idempotent).

alter table public.matches
  add column if not exists live_request_by text,
  add column if not exists live_request_by_name text,
  add column if not exists live_request_scope text;
