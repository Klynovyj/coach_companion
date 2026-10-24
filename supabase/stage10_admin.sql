-- Stufe 10: Team-Ersteller ist immer Admin.
--
-- Der Ersteller (teams.created_by) hat IMMER volle Trainerrechte (auch wenn
-- seine Mitglieds-Rolle versehentlich „spieler" wäre), darf Rollen vergeben
-- und kann nicht herabgestuft werden.
--
-- Im Supabase SQL-Editor ausführen. Idempotent (mehrfach ausführbar).

-- 1) Ersteller zählt immer als Mitglied (Lesezugriff garantiert).
create or replace function public.is_team_member(t uuid)
returns boolean language sql security definer stable as $$
  select exists(
    select 1 from public.team_members m
    where m.team_id = t and m.user_id = auth.uid()
  ) or exists(
    select 1 from public.teams tm
    where tm.id = t and tm.created_by = auth.uid()
  );
$$;

-- 2) Der Ersteller zählt immer als Trainer/Admin (volle Schreibrechte).
create or replace function public.is_team_trainer(t uuid)
returns boolean language sql security definer stable as $$
  select exists(
    select 1 from public.team_members m
    where m.team_id = t and m.user_id = auth.uid() and m.role = 'trainer'
  ) or exists(
    select 1 from public.teams tm
    where tm.id = t and tm.created_by = auth.uid()
  );
$$;

-- 3) Mitgliederliste mit Admin-Kennzeichnung (is_admin = Ersteller).
--    Rückgabetyp ändert sich → alte Signatur zuerst entfernen.
drop function if exists public.list_team_members(uuid);
create or replace function public.list_team_members(t uuid)
returns table (user_id uuid, role text, display_name text, email text,
               is_me boolean, is_admin boolean)
language sql security definer stable as $$
  select m.user_id,
         m.role::text,
         coalesce(p.display_name, ''),
         u.email,
         m.user_id = auth.uid(),
         m.user_id = tm.created_by
  from public.team_members m
  left join public.profiles p on p.id = m.user_id
  left join auth.users u on u.id = m.user_id
  join public.teams tm on tm.id = m.team_id
  where m.team_id = t and public.is_team_member(t)
  order by (m.user_id = tm.created_by) desc,
           (m.role = 'trainer') desc,
           p.display_name nulls last;
$$;

-- 4) Rollen ändern: Ersteller (Admin) kann nicht herabgestuft werden.
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
  -- Den Admin (Team-Ersteller) nicht herabstufen.
  if new_role = 'spieler'
     and target = (select created_by from public.teams where id = t) then
    raise exception 'Der Team-Ersteller (Admin) kann nicht herabgestuft werden';
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
