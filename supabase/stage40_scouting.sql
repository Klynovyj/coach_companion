-- stage40: Scouting (beobachtete/potenzielle Spieler) – team-weit geteilt.
-- Zwei Tabellen: scouting (Spieler) + scouting_entries (Status-Verlauf & Notizen).
-- Lesen: alle Team-Mitglieder; Schreiben: Trainer. Im Supabase SQL-Editor
-- ausfuehren (idempotent).

create table if not exists public.scouting (
  id text primary key,
  team_id uuid not null references public.teams(id) on delete cascade,
  name text not null,
  position text,
  number integer,
  fupa_url text,
  external_id text,
  photo_url text,
  status text,
  status_date text,
  stats_json text,
  stats_updated_at text,
  actor_id text,
  actor_name text,
  created_at text not null
);
create index if not exists idx_scouting_team_created
  on public.scouting (team_id, created_at desc);

create table if not exists public.scouting_entries (
  id text primary key,
  team_id uuid not null references public.teams(id) on delete cascade,
  scout_id text not null references public.scouting(id) on delete cascade,
  kind text not null,
  status text,
  text text,
  entry_date text,
  actor_id text,
  actor_name text,
  created_at text not null
);
create index if not exists idx_scouting_entries_team_scout
  on public.scouting_entries (team_id, scout_id);

do $$
declare t text;
begin
  foreach t in array array['scouting','scouting_entries'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists "read %1$s" on public.%1$I', t);
    execute format(
      'create policy "read %1$s" on public.%1$I for select using (public.is_team_member(team_id))',
      t);
    execute format('drop policy if exists "trainer write %1$s" on public.%1$I', t);
    execute format(
      'create policy "trainer write %1$s" on public.%1$I for all '
      'using (public.is_team_trainer(team_id)) '
      'with check (public.is_team_trainer(team_id))',
      t);
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null;
    end;
  end loop;
end $$;
