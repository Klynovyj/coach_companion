-- stage49: Hintergrund-Vorlagen (kompletter Look) fuer die Grafiken.
-- Team-weit geteilt: Lesen alle Mitglieder, Schreiben nur Trainer.
-- Im Supabase SQL-Editor ausfuehren (idempotent).

create table if not exists public.graphic_presets (
  id text primary key,
  team_id uuid not null references public.teams(id) on delete cascade,
  name text not null,
  bg_image text,
  grad_top text,
  grad_bottom text,
  overlay_opacity integer,
  bg_opacity integer,
  bg_blend text,
  accent text,
  created_at text not null
);
create index if not exists idx_graphic_presets_team_created
  on public.graphic_presets (team_id, created_at desc);

do $$
declare t text;
begin
  foreach t in array array['graphic_presets'] loop
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
