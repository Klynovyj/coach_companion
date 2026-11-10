-- myCoach – Stufe 57: Vorbereitungspläne (wie im Coach Studio)
-- Nach den vorherigen Stufen im Supabase SQL-Editor ausführen.
--
-- Spiegelt die lokale SQLite-Tabelle `prep_plans` (+ team_id für RLS).
-- data = ganzer Plan als JSON (Titel, Untertitel, Extra-Texte, Termine).
-- Lesen: alle Team-Mitglieder. Schreiben: Trainer/Admin.

create table if not exists public.prep_plans (
  id text primary key,
  team_id uuid not null references public.teams(id) on delete cascade,
  data text not null,
  updated_at text
);

alter table public.prep_plans enable row level security;

drop policy if exists "read prep_plans" on public.prep_plans;
create policy "read prep_plans" on public.prep_plans
  for select using (public.is_team_member(team_id));

drop policy if exists "trainer write prep_plans" on public.prep_plans;
create policy "trainer write prep_plans" on public.prep_plans
  for all
  using (public.is_team_trainer(team_id))
  with check (public.is_team_trainer(team_id));

do $$
begin
  alter publication supabase_realtime add table public.prep_plans;
exception when duplicate_object then null;
end $$;
