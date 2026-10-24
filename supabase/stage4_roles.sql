-- myCoach – Stufe 4: Rollen-UI (Co-Trainer hochstufen)
-- Nach schema.sql im Supabase SQL-Editor ausführen.
--
-- Zwei SECURITY-DEFINER-Funktionen:
--  * list_team_members: Mitglieder eines Teams MIT Namen – umgeht die
--    profiles-RLS (die sonst nur das eigene Profil sichtbar macht), prüft
--    aber, dass der Aufrufer selbst Mitglied ist.
--  * set_member_role: Rolle eines Mitglieds ändern – nur Trainer, und das
--    Team behält mindestens einen Trainer.

-- Alte Signatur entfernen (Rückgabetyp änderte sich um die E-Mail-Spalte).
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
