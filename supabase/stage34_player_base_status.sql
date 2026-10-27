-- myCoach – Stufe 34: Grundstatus getrennt vom effektiven Status.
-- `status` bleibt der effektive (abgeleitete) Wert; `base_status` ist der
-- manuell gesetzte Grundzustand (fit/inaktiv). Abwesenheiten (krank, verletzt,
-- gesperrt, urlaub, abwesend) ueberlagern den Status nur zeitweise.
-- Im Supabase SQL-Editor ausfuehren. Idempotent.

alter table public.players add column if not exists base_status text;

-- Backfill: inaktiv bleibt inaktiv, alles andere wird fit.
update public.players
  set base_status = case when status = 'inaktiv' then 'inaktiv' else 'fit' end
  where base_status is null;
