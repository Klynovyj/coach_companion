-- stage37: Mehrere benannte Aufstellungen je Spiel.
-- Ergänzt die Cloud-Tabelle lineups um Name + Reihenfolge (sort_index).
-- Die oberste Aufstellung (kleinstes sort_index) ist die gültige Start-11.
-- Im Supabase SQL-Editor ausführen (idempotent).

alter table public.lineups
  add column if not exists name text,
  add column if not exists sort_index integer not null default 0;
