-- myCouch – Stufe 1: Konten + gemeinsames Live-Tracking
-- Im Supabase SQL-Editor ausführen (neues Projekt für myCouch).
-- Enthält: Teams, Mitglieder (Rolle), Spiele, Ereignisse + Row-Level-Security
-- + Einladungscode-Beitritt + Realtime.

-- ---------------------------------------------------------------- Tabellen
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  created_at timestamptz not null default now()
);

create table if not exists public.teams (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  invite_code text unique not null default encode(gen_random_bytes(4), 'hex'),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);

do $$ begin
  create type public.team_role as enum ('trainer', 'spieler');
exception when duplicate_object then null; end $$;

create table if not exists public.team_members (
  team_id uuid not null references public.teams(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role public.team_role not null default 'spieler',
  created_at timestamptz not null default now(),
  primary key (team_id, user_id)
);

create table if not exists public.matches (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.teams(id) on delete cascade,
  opponent text not null,
  kickoff timestamptz,
  venue text,
  own_score int not null default 0,
  opponent_score int not null default 0,
  status text not null default 'scheduled',
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

create table if not exists public.match_events (
  id uuid primary key default gen_random_uuid(),
  match_id uuid not null references public.matches(id) on delete cascade,
  team_id uuid not null references public.teams(id) on delete cascade,
  minute int not null default 0,
  minute_extra int not null default 0,
  type text not null,
  player_name text,   -- Stufe 1: Name als Text (echter Kader-Sync folgt später)
  assist_name text,
  note text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

create index if not exists idx_events_match on public.match_events(match_id);
create index if not exists idx_members_user on public.team_members(user_id);

-- ------------------------------------------------------------- Helfer (RLS)
create or replace function public.is_team_member(t uuid)
returns boolean language sql security definer stable as $$
  select exists(
    select 1 from public.team_members m
    where m.team_id = t and m.user_id = auth.uid()
  );
$$;

create or replace function public.is_team_trainer(t uuid)
returns boolean language sql security definer stable as $$
  select exists(
    select 1 from public.team_members m
    where m.team_id = t and m.user_id = auth.uid() and m.role = 'trainer'
  );
$$;

-- Beitritt per Einladungscode (umgeht RLS kontrolliert).
create or replace function public.join_team(code text)
returns uuid language plpgsql security definer as $$
declare tid uuid;
begin
  select id into tid from public.teams where invite_code = code;
  if tid is null then
    raise exception 'Ungültiger Einladungscode';
  end if;
  insert into public.team_members(team_id, user_id, role)
  values (tid, auth.uid(), 'spieler')
  on conflict do nothing;
  return tid;
end; $$;

-- ---------------------------------------------------------------- RLS an
alter table public.profiles enable row level security;
alter table public.teams enable row level security;
alter table public.team_members enable row level security;
alter table public.matches enable row level security;
alter table public.match_events enable row level security;

-- profiles: jeder verwaltet sein eigenes
drop policy if exists "own profile" on public.profiles;
create policy "own profile" on public.profiles
  for all using (id = auth.uid()) with check (id = auth.uid());

-- teams
drop policy if exists "read teams" on public.teams;
create policy "read teams" on public.teams
  for select using (public.is_team_member(id));
drop policy if exists "create teams" on public.teams;
create policy "create teams" on public.teams
  for insert with check (created_by = auth.uid());
drop policy if exists "trainer update teams" on public.teams;
create policy "trainer update teams" on public.teams
  for update using (public.is_team_trainer(id));

-- team_members
drop policy if exists "read members" on public.team_members;
create policy "read members" on public.team_members
  for select using (public.is_team_member(team_id));
drop policy if exists "join self" on public.team_members;
create policy "join self" on public.team_members
  for insert with check (user_id = auth.uid());
drop policy if exists "trainer manage members" on public.team_members;
create policy "trainer manage members" on public.team_members
  for update using (public.is_team_trainer(team_id));
drop policy if exists "trainer delete members" on public.team_members;
create policy "trainer delete members" on public.team_members
  for delete using (public.is_team_trainer(team_id));

-- matches: Mitglieder lesen, Trainer schreiben
drop policy if exists "read matches" on public.matches;
create policy "read matches" on public.matches
  for select using (public.is_team_member(team_id));
drop policy if exists "trainer write matches" on public.matches;
create policy "trainer write matches" on public.matches
  for insert with check (public.is_team_trainer(team_id));
drop policy if exists "trainer update matches" on public.matches;
create policy "trainer update matches" on public.matches
  for update using (public.is_team_trainer(team_id));
drop policy if exists "trainer delete matches" on public.matches;
create policy "trainer delete matches" on public.matches
  for delete using (public.is_team_trainer(team_id));

-- match_events: Mitglieder lesen, Trainer schreiben (Spieler = nur Ansicht)
drop policy if exists "read events" on public.match_events;
create policy "read events" on public.match_events
  for select using (public.is_team_member(team_id));
drop policy if exists "trainer write events" on public.match_events;
create policy "trainer write events" on public.match_events
  for insert with check (public.is_team_trainer(team_id));
drop policy if exists "trainer update events" on public.match_events;
create policy "trainer update events" on public.match_events
  for update using (public.is_team_trainer(team_id));
drop policy if exists "trainer delete events" on public.match_events;
create policy "trainer delete events" on public.match_events
  for delete using (public.is_team_trainer(team_id));

-- ---------------------------------------------------------------- Realtime
alter publication supabase_realtime add table public.match_events;
alter publication supabase_realtime add table public.matches;

-- ----------------------------------------- Profil automatisch beim Registrieren
-- Legt bei jedem neuen Auth-Nutzer ein profiles-Zeile an (Name aus Metadaten).
-- SECURITY DEFINER umgeht die RLS kontrolliert.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer as $$
begin
  insert into public.profiles(id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data->>'display_name', ''))
  on conflict (id) do nothing;
  return new;
end; $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
