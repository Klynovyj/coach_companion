-- myCoach – Stufe 15: Sponsoren (teamweit, für die Startelf-Grafik)
-- Nach den vorherigen Stufen im Supabase SQL-Editor ausführen.
--
-- Spiegelt EXAKT die lokale SQLite-Tabelle `sponsors` (+ team_id für RLS).
-- logo = Base64-Data-URL (wie die Vereinslogos). is_main = Haupt-Sponsor
-- („Präsentiert von"); als int (0/1), passend zur lokalen Spalte.
-- Lesen: alle Team-Mitglieder. Schreiben: Trainer/Admin.

create table if not exists public.sponsors (
  id text primary key,
  team_id uuid not null references public.teams(id) on delete cascade,
  name text not null,
  logo text,
  is_main int not null default 0,
  sort_order int not null default 0
);

-- RLS + Policies + Realtime
alter table public.sponsors enable row level security;

drop policy if exists "read sponsors" on public.sponsors;
create policy "read sponsors" on public.sponsors
  for select using (public.is_team_member(team_id));

drop policy if exists "trainer write sponsors" on public.sponsors;
create policy "trainer write sponsors" on public.sponsors
  for all
  using (public.is_team_trainer(team_id))
  with check (public.is_team_trainer(team_id));

do $$
begin
  alter publication supabase_realtime add table public.sponsors;
exception when duplicate_object then null;
end $$;
