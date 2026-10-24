-- myCouch – Stufe 5: FuPa-Import direkt in die Cloud
-- Nach schema.sql im Supabase SQL-Editor ausführen.
--
-- Der FuPa-Teamlink wird am Cloud-Team gespeichert, damit JEDER Trainer des
-- Teams (nicht nur der ursprüngliche Importeur) Kader + Spielplan aus FuPa
-- auffrischen kann – die Aktualisierung landet dann direkt in der Cloud und
-- ist für alle sichtbar.

alter table public.teams add column if not exists fupa_url text;
