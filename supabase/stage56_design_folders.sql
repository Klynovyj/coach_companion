-- stage56: Designer („Meine Designs"): Designs in eigene Ordner einsortieren.
-- Voraussetzung: stage54_designer.sql. Im Supabase SQL-Editor ausfuehren
-- (idempotent). Ohne diese Spalte bleiben Ordner nur auf dem jeweiligen Geraet.

alter table public.announcement_designs add column if not exists folder text;
