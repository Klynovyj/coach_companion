-- stage48: Deckkraft + Mischmodus des Hintergrundbilds der Grafik.
-- bg_opacity (0-100, null=100), bg_blend ('normal'|'overlay'|'multiply'|
-- 'screen'|'softlight', null=normal). Im Supabase SQL-Editor ausfuehren.

alter table public.graphic_settings
  add column if not exists bg_opacity integer;
alter table public.graphic_settings
  add column if not exists bg_blend text;
