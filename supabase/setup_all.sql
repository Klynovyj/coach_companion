-- myCoach – Komplettes Cloud-Setup (Stufe 2–7) in einer Datei
-- Im Supabase SQL-Editor ausführen. VORAUSSETZUNG: schema.sql (Stufe 1) wurde
-- bereits eingespielt (Konten, Teams, Mitglieder, Spiele, Ereignisse, RLS).
-- Alle Schritte sind idempotent – mehrfaches Ausführen ist unschädlich.


-- ============================================================
-- >>> stage2_players.sql
-- ============================================================

-- myCoach – Stufe 2a: Kader in der Cloud
-- Im Supabase SQL-Editor ausführen (nach schema.sql).

create table if not exists public.players (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.teams(id) on delete cascade,
  first_name text,
  last_name text,
  number int,
  position text,
  created_at timestamptz not null default now()
);
create index if not exists idx_players_team on public.players(team_id);

alter table public.players enable row level security;

drop policy if exists "read players" on public.players;
create policy "read players" on public.players
  for select using (public.is_team_member(team_id));
drop policy if exists "trainer write players" on public.players;
create policy "trainer write players" on public.players
  for insert with check (public.is_team_trainer(team_id));
drop policy if exists "trainer update players" on public.players;
create policy "trainer update players" on public.players
  for update using (public.is_team_trainer(team_id));
drop policy if exists "trainer delete players" on public.players;
create policy "trainer delete players" on public.players
  for delete using (public.is_team_trainer(team_id));

-- Ereignis kann einen echten Spieler referenzieren (Name bleibt zusätzlich).
alter table public.match_events
  add column if not exists player_id uuid references public.players(id);


-- ============================================================
-- >>> stage3_tables.sql
-- ============================================================

-- myCoach – Stufe 3: geteilte Bereiche (eigene Tabelle pro Bereich)
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


-- ============================================================
-- >>> stage4_roles.sql
-- ============================================================

-- myCoach – Stufe 4: Rollen-UI (Co-Trainer hochstufen)
-- Nach schema.sql im Supabase SQL-Editor ausführen.
--
-- Zwei SECURITY-DEFINER-Funktionen:
--  * list_team_members: Mitglieder eines Teams MIT Namen – umgeht die
--    profiles-RLS (die sonst nur das eigene Profil sichtbar macht), prüft
--    aber, dass der Aufrufer selbst Mitglied ist.
--  * set_member_role: Rolle eines Mitglieds ändern – nur Trainer, und das
--    Team behält mindestens einen Trainer.

create or replace function public.list_team_members(t uuid)
returns table (user_id uuid, role text, display_name text, email text,
               is_me boolean)
language sql security definer stable as $$
  select m.user_id,
         m.role::text,
         coalesce(p.display_name, ''),
         u.email,
         m.user_id = auth.uid()
  from public.team_members m
  left join public.profiles p on p.id = m.user_id
  left join auth.users u on u.id = m.user_id
  where m.team_id = t and public.is_team_member(t)
  order by (m.role = 'trainer') desc, p.display_name nulls last;
$$;

create or replace function public.set_member_role(
  t uuid, target uuid, new_role text)
returns void language plpgsql security definer as $$
begin
  if not public.is_team_trainer(t) then
    raise exception 'Nur Trainer dürfen Rollen ändern';
  end if;
  if new_role not in ('trainer', 'spieler') then
    raise exception 'Ungültige Rolle';
  end if;
  -- Den letzten Trainer nicht entfernen (sonst sperrt sich das Team aus).
  if new_role = 'spieler' then
    if (select count(*) from public.team_members
        where team_id = t and role = 'trainer' and user_id <> target) = 0 then
      raise exception 'Das Team braucht mindestens einen Trainer';
    end if;
  end if;
  update public.team_members
     set role = new_role::public.team_role
   where team_id = t and user_id = target;
end; $$;


-- ============================================================
-- >>> stage5_fupa.sql
-- ============================================================

-- myCoach – Stufe 5: FuPa-Import direkt in die Cloud
-- Nach schema.sql im Supabase SQL-Editor ausführen.
--
-- Der FuPa-Teamlink wird am Cloud-Team gespeichert, damit JEDER Trainer des
-- Teams (nicht nur der ursprüngliche Importeur) Kader + Spielplan aus FuPa
-- auffrischen kann – die Aktualisierung landet dann direkt in der Cloud und
-- ist für alle sichtbar.

alter table public.teams add column if not exists fupa_url text;


-- ============================================================
-- >>> stage6_events.sql
-- ============================================================

-- myCoach – Stufe 6: Ereignis-IDs vereinheitlichen + Erwähnungen teilen
-- Nach schema.sql / stage2_players.sql im Supabase SQL-Editor ausführen.
--
-- Gespiegelte Ereignisse nutzen künftig die lokale ID als Cloud-ID (Upsert),
-- damit Erwähnungen (event_mentions) sie referenzieren können und Ereignisse
-- + Erwähnungen auf andere Geräte eingelesen werden. is_opponent erlaubt die
-- korrekte Eigen/Gegner-Zuordnung beim Einlesen.

alter table public.match_events
  add column if not exists assist_player_id uuid;
alter table public.match_events
  add column if not exists is_opponent boolean not null default false;

-- Geteilte Erwähnungen (Spieler in Kommentaren/Ereignissen). Kein FK auf
-- match_events, damit Reihenfolge/ID-Typ beim Spiegeln unkritisch sind.
create table if not exists public.event_mentions (
  event_id text not null,
  player_id text not null,
  team_id uuid not null references public.teams(id) on delete cascade,
  primary key (event_id, player_id)
);

alter table public.event_mentions enable row level security;

drop policy if exists "read event_mentions" on public.event_mentions;
create policy "read event_mentions" on public.event_mentions
  for select using (public.is_team_member(team_id));

drop policy if exists "trainer write event_mentions" on public.event_mentions;
create policy "trainer write event_mentions" on public.event_mentions
  for all using (public.is_team_trainer(team_id))
  with check (public.is_team_trainer(team_id));

do $$ begin
  alter publication supabase_realtime add table public.event_mentions;
exception when duplicate_object then null; end $$;


-- ============================================================
-- >>> stage7_media_stats.sql
-- ============================================================

-- myCoach – Stufe 7: Medien (Fotos/Logos) + Statistik in der Cloud
-- Nach schema.sql / stage2_players.sql im Supabase SQL-Editor ausführen.
--
-- Fotos & Logos werden (bewusst) als Data-URL direkt in Textspalten gespeichert
-- (kein Storage). So laufen sie über den normalen Sync mit.

alter table public.players add column if not exists photo text;         -- Spielerfoto (Data-URL)
alter table public.teams   add column if not exists logo text;          -- eigenes Vereinslogo
alter table public.matches add column if not exists opponent_logo text; -- Gegner-Logo

-- Spieler-Saison-Statistik (geteilt, aus FuPa)
create table if not exists public.player_stats (
  id text primary key,
  team_id uuid not null references public.teams(id) on delete cascade,
  external_id text,
  first_name text,
  last_name text,
  matches int not null default 0,
  goals int not null default 0,
  assists int not null default 0,
  yellow_cards int not null default 0,
  yellow_red_cards int not null default 0,
  red_cards int not null default 0,
  minutes int not null default 0,
  top_eleven int not null default 0
);

alter table public.player_stats enable row level security;

drop policy if exists "read player_stats" on public.player_stats;
create policy "read player_stats" on public.player_stats
  for select using (public.is_team_member(team_id));

drop policy if exists "trainer write player_stats" on public.player_stats;
create policy "trainer write player_stats" on public.player_stats
  for all using (public.is_team_trainer(team_id))
  with check (public.is_team_trainer(team_id));

do $$ begin
  alter publication supabase_realtime add table public.player_stats;
exception when duplicate_object then null; end $$;
