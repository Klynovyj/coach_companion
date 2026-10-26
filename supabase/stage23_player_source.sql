-- myCoach – Stufe 23: Herkunft der Spieler (FuPa vs. manuell) mitsynchronisieren,
-- damit das Herkunfts-Badge auch auf anderen Geraeten stimmt.
-- Im Supabase SQL-Editor ausfuehren.

alter table public.players
  add column if not exists source text;
