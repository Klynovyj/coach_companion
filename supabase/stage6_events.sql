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
