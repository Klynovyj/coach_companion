-- myCoach – Stufe 72: Statistik-Baukasten (eigene Gruppen + Vorlagen)
-- Nach den vorherigen Stufen im Supabase SQL-Editor ausführen.
--
-- Spiegelt die lokalen SQLite-Tabellen `stat_groups` und `stat_templates`
-- (+ team_id für RLS). player_ids bzw. config = JSON-Text.
-- Lesen: alle Team-Mitglieder. Schreiben: Trainer/Admin.

create table if not exists public.stat_groups (
  id text primary key,
  team_id uuid not null references public.teams(id) on delete cascade,
  name text not null,
  player_ids text not null default '[]',
  created_by text,
  updated_at text
);

create table if not exists public.stat_templates (
  id text primary key,
  team_id uuid not null references public.teams(id) on delete cascade,
  name text not null,
  config text not null default '{}',
  created_by text,
  updated_at text
);

alter table public.stat_groups enable row level security;
alter table public.stat_templates enable row level security;

drop policy if exists "read stat_groups" on public.stat_groups;
create policy "read stat_groups" on public.stat_groups
  for select using (public.is_team_member(team_id));

drop policy if exists "trainer write stat_groups" on public.stat_groups;
create policy "trainer write stat_groups" on public.stat_groups
  for all
  using (public.is_team_trainer(team_id))
  with check (public.is_team_trainer(team_id));

drop policy if exists "read stat_templates" on public.stat_templates;
create policy "read stat_templates" on public.stat_templates
  for select using (public.is_team_member(team_id));

drop policy if exists "trainer write stat_templates" on public.stat_templates;
create policy "trainer write stat_templates" on public.stat_templates
  for all
  using (public.is_team_trainer(team_id))
  with check (public.is_team_trainer(team_id));

do $$
begin
  alter publication supabase_realtime add table public.stat_groups;
exception when duplicate_object then null;
end $$;

do $$
begin
  alter publication supabase_realtime add table public.stat_templates;
exception when duplicate_object then null;
end $$;
