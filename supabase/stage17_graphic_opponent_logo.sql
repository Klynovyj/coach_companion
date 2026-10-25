-- myCoach – Stufe 17: optionales Gegner-Logo auf der Startelf-Grafik
-- Nach stage16_graphic_settings.sql im Supabase SQL-Editor ausführen.
--
-- Ergänzt die bestehende Tabelle graphic_settings um einen Schalter
-- (int 0/1), passend zur lokalen Spalte show_opponent_logo.

alter table public.graphic_settings
  add column if not exists show_opponent_logo int default 0;
