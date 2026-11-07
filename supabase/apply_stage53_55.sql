-- Sammeldatei: stage53 + stage54 + stage55 in einem Rutsch (idempotent).
-- Im Supabase SQL-Editor komplett einfuegen und ausfuehren.

-- stage53: Sponsoren einzeln deaktivierbar. enabled (int 0/1, null/1 = aktiv).
-- Deaktivierte Sponsoren erscheinen auf keiner Grafik, bleiben aber erhalten.
-- Im Supabase SQL-Editor ausfuehren (idempotent).

alter table public.sponsors
  add column if not exists enabled int not null default 1;

-- stage54: Designer („Meine Designs"): Titel, Vorlage und kleines Vorschaubild
-- je Design, damit die Liste ohne das grosse Design-JSON geladen werden kann.
-- Voraussetzung: stage52_announcement_designs.sql. Im Supabase SQL-Editor
-- ausfuehren (idempotent).

alter table public.announcement_designs add column if not exists title text;
alter table public.announcement_designs add column if not exists kind text;
alter table public.announcement_designs add column if not exists thumb text;

-- stage55: Feld hinter dem Sponsor-Logo auf Grafiken je Sponsor waehlbar.
-- chip: 'auto' (hell/dunkel nach Kontrast), 'white', 'dark', 'none'.
-- Im Supabase SQL-Editor ausfuehren (idempotent).

alter table public.sponsors
  add column if not exists chip text not null default 'auto';
