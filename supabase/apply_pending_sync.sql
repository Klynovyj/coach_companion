-- ============================================================
-- coach_companion: Gesammelte offene Cloud-Migrationen
-- stage33 bis stage45, in Reihenfolge. Alle idempotent
-- (create ... if not exists / or replace / drop ... if exists),
-- daher ist mehrfaches Ausfuehren unschaedlich.
-- EINMAL komplett im Supabase SQL-Editor ausfuehren.
-- ============================================================

-- ============================================================
-- stage33_inbox.sql
-- ============================================================
-- myCoach – Stufe 33: Persönlicher Posteingang (Benachrichtigungen je Trainer).
-- Pro Empfaenger adressiert (nicht team-weit wie activities). Im Supabase
-- SQL-Editor ausfuehren.

create table if not exists public.inbox (
  id uuid primary key,
  team_id uuid not null references public.teams(id) on delete cascade,
  recipient_id uuid not null references auth.users(id) on delete cascade,
  actor_id uuid,
  actor_name text,
  type text,
  title text not null,
  subtitle text,
  link_type text,
  link_id text,
  created_at timestamptz not null default now(),
  read_at timestamptz
);

create index if not exists idx_inbox_recipient
  on public.inbox(recipient_id, created_at desc);

alter table public.inbox enable row level security;

-- Lesen: nur die eigenen Eintraege.
drop policy if exists "read own inbox" on public.inbox;
create policy "read own inbox" on public.inbox
  for select using (recipient_id = auth.uid());

-- Einfuegen: Ausloeser ist Mitglied des Teams. (Der Empfaenger ist in der Praxis
-- immer ein Teamkollege; Lesen bleibt ohnehin auf den Empfaenger beschraenkt.)
drop policy if exists "insert inbox for team member" on public.inbox;
create policy "insert inbox for team member" on public.inbox
  for insert with check (
    exists (
      select 1 from public.team_members m
      where m.team_id = inbox.team_id and m.user_id = auth.uid()
    )
  );

-- Aktualisieren: nur die eigene Zeile (read_at setzen).
drop policy if exists "update own inbox" on public.inbox;
create policy "update own inbox" on public.inbox
  for update using (recipient_id = auth.uid())
  with check (recipient_id = auth.uid());

-- Loeschen: nur die eigenen Eintraege (Aufraeumen).
drop policy if exists "delete own inbox" on public.inbox;
create policy "delete own inbox" on public.inbox
  for delete using (recipient_id = auth.uid());

-- Realtime aktivieren (idempotent).
do $$ begin
  alter publication supabase_realtime add table public.inbox;
exception when duplicate_object then null; end $$;

-- ============================================================
-- stage34_player_base_status.sql
-- ============================================================
-- myCoach – Stufe 34: Grundstatus getrennt vom effektiven Status.
-- `status` bleibt der effektive (abgeleitete) Wert; `base_status` ist der
-- manuell gesetzte Grundzustand (fit/inaktiv). Abwesenheiten (krank, verletzt,
-- gesperrt, urlaub, abwesend) ueberlagern den Status nur zeitweise.
-- Im Supabase SQL-Editor ausfuehren. Idempotent.

alter table public.players add column if not exists base_status text;

-- Backfill: inaktiv bleibt inaktiv, alles andere wird fit.
update public.players
  set base_status = case when status = 'inaktiv' then 'inaktiv' else 'fit' end
  where base_status is null;

-- ============================================================
-- stage35_training.sql
-- ============================================================
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

-- ============================================================
-- stage36_training_flags.sql
-- ============================================================
-- stage36: Favoriten/Archiv an Übungen und Archiv an Einheiten.
-- Ergänzt die in stage35 angelegten Cloud-Tabellen um die neuen Spalten.
-- Im Supabase SQL-Editor ausführen (idempotent).

alter table public.exercises
  add column if not exists favorite integer default 0,
  add column if not exists archived integer default 0,
  add column if not exists goalkeepers integer;

alter table public.training_sessions
  add column if not exists archived integer default 0;

-- ============================================================
-- stage37_lineups_named.sql
-- ============================================================
-- stage37: Mehrere benannte Aufstellungen je Spiel.
-- Ergänzt die Cloud-Tabelle lineups um Name + Reihenfolge (sort_index).
-- Die oberste Aufstellung (kleinstes sort_index) ist die gültige Start-11.
-- Im Supabase SQL-Editor ausführen (idempotent).

alter table public.lineups
  add column if not exists name text,
  add column if not exists sort_index integer not null default 0;

-- Mehrere Aufstellungen je Trainer erlauben: den alten Unique-Index
-- (match_id, team_id, created_by) entfernen. Sonst scheitert das Anlegen einer
-- zweiten Aufstellung desselben Trainers in der Cloud.
drop index if exists public.lineups_match_team_creator;

-- ============================================================
-- stage38_live_control_per_team.sql
-- ============================================================
-- stage38: Live-Erfassung pro Seite (eigene Mannschaft / Gegner) uebernehmbar.
-- Ergaenzt die Cloud-Tabelle matches um einen zweiten Controller fuer die
-- Gegner-Erfassung. live_controller steuert weiterhin die eigene Mannschaft +
-- Uhr/Phasen. Im Supabase SQL-Editor ausfuehren (idempotent).

alter table public.matches
  add column if not exists live_controller_opp text,
  add column if not exists live_controller_opp_name text;

-- ============================================================
-- stage39_live_control_request.sql
-- ============================================================
-- stage39: Live-Steuerung per Anfrage & Genehmigung.
-- Ergaenzt die Cloud-Tabelle matches um eine offene Uebernahme-Anfrage:
-- live_request_by (User-ID), live_request_by_name, live_request_scope
-- ('own' = eigene + Uhr, 'opp' = Gegner, 'both' = beide). Der Haupt-Ticker
-- genehmigt/lehnt ab. Im Supabase SQL-Editor ausfuehren (idempotent).

alter table public.matches
  add column if not exists live_request_by text,
  add column if not exists live_request_by_name text,
  add column if not exists live_request_scope text;

-- ============================================================
-- stage40_scouting.sql
-- ============================================================
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

-- ============================================================
-- stage41_live_main_ticker.sql
-- ============================================================
-- stage41: Haupt-Ticker behält immer die volle Kontrolle; Delegierte sind
-- ZUSAETZLICH (nehmen ihm nichts weg). live_controller = Haupt-Ticker (Starter,
-- beide Seiten + Uhr), live_controller_opp = Gegner-Delegierter,
-- live_delegate_own = Eigen-Delegierter. Im Supabase SQL-Editor ausfuehren.

alter table public.matches
  add column if not exists live_delegate_own text,
  add column if not exists live_delegate_own_name text;

-- ============================================================
-- stage42_player_strong_foot.sql
-- ============================================================
-- stage42: Starker Fuss am Spieler (links/rechts/beide). Mannschaftsweit geteilt.
-- Im Supabase SQL-Editor ausfuehren (idempotent).

alter table public.players
  add column if not exists strong_foot text;

-- ============================================================
-- stage43_graphic_photos.sql
-- ============================================================
-- stage43: Spielerfotos-Schalter in der Grafik (Ergebnis-Grafik: Torschuetzen/
-- Karten mit/ohne Foto). Ergaenzt graphic_settings um show_photos (int 0/1).
-- Im Supabase SQL-Editor ausfuehren (idempotent).

alter table public.graphic_settings
  add column if not exists show_photos int default 0;

-- ============================================================
-- stage44_graphic_bg_preset.sql
-- ============================================================
-- stage44: Eingebautes Hintergrund-Design (Vorlage) fuer die Grafiken.
-- Ergaenzt graphic_settings um bg_preset (z.B. 'stripes'). Im Supabase
-- SQL-Editor ausfuehren (idempotent).

alter table public.graphic_settings
  add column if not exists bg_preset text;

-- ============================================================
-- stage45_ai_permissions.sql
-- ============================================================
-- Stufe 45: KI-Berechtigungen pro Benutzer (Admin-Steuerung).
--
-- Zwei KI-Funktionen kosten Geld:
--   * Gemini  (Edge-Function ai-image)  -> Flag ai_image_enabled
--   * Claude  (Edge-Function ai-coach)  -> Flag ai_coach_enabled
-- Standardmaessig darf jeder beide nutzen (Default true). Nur der Team-Ersteller
-- (Admin) kann pro Mitglied einzeln an-/abschalten. Die Edge-Functions pruefen
-- die Freigabe serverseitig (has_ai_access), damit ein gesperrter Nutzer keine
-- Kosten ausloesen kann.
--
-- Im Supabase SQL-Editor ausfuehren. Idempotent (mehrfach ausfuehrbar).

-- 1) Flags je Mitglied, Default true (= alle an).
alter table public.team_members add column if not exists ai_image_enabled boolean not null default true;
alter table public.team_members add column if not exists ai_coach_enabled boolean not null default true;

-- 2) Admin = Team-Ersteller.
create or replace function public.is_team_admin(t uuid)
returns boolean language sql security definer stable as $$
  select exists(
    select 1 from public.teams tm
    where tm.id = t and tm.created_by = auth.uid()
  );
$$;

-- 3) KI-Recht setzen -- nur der Admin (Ersteller).
create or replace function public.set_ai_permission(
  t uuid, target uuid, kind text, value boolean)
returns void language plpgsql security definer as $$
begin
  if not public.is_team_admin(t) then
    raise exception 'Nur der Team-Ersteller darf KI-Rechte vergeben';
  end if;
  if kind = 'image' then
    update public.team_members set ai_image_enabled = value
     where team_id = t and user_id = target;
  elsif kind = 'coach' then
    update public.team_members set ai_coach_enabled = value
     where team_id = t and user_id = target;
  else
    raise exception 'Unbekannte KI-Art';
  end if;
end; $$;

-- 4) Serverpruefung fuer die Edge-Functions: Ist der Aufrufer fuer die KI-Art
--    in MINDESTENS einem Team freigeschaltet? (SECURITY DEFINER umgeht RLS.)
create or replace function public.has_ai_access(kind text)
returns boolean language sql security definer stable as $$
  select exists(
    select 1 from public.team_members m
    where m.user_id = auth.uid()
      and (case kind
             when 'image' then m.ai_image_enabled
             when 'coach' then m.ai_coach_enabled
             else false
           end) = true
  );
$$;

-- 5) Mitgliederliste um die zwei Flags ergaenzen (Rueckgabetyp aendert sich ->
--    alte Signatur zuerst entfernen; baut auf stage12 auf).
drop function if exists public.list_team_members(uuid);
create or replace function public.list_team_members(t uuid)
returns table (user_id uuid, role text, display_name text, email text,
               is_me boolean, is_admin boolean, can_ticker boolean,
               ai_image_enabled boolean, ai_coach_enabled boolean)
language sql security definer stable as $$
  select m.user_id,
         m.role::text,
         coalesce(p.display_name, ''),
         u.email,
         m.user_id = auth.uid(),
         m.user_id = tm.created_by,
         m.can_ticker,
         m.ai_image_enabled,
         m.ai_coach_enabled
  from public.team_members m
  left join public.profiles p on p.id = m.user_id
  left join auth.users u on u.id = m.user_id
  join public.teams tm on tm.id = m.team_id
  where m.team_id = t and public.is_team_member(t)
  order by (m.user_id = tm.created_by) desc,
           (m.role = 'trainer') desc,
           p.display_name nulls last;
$$;
