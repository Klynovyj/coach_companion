-- myCoach – Stufe 19: Spieler des Monats (Kürung je Monat, teamweit)
-- Nach den vorherigen Stufen im Supabase SQL-Editor ausführen.

create table if not exists public.player_of_month (
  id text primary key,
  team_id uuid not null references public.teams(id) on delete cascade,
  year_month text not null,
  player_id text not null,
  created_at text,
  unique (team_id, year_month)
);

alter table public.player_of_month enable row level security;

drop policy if exists "read player_of_month" on public.player_of_month;
create policy "read player_of_month" on public.player_of_month
  for select using (public.is_team_member(team_id));

drop policy if exists "trainer write player_of_month" on public.player_of_month;
create policy "trainer write player_of_month" on public.player_of_month
  for all
  using (public.is_team_trainer(team_id))
  with check (public.is_team_trainer(team_id));

do $$
begin
  alter publication supabase_realtime add table public.player_of_month;
exception when duplicate_object then null;
end $$;
