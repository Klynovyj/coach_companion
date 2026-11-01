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
