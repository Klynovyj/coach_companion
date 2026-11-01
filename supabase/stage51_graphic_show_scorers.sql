-- stage51: Torschuetzen-Block ("Ticker") der Ergebnis-Grafik ein-/ausblendbar.
-- show_scorers (0/1, null/1 = an). Im Supabase SQL-Editor ausfuehren (idempotent).

alter table public.graphic_settings
  add column if not exists show_scorers integer;
