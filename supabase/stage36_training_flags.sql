-- stage36: Favoriten/Archiv an Übungen und Archiv an Einheiten.
-- Ergänzt die in stage35 angelegten Cloud-Tabellen um die neuen Spalten.
-- Im Supabase SQL-Editor ausführen (idempotent).

alter table public.exercises
  add column if not exists favorite integer default 0,
  add column if not exists archived integer default 0,
  add column if not exists goalkeepers integer;

alter table public.training_sessions
  add column if not exists archived integer default 0;
