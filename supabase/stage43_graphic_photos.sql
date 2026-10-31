-- stage43: Spielerfotos-Schalter in der Grafik (Ergebnis-Grafik: Torschuetzen/
-- Karten mit/ohne Foto). Ergaenzt graphic_settings um show_photos (int 0/1).
-- Im Supabase SQL-Editor ausfuehren (idempotent).

alter table public.graphic_settings
  add column if not exists show_photos int default 0;
