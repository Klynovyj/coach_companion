-- stage52: Spielankuendigungs-Design je Spiel (Positionen/Bilder/Finish als JSON).
-- Team-weit geteilt: Lesen alle Mitglieder, Schreiben nur Trainer.
-- Im Supabase SQL-Editor ausfuehren (idempotent).

create table if not exists public.announcement_designs (
  id text primary key,
  team_id uuid not null references public.teams(id) on delete cascade,
  match_id text,
  data text,
  updated_at text
);
create index if not exists idx_announcement_designs_team
  on public.announcement_designs (team_id);

do $$
declare t text;
begin
  foreach t in array array['announcement_designs'] loop
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
