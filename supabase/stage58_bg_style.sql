-- stage58: Verlaufsform + Splitter-Muster fuer alle Grafiken (teamweit).
-- grad_shape: 'linear' | 'radial' | 'diagonal' (null = Standard der Grafik).
-- bg_pattern: Staerke des Polygon-Musters, 0 = aus.
-- Im Supabase SQL-Editor ausfuehren (idempotent).

alter table public.graphic_settings
  add column if not exists grad_shape text,
  add column if not exists bg_pattern double precision;
