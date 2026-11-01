-- stage46: Design-Modus (eigenes Branding-Design) fuer die Grafiken.
-- Ergaenzt graphic_settings um logo_dark (Logo fuer dunkle Hintergruende),
-- design_mode (0/1), info_x/info_y (Position des Info-Blocks, 0..1).
-- Im Supabase SQL-Editor ausfuehren (idempotent).

alter table public.graphic_settings
  add column if not exists logo_dark text;
alter table public.graphic_settings
  add column if not exists design_mode integer not null default 0;
alter table public.graphic_settings
  add column if not exists info_x real;
alter table public.graphic_settings
  add column if not exists info_y real;
