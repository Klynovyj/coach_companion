-- myCoach – Stufe 31: Aktivitäten-Feed (teamweit protokollierte Aktionen)
-- Nach den vorherigen Stufen im Supabase SQL-Editor ausführen.

create table if not exists public.activities (
  id text primary key,
  team_id uuid not null references public.teams(id) on delete cascade,
  actor_id text,
  actor_name text,
  type text,
  title text,
  subtitle text,
  created_at text not null
);

create index if not exists idx_activities_team_created
  on public.activities (team_id, created_at desc);

alter table public.activities enable row level security;

drop policy if exists "read activities" on public.activities;
create policy "read activities" on public.activities
  for select using (public.is_team_member(team_id));

drop policy if exists "trainer write activities" on public.activities;
create policy "trainer write activities" on public.activities
  for all
  using (public.is_team_trainer(team_id))
  with check (public.is_team_trainer(team_id));

do $$
begin
  alter publication supabase_realtime add table public.activities;
exception when duplicate_object then null;
end $$;
