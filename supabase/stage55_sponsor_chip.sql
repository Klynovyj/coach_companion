-- stage55: Feld hinter dem Sponsor-Logo auf Grafiken je Sponsor waehlbar.
-- chip: 'auto' (hell/dunkel nach Kontrast), 'white', 'dark', 'none'.
-- Im Supabase SQL-Editor ausfuehren (idempotent).

alter table public.sponsors
  add column if not exists chip text not null default 'auto';
