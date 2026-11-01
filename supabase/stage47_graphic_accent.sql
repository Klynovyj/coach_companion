-- stage47: Akzentfarbe (z.B. Gold) fuer die Grafiken.
-- Ergaenzt graphic_settings um accent (Hex-Farbe, z.B. '#D4AF37'); null = Weiss.
-- Im Supabase SQL-Editor ausfuehren (idempotent).

alter table public.graphic_settings
  add column if not exists accent text;
