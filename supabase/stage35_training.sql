-- myCoach – Stufe 35: Trainings-Planer (Uebungs-Bibliothek + Einheiten).
-- Team-weit geteilt: Mitglieder lesen, Trainer schreiben (wie die uebrigen
-- Bereiche). Im Supabase SQL-Editor ausfuehren. Idempotent.

create table if not exists public.exercises (
  id text primary key,
  team_id uuid not null,
  title text,
  categories text,
  aufbau text,
  ablauf text,
  coaching_points text,
  varianten text,
  min_players integer,
  needs_goalkeeper integer,
  duration_min integer,
  material text,
  diagram text,
  video_links text,
  sketch_photo text,
  source text,
  created_by text,
  created_at text,
  updated_at text
);

create table if not exists public.training_sessions (
  id text primary key,
  team_id uuid not null,
  date text,
  field_players integer,
  goalkeepers integer,
  categories text,
  note text,
  created_at text
);

create table if not exists public.session_items (
  id text primary key,
  team_id uuid not null,
  session_id text,
  exercise_id text,
  order_index integer,
  duration_min integer,
  note text
);

create index if not exists idx_exercises_team on public.exercises(team_id);
create index if not exists idx_sessions_team on public.training_sessions(team_id);
create index if not exists idx_session_items_team
  on public.session_items(team_id, session_id);

-- RLS: Mitglieder lesen, Trainer schreiben + Realtime (wie stage3_tables).
do $$
declare
  t text;
  tables text[] := array['exercises','training_sessions','session_items'];
begin
  foreach t in array tables loop
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
