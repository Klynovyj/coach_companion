-- Stufe 68: Spieler des Monats nur einstimmig (alle Trainer: Link + App) und
-- voraussichtliche Abzeichen. Kuerung/Stimmen werden nie geloescht, sondern
-- geleert (player_id '' bzw. null) – so erreichen Aenderungen die App per
-- Realtime-UPDATE.

create table if not exists public.month_crown_votes (
  team_id uuid not null references public.teams(id) on delete cascade,
  year_month text not null,
  rater_id text not null,
  player_id text,
  updated_at timestamptz not null default now(),
  primary key (team_id, year_month, rater_id)
);
alter table public.month_crown_votes enable row level security;
drop policy if exists "read month_crown_votes" on public.month_crown_votes;
create policy "read month_crown_votes" on public.month_crown_votes
  for select using (public.is_team_member(team_id));
do $$ begin
  alter publication supabase_realtime add table public.month_crown_votes;
exception when duplicate_object then null; end $$;

-- Pflicht-Trainer: alle Trainer-Links + App-Trainer/Admin ohne eigenen Link.
create or replace function public.crown_required(t uuid)
returns jsonb language sql security definer stable
set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('rater_id', rid, 'name', nm) order by nm), '[]'::jsonb)
    from (
      select l.rater_id rid, coalesce(nullif(l.name, ''), 'Trainer') nm
        from public.coach_rating_links l where l.team_id = t
      union
      select m.user_id::text, coalesce(nullif(p.display_name, ''), 'Trainer')
        from public.team_members m left join public.profiles p on p.id = m.user_id
       where m.team_id = t and m.role = 'trainer'
         and not exists (select 1 from public.coach_rating_links l where l.rater_id = m.user_id::text)
      union
      select tm.created_by::text, coalesce(nullif(p.display_name, ''), 'Trainer')
        from public.teams tm left join public.profiles p on p.id = tm.created_by
       where tm.id = t
         and not exists (select 1 from public.coach_rating_links l where l.rater_id = tm.created_by::text)
    ) x;
$$;

-- Platz 1 der Monats-Rangliste (Trainer-Schnitt; Gleichstand = mehrere).
create or replace function public.month_leaders(t uuid, ym text)
returns jsonb language sql security definer stable
set search_path = public as $$
  with a as (
    select pr.player_id pid, avg(pr.rating) av
      from public.player_ratings pr
      join public.matches mt on mt.id::text = pr.match_id
     where mt.team_id = t
       and to_char(mt.kickoff at time zone 'Europe/Berlin', 'YYYY-MM') = ym
     group by pr.player_id
  )
  select coalesce(jsonb_agg(pid order by pid), '[]'::jsonb) from a
   where round(av::numeric, 4) = (select round(max(av)::numeric, 4) from a);
$$;

-- Gekuerter Spieler (leer = nicht gekuert).
create or replace function public.crowned_of(t uuid, ym text)
returns text language sql security definer stable
set search_path = public as $$
  select nullif(player_id, '') from public.player_of_month
   where team_id = t and year_month = ym;
$$;

-- Stand der Kuerung eines Monats.
create or replace function public.crown_state_core(t uuid, ym text)
returns jsonb language sql security definer stable
set search_path = public as $$
  with req as (select r->>'rater_id' rid, r->>'name' nm
                 from jsonb_array_elements(public.crown_required(t)) r),
       v as (select rater_id, player_id from public.month_crown_votes
              where team_id = t and year_month = ym and player_id is not null)
  select jsonb_build_object(
    'year_month', ym,
    'required', coalesce((select jsonb_agg(jsonb_build_object('rater_id', req.rid, 'name', req.nm,
        'player_id', v.player_id) order by req.nm) from req left join v on v.rater_id = req.rid), '[]'::jsonb),
    'counts', coalesce((select jsonb_object_agg(player_id, n) from (
        select v.player_id, count(*) n from v join req on req.rid = v.rater_id group by v.player_id) c), '{}'::jsonb),
    'crowned', public.crowned_of(t, ym),
    'leaders', public.month_leaders(t, ym));
$$;

-- Nach jeder Stimme: einstimmig -> kueren, sonst Kuerung leeren.
create or replace function public.crown_apply(t uuid, ym text)
returns void language plpgsql security definer volatile
set search_path = public as $$
declare
  req int;
  pid text;
  n int;
begin
  select jsonb_array_length(public.crown_required(t)) into req;
  select v.player_id, count(*) into pid, n
    from public.month_crown_votes v
   where v.team_id = t and v.year_month = ym and v.player_id is not null
     and v.rater_id in (select r->>'rater_id' from jsonb_array_elements(public.crown_required(t)) r)
   group by v.player_id order by count(*) desc limit 1;
  if req > 0 and n = req then
    insert into public.player_of_month (id, team_id, year_month, player_id, created_at)
    values (gen_random_uuid()::text, t, ym, pid,
            to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'))
    on conflict (team_id, year_month) do update set player_id = excluded.player_id;
  else
    update public.player_of_month set player_id = ''
     where team_id = t and year_month = ym and player_id <> '';
  end if;
end; $$;

create or replace function public.crown_vote_core(t uuid, rid text, ym text, pid text)
returns jsonb language plpgsql security definer volatile
set search_path = public as $$
begin
  if ym !~ '^[0-9]{4}-[0-9]{2}$' then
    return jsonb_build_object('ok', false, 'error', 'month');
  end if;
  if pid is not null and not exists (select 1 from public.players
       where id::text = pid and team_id = t) then
    return jsonb_build_object('ok', false, 'error', 'player');
  end if;
  insert into public.month_crown_votes (team_id, year_month, rater_id, player_id, updated_at)
  values (t, ym, rid, pid, now())
  on conflict (team_id, year_month, rater_id) do update set
    player_id = excluded.player_id, updated_at = now();
  perform public.crown_apply(t, ym);
  return jsonb_build_object('ok', true, 'state', public.crown_state_core(t, ym));
end; $$;

-- Trainer-Link.
create or replace function public.coach_crown_vote(p_token text, p_year_month text, p_player_id text)
returns jsonb language plpgsql security definer volatile
set search_path = public as $$
declare
  l public.coach_rating_links;
begin
  select * into l from public.coach_rating_links where token = p_token;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'invalid');
  end if;
  return public.crown_vote_core(l.team_id, l.rater_id, p_year_month, p_player_id);
end; $$;

create or replace function public.coach_crown_state(p_token text, p_year_month text)
returns jsonb language plpgsql security definer stable
set search_path = public as $$
declare
  l public.coach_rating_links;
begin
  select * into l from public.coach_rating_links where token = p_token;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'invalid');
  end if;
  return jsonb_build_object('ok', true, 'me', l.rater_id,
    'state', public.crown_state_core(l.team_id, p_year_month));
end; $$;

-- Alte Kuer-RPC: nur noch eine Stimme (kein Alleingang).
create or replace function public.coach_crown_month(p_token text, p_year_month text, p_player_id text)
returns jsonb language sql security definer volatile
set search_path = public as $$
  select public.coach_crown_vote(p_token, p_year_month, p_player_id);
$$;

-- App (Trainer, Bewerter = eigenes Konto).
create or replace function public.app_crown_vote(p_team uuid, p_year_month text, p_player_id text)
returns jsonb language plpgsql security definer volatile
set search_path = public as $$
begin
  if not public.is_team_trainer(p_team) then
    raise exception 'Nur fuer Trainer';
  end if;
  return public.crown_vote_core(p_team, auth.uid()::text, p_year_month, p_player_id);
end; $$;

create or replace function public.app_crown_state(p_team uuid, p_year_month text)
returns jsonb language plpgsql security definer stable
set search_path = public as $$
begin
  if not public.is_team_trainer(p_team) then
    raise exception 'Nur fuer Trainer';
  end if;
  return jsonb_build_object('ok', true, 'me', auth.uid()::text,
    'state', public.crown_state_core(p_team, p_year_month));
end; $$;


create or replace function public.coach_month(p_token text, p_year_month text)
returns jsonb language plpgsql security definer stable
set search_path = public as $$
declare
  l public.coach_rating_links;
  ym text;
begin
  select * into l from public.coach_rating_links where token = p_token;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'invalid');
  end if;
  ym := coalesce(nullif(p_year_month, ''),
                 to_char(now() at time zone 'Europe/Berlin', 'YYYY-MM'));
  return jsonb_build_object(
    'ok', true,
    'year_month', ym,
    'months', coalesce((select jsonb_agg(m order by m desc) from (
        select distinct to_char(kickoff at time zone 'Europe/Berlin', 'YYYY-MM') m
          from public.matches where team_id = l.team_id and kickoff is not null
           and kickoff <= now() + interval '1 day'
        union select ym) x), '[]'::jsonb),
    'ranking', coalesce((select jsonb_agg(jsonb_build_object(
        'id', p.id::text,
        'name', trim(coalesce(p.first_name, '') || ' ' || coalesce(p.last_name, '')),
        'number', p.number,
        'photo', p.photo_fupa,
        't', jsonb_build_object('avg', t.a, 'n', t.c),
        'm', case when pm.c is null then null else jsonb_build_object('avg', pm.a, 'n', pm.c) end)
        order by t.a desc, t.c desc)
      from (select pr.player_id pid, avg(pr.rating) a, count(*) c
              from public.player_ratings pr
              join public.matches mt on mt.id::text = pr.match_id
             where mt.team_id = l.team_id
               and to_char(mt.kickoff at time zone 'Europe/Berlin', 'YYYY-MM') = ym
             group by pr.player_id) t
      join public.players p on p.id::text = t.pid and p.team_id = l.team_id
      left join (select e.key pid, avg((e.value #>> '{}')::numeric) a, count(*) c
                   from public.peer_ratings x
                   join public.peer_rating_rounds rr on rr.match_id = x.match_id
                   , jsonb_each(x.stars) e
                  where rr.team_id = l.team_id
                    and to_char(rr.match_date at time zone 'Europe/Berlin', 'YYYY-MM') = ym
                  group by e.key) pm on pm.pid = t.pid), '[]'::jsonb),
    'honored', (select jsonb_build_object('year_month', h.year_month, 'id', h.player_id,
        'name', trim(coalesce(p.first_name, '') || ' ' || coalesce(p.last_name, '')),
        'number', p.number, 'photo', p.photo_fupa)
      from public.player_of_month h
      left join public.players p on p.id::text = h.player_id
     where h.team_id = l.team_id and h.year_month = ym and h.player_id <> ''),
    'crown', public.crown_state_core(l.team_id, ym),
    'me', l.rater_id,
    'history', coalesce((select jsonb_agg(jsonb_build_object('year_month', h.year_month,
        'id', h.player_id,
        'name', trim(coalesce(p.first_name, '') || ' ' || coalesce(p.last_name, '')),
        'number', p.number, 'photo', p.photo_fupa) order by h.year_month desc)
      from (select * from public.player_of_month where team_id = l.team_id
               and player_id <> ''
             order by year_month desc limit 6) h
      left join public.players p on p.id::text = h.player_id), '[]'::jsonb));
end; $$;

create or replace function public.peer_month(p_token text)
returns jsonb language plpgsql security definer stable
set search_path = public as $$
declare
  l public.peer_rating_links;
begin
  select * into l from public.peer_rating_links where token = p_token;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'invalid');
  end if;
  return jsonb_build_object('ok', true, 'honored',
    (select jsonb_build_object('year_month', h.year_month, 'id', h.player_id,
        'name', trim(coalesce(p.first_name, '') || ' ' || coalesce(p.last_name, '')),
        'number', p.number, 'photo', p.photo_fupa)
       from public.player_of_month h
       left join public.players p on p.id::text = h.player_id
      where h.team_id = l.team_id and h.player_id <> ''
      order by h.year_month desc limit 1));
end; $$;

create or replace function public.peer_badges(p_token text)
returns jsonb language plpgsql security definer stable
set search_path = public as $$
declare
  l public.peer_rating_links;
  r public.peer_rating_rounds;
  motm jsonb := '[]'::jsonb;
  ym text := to_char(now() at time zone 'Europe/Berlin', 'YYYY-MM');
  crowned text;
begin
  select * into l from public.peer_rating_links where token = p_token;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'invalid');
  end if;
  select * into r from public.peer_rating_rounds
   where team_id = l.team_id
     and players @> jsonb_build_array(jsonb_build_object('id', l.player_id))
   order by closes_at desc limit 1;
  if found then
    select coalesce(jsonb_agg(jsonb_build_object('id', v->>'id', 'votes', (v->>'votes')::int)), '[]'::jsonb)
      into motm
      from jsonb_array_elements(public.motm_votes(r.match_id)) v
     where (v->>'votes')::int = (select max((x->>'votes')::int)
                                   from jsonb_array_elements(public.motm_votes(r.match_id)) x);
  end if;
  crowned := public.crowned_of(l.team_id, ym);
  return jsonb_build_object(
    'ok', true,
    'match_id', r.match_id,
    'motm', motm,
    'motm_final', r.match_id is not null and now() > r.closes_at,
    'pom', case when crowned is not null
                then jsonb_build_object('ids', jsonb_build_array(crowned), 'final', true, 'year_month', ym)
                else jsonb_build_object('ids', public.month_leaders(l.team_id, ym), 'final', false, 'year_month', ym) end);
end; $$;


revoke all on function public.crown_required(uuid) from public, anon, authenticated;
revoke all on function public.month_leaders(uuid, text) from public, anon, authenticated;
revoke all on function public.crowned_of(uuid, text) from public, anon, authenticated;
revoke all on function public.crown_state_core(uuid, text) from public, anon, authenticated;
revoke all on function public.crown_apply(uuid, text) from public, anon, authenticated;
revoke all on function public.crown_vote_core(uuid, text, text, text) from public, anon, authenticated;
revoke all on function public.coach_crown_vote(text, text, text) from public;
revoke all on function public.coach_crown_state(text, text) from public;
revoke all on function public.app_crown_vote(uuid, text, text) from public;
revoke all on function public.app_crown_state(uuid, text) from public;
grant execute on function public.coach_crown_vote(text, text, text) to anon, authenticated;
grant execute on function public.coach_crown_state(text, text) to anon, authenticated;
grant execute on function public.app_crown_vote(uuid, text, text) to authenticated;
grant execute on function public.app_crown_state(uuid, text) to authenticated;
