-- Stufe 66: Uebersicht aller Abstimmungen fuer Trainer (App + Trainer-Link).
-- Je Spiel: Trainer-Note + Stand, Mannschafts-Note + Stand, Spieler des Spiels.
-- Trainer-Stimmen einzeln (mit Namen); Spieler bleiben anonym (nur Schnitte).
-- Voraussetzung: Stufen 59, 60, 64.

create or replace function public.rating_overview_core(t uuid)
returns jsonb language sql security definer stable
set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'match_id', r.match_id,
      'title', r.title,
      'match_date', r.match_date,
      'closes_at', r.closes_at,
      'open', now() <= r.closes_at,
      'coach_avg', (select avg(rating) from public.match_ratings
                     where match_id = r.match_id and rating is not null
                       and coalesce(abstained, 0) = 0),
      'coach_n', (select count(*) from public.match_ratings
                   where match_id = r.match_id and rating is not null
                     and coalesce(abstained, 0) = 0),
      'coach_done', cd.n,
      'coach_total', greatest(cd.n, (select count(*) from public.coach_rating_links
                                      where team_id = t)),
      'team_avg', (select avg(match_stars) from public.peer_ratings
                    where match_id = r.match_id and match_stars is not null),
      'team_n', (select count(match_stars) from public.peer_ratings
                  where match_id = r.match_id),
      'voters', (select count(*) from public.peer_ratings where match_id = r.match_id),
      'players', jsonb_array_length(r.players),
      'motm', (select jsonb_build_object('id', v->>'id', 'votes', (v->>'votes')::int,
                 'name', coalesce(nullif(trim(coalesce(p.first_name, '') || ' ' || coalesce(p.last_name, '')), ''),
                                  (select e->>'name' from jsonb_array_elements(r.players) e
                                    where e->>'id' = v->>'id' limit 1)),
                 'number', p.number, 'photo', p.photo_fupa)
                 from jsonb_array_elements(public.motm_votes(r.match_id)) with ordinality x(v, i)
                 left join public.players p on p.id::text = v->>'id'
                order by i limit 1))
      order by r.match_date desc nulls last), '[]'::jsonb)
    from public.peer_rating_rounds r
    cross join lateral (
      select count(*) n from (
        select user_id from public.match_ratings where match_id = r.match_id
        union select user_id from public.player_ratings where match_id = r.match_id
        union select rater_id from public.coach_motm where match_id = r.match_id
      ) u) cd
   where r.team_id = t;
$$;

create or replace function public.coach_votes_core(p_match_id text)
returns jsonb language sql security definer stable
set search_path = public as $$
  with r as (select * from public.peer_rating_rounds where match_id = p_match_id),
  raters as (
    select user_id rid from public.match_ratings where match_id = p_match_id
    union select user_id from public.player_ratings where match_id = p_match_id
    union select rater_id from public.coach_motm where match_id = p_match_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'rater_id', x.rid,
      'name', public.coach_rater_name((select team_id from r), x.rid),
      'photo', (select coalesce(p.photo_fupa, p.photo) from public.coach_rating_links l
                  join public.players p on p.id::text = public.coach_link_player(l)
                 where l.rater_id = x.rid limit 1),
      'match_stars', mr.rating,
      'abstained', coalesce(mr.abstained, 0) = 1,
      'note', nullif(trim(coalesce(mr.note, '')), ''),
      'motm_player_id', (select player_id from public.coach_motm
                          where match_id = p_match_id and rater_id = x.rid),
      'stars', coalesce((select jsonb_object_agg(player_id, rating)
                           from public.player_ratings
                          where match_id = p_match_id and user_id = x.rid), '{}'::jsonb))
      order by public.coach_rater_name((select team_id from r), x.rid)), '[]'::jsonb)
    from raters x
    left join public.match_ratings mr on mr.match_id = p_match_id and mr.user_id = x.rid
   where x.rid is not null;
$$;

revoke all on function public.rating_overview_core(uuid) from public, anon, authenticated;
revoke all on function public.coach_votes_core(text) from public, anon, authenticated;

-- App (Trainer des Teams).
create or replace function public.rating_overview(p_team uuid)
returns jsonb language plpgsql security definer stable
set search_path = public as $$
begin
  if not public.is_team_trainer(p_team) then
    raise exception 'Nur fuer Trainer';
  end if;
  return public.rating_overview_core(p_team);
end; $$;

create or replace function public.rating_coach_votes(p_match_id text)
returns jsonb language plpgsql security definer stable
set search_path = public as $$
declare
  t uuid;
begin
  select team_id into t from public.peer_rating_rounds where match_id = p_match_id;
  if t is null then
    -- Spiel ohne Runde: Team aus den Trainer-Noten bestimmen.
    select team_id into t from public.match_ratings where match_id = p_match_id limit 1;
  end if;
  if t is null then return '[]'::jsonb; end if;
  if not public.is_team_trainer(t) then
    raise exception 'Nur fuer Trainer';
  end if;
  return public.coach_votes_core(p_match_id);
end; $$;

-- Trainer-Link.
create or replace function public.coach_overview(p_token text)
returns jsonb language plpgsql security definer stable
set search_path = public as $$
declare
  l public.coach_rating_links;
begin
  select * into l from public.coach_rating_links where token = p_token;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'invalid');
  end if;
  return jsonb_build_object('ok', true, 'games', public.rating_overview_core(l.team_id));
end; $$;

create or replace function public.coach_votes(p_token text, p_match_id text)
returns jsonb language plpgsql security definer stable
set search_path = public as $$
declare
  l public.coach_rating_links;
  r public.peer_rating_rounds;
begin
  select * into l from public.coach_rating_links where token = p_token;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'invalid');
  end if;
  select * into r from public.peer_rating_rounds
   where match_id = p_match_id and team_id = l.team_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_round');
  end if;
  -- Wie die Auswertung: erst nach eigener Abgabe oder Fristende.
  if now() <= r.closes_at
     and not exists (select 1 from public.match_ratings where match_id = r.match_id and user_id = l.rater_id)
     and not exists (select 1 from public.player_ratings where match_id = r.match_id and user_id = l.rater_id)
     and not exists (select 1 from public.coach_motm where match_id = r.match_id and rater_id = l.rater_id) then
    return jsonb_build_object('ok', true, 'locked', true, 'votes', '[]'::jsonb);
  end if;
  return jsonb_build_object('ok', true, 'locked', false, 'votes', public.coach_votes_core(r.match_id));
end; $$;

revoke all on function public.rating_overview(uuid) from public;
revoke all on function public.rating_coach_votes(text) from public;
revoke all on function public.coach_overview(text) from public;
revoke all on function public.coach_votes(text, text) from public;
grant execute on function public.rating_overview(uuid) to authenticated;
grant execute on function public.rating_coach_votes(text) to authenticated;
grant execute on function public.coach_overview(text) to anon, authenticated;
grant execute on function public.coach_votes(text, text) to anon, authenticated;
