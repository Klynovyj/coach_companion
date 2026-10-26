-- myCoach – Stufe 25: Sperre je Wettbewerb + Startdatum mitsynchronisieren.
-- Im Supabase SQL-Editor ausfuehren.

alter table public.players
  add column if not exists suspension_competition text,
  add column if not exists suspension_from text;
