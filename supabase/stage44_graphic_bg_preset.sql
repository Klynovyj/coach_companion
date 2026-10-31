-- stage44: Eingebautes Hintergrund-Design (Vorlage) fuer die Grafiken.
-- Ergaenzt graphic_settings um bg_preset (z.B. 'stripes'). Im Supabase
-- SQL-Editor ausfuehren (idempotent).

alter table public.graphic_settings
  add column if not exists bg_preset text;
