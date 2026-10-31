-- stage42: Starker Fuss am Spieler (links/rechts/beide). Mannschaftsweit geteilt.
-- Im Supabase SQL-Editor ausfuehren (idempotent).

alter table public.players
  add column if not exists strong_foot text;
