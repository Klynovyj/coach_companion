-- Stufe 13: Live-Steuerung – wer steuert gerade das Live-Spiel.
--
-- Nur der Controller (der das Spiel gestartet bzw. die Steuerung übernommen
-- hat) bedient das Live-Spiel; andere Trainer sehen es schreibgeschützt und wer
-- steuert. Rein über die Spiel-Zeile geteilt (Realtime + Poll).
--
-- Im Supabase SQL-Editor ausführen. Idempotent.

alter table public.matches add column if not exists live_controller text;      -- User-ID des steuernden Trainers
alter table public.matches add column if not exists live_controller_name text; -- Anzeigename
