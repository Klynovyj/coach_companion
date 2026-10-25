-- myCoach – Stufe 21: FuPa-Match-Slug an den Spielen (Link auf die FuPa-Spielseite,
-- u.a. fuer die Bester-Spieler-Abstimmung). Im Supabase SQL-Editor ausfuehren.

alter table public.matches
  add column if not exists fupa_match_slug text;
