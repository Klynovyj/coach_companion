-- stage50: Form des Logo-Hintergrunds der Grafik (eckig/rund).
-- logo_shape ('rounded'|'circle', null=rounded). Im Supabase SQL-Editor
-- ausfuehren (idempotent).

alter table public.graphic_settings
  add column if not exists logo_shape text;
