-- stage53: Sponsoren einzeln deaktivierbar. enabled (int 0/1, null/1 = aktiv).
-- Deaktivierte Sponsoren erscheinen auf keiner Grafik, bleiben aber erhalten.
-- Im Supabase SQL-Editor ausfuehren (idempotent).

alter table public.sponsors
  add column if not exists enabled int not null default 1;
