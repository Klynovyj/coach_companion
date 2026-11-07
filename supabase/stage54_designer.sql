-- stage54: Designer („Meine Designs"): Titel, Vorlage und kleines Vorschaubild
-- je Design, damit die Liste ohne das grosse Design-JSON geladen werden kann.
-- Voraussetzung: stage52_announcement_designs.sql. Im Supabase SQL-Editor
-- ausfuehren (idempotent).

alter table public.announcement_designs add column if not exists title text;
alter table public.announcement_designs add column if not exists kind text;
alter table public.announcement_designs add column if not exists thumb text;
