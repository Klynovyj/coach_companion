-- Stufe 12: Live-Ticker-Rollen.
--
-- Trainer dürfen im Live-Spiel immer mitschreiben. Spieler (Mitglieder mit
-- Rolle „spieler") sind standardmäßig Zuschauer (nur Ticker lesen). Einzelnen
-- Spielern kann ein Trainer „Ticker-Rechte" geben (can_ticker), dann dürfen
-- sie live mitschreiben.
--
-- Im Supabase SQL-Editor ausführen. Idempotent.

-- 1) Ticker-Recht je Mitglied.
alter table public.team_members add column if not exists can_ticker boolean not null default false;

-- 2) Darf der Aufrufer live mitschreiben? Trainer ODER Ticker-berechtigt.
create or replace function public.is_team_ticker_editor(t uuid)
returns boolean language sql security definer stable as $$
  select public.is_team_trainer(t) or exists(
    select 1 from public.team_members m
    where m.team_id = t and m.user_id = auth.uid() and m.can_ticker = true
  );
$$;

-- 3) Live-Schreibrechte (matches-Status/Ergebnis, Ereignisse, Karten) auf
--    Ticker-Editoren ausweiten. Lesen bleibt für alle Mitglieder.
drop policy if exists "trainer update matches" on public.matches;
create policy "ticker update matches" on public.matches
  for update using (public.is_team_ticker_editor(team_id));

drop policy if exists "trainer write events" on public.match_events;
create policy "ticker write events" on public.match_events
  for insert with check (public.is_team_ticker_editor(team_id));
drop policy if exists "trainer update events" on public.match_events;
create policy "ticker update events" on public.match_events
  for update using (public.is_team_ticker_editor(team_id));
drop policy if exists "trainer delete events" on public.match_events;
create policy "ticker delete events" on public.match_events
  for delete using (public.is_team_ticker_editor(team_id));

-- card_entries liegt im Setup-Loop (Policy „trainer write card_entries", for all).
drop policy if exists "trainer write card_entries" on public.card_entries;
create policy "ticker write card_entries" on public.card_entries
  for all using (public.is_team_ticker_editor(team_id))
  with check (public.is_team_ticker_editor(team_id));

-- 4) Ticker-Recht setzen – nur Trainer.
create or replace function public.set_ticker(t uuid, target uuid, value boolean)
returns void language plpgsql security definer as $$
begin
  if not public.is_team_trainer(t) then
    raise exception 'Nur Trainer dürfen Ticker-Rechte vergeben';
  end if;
  update public.team_members set can_ticker = value
   where team_id = t and user_id = target;
end; $$;

-- 5) Mitgliederliste um can_ticker ergänzen (inkl. is_admin aus Stufe 10).
drop function if exists public.list_team_members(uuid);
create or replace function public.list_team_members(t uuid)
returns table (user_id uuid, role text, display_name text, email text,
               is_me boolean, is_admin boolean, can_ticker boolean)
language sql security definer stable as $$
  select m.user_id,
         m.role::text,
         coalesce(p.display_name, ''),
         u.email,
         m.user_id = auth.uid(),
         m.user_id = tm.created_by,
         m.can_ticker
  from public.team_members m
  left join public.profiles p on p.id = m.user_id
  left join auth.users u on u.id = m.user_id
  join public.teams tm on tm.id = m.team_id
  where m.team_id = t and public.is_team_member(t)
  order by (m.user_id = tm.created_by) desc,
           (m.role = 'trainer') desc,
           p.display_name nulls last;
$$;
