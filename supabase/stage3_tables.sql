-- myCouch – Stufe 3: geteilte Bereiche (eigene Tabelle pro Bereich)
-- Nach schema.sql und stage2_players.sql im Supabase SQL-Editor ausführen.
--
-- Jede Tabelle spiegelt EXAKT die lokalen SQLite-Spalten (+ team_id für RLS).
-- IDs bleiben Text (die App vergibt UUID-v4-Strings), team_id ist echte UUID.
-- Lesen: alle Team-Mitglieder. Schreiben: Trainer (Spieler = nur Ansicht).
-- Co-Trainer müssen dafür auf die Rolle „trainer" gesetzt werden.

-- --------------------------------------------------------------- Aufstellung
create table if not exists public.lineups (
  id text primary key,
  team_id uuid not null references public.teams(id) on delete cascade,
  match_id text not null,
  formation text not null,
  created_at text
);

create table if not exists public.lineup_entries (
  id text primary key,
  team_id uuid not null references public.teams(id) on delete cascade,
  lineup_id text not null,
  player_id text not null,
  role text not null,
  position_label text,
  order_index int not null default 0,
  pos_x double precision,
  pos_y double precision
);
create index if not exists idx_cl_lineup_entries on public.lineup_entries(lineup_id);

-- --------------------------------------------------------------- Nominierung
create table if not exists public.match_nominations (
  id text primary key,
  team_id uuid not null references public.teams(id) on delete cascade,
  match_id text not null,
  player_id text not null,
  status text not null,
  updated_at text,
  unique (match_id, player_id)
);

-- --------------------------------------------------------------------- Karten
create table if not exists public.card_entries (
  id text primary key,
  team_id uuid not null references public.teams(id) on delete cascade,
  player_id text not null,
  type text not null,
  date text not null,
  match_id text,
  match_event_id text,
  minute int,
  minute_extra int not null default 0,
  note text
);
create index if not exists idx_cl_cards_player on public.card_entries(player_id);

-- -------------------------------------------------------------------- Notizen
create table if not exists public.note_categories (
  id text primary key,
  team_id uuid not null references public.teams(id) on delete cascade,
  name text not null,
  sort_order int not null default 0
);

create table if not exists public.player_notes (
  id text primary key,
  team_id uuid not null references public.teams(id) on delete cascade,
  player_id text not null,
  "text" text not null,
  created_at text not null,
  category_id text,
  match_id text
);
create index if not exists idx_cl_notes_player on public.player_notes(player_id);

-- ---------------------------------------------------------------- Bewertungen
create table if not exists public.player_ratings (
  id text primary key,
  team_id uuid not null references public.teams(id) on delete cascade,
  match_id text not null,
  player_id text not null,
  rating double precision not null,
  note text,
  created_at text not null,
  unique (match_id, player_id)
);

-- ------------------------------------------------------------------- Aufgaben
create table if not exists public.todos (
  id text primary key,
  team_id uuid not null references public.teams(id) on delete cascade,
  "text" text not null,
  done int not null default 0,
  created_at text not null,
  due_date text,
  completed_at text,
  archived int not null default 0,
  topic_id text,
  responsible text
);

create table if not exists public.todo_topics (
  id text primary key,
  team_id uuid not null references public.teams(id) on delete cascade,
  title text not null,
  sort_order int not null default 0,
  created_at text not null
);

-- ---------------------------------------------------------- Spielergespräche
create table if not exists public.player_talks (
  id text primary key,
  team_id uuid not null references public.teams(id) on delete cascade,
  player_id text not null,
  title text not null,
  scheduled_at text not null,
  notes text,
  done int not null default 0,
  created_at text not null
);

-- --------------------------------------------------------------- Abwesenheiten
create table if not exists public.player_absences (
  id text primary key,
  team_id uuid not null references public.teams(id) on delete cascade,
  player_id text not null,
  status text not null,
  from_date text not null,
  until_date text not null,
  note text,
  created_at text not null
);

-- -------------------------------------- RLS + Policies + Realtime (pro Tabelle)
do $$
declare
  t text;
  tables text[] := array[
    'lineups','lineup_entries','match_nominations','card_entries',
    'note_categories','player_notes','player_ratings','todos',
    'todo_topics','player_talks','player_absences'
  ];
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

    -- Realtime aktivieren (doppeltes Hinzufügen ignorieren).
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null;
    end;
  end loop;
end $$;
