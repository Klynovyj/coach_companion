-- Stufe 70: Spieler des Spiels = Podest nach Sternen (Trainer-Schnitt, ohne
-- Trainer-Noten der Mannschafts-Schnitt). Gleichstand teilt sich den Platz
-- (dichte Raenge 1-3). Die Wahl per Stimmen bleibt zusaetzlich sichtbar.

create or replace function public.match_star_podium(p_match_id text)
returns jsonb language sql security definer stable
set search_path = public as $$
  with t as (
    select player_id pid, avg(rating)::numeric av, count(*) n
      from public.player_ratings where match_id = p_match_id group by player_id
  ), m as (
    select e.key pid, avg((e.value #>> '{}')::numeric) av, count(*) n
      from public.peer_ratings pr, jsonb_each(pr.stars) e
     where pr.match_id = p_match_id group by e.key
  ), src as (
    select case when exists (select 1 from t) then 'trainer' else 'team' end s
  ), a as (
    select pid, round(av, 2) av, n from t where (select s from src) = 'trainer'
    union all
    select pid, round(av, 2), n from m where (select s from src) = 'team'
  ), r as (
    select pid, av, n, dense_rank() over (order by av desc) pl from a
  )
  select jsonb_build_object(
    'source', (select s from src),
    'ranking', coalesce((select jsonb_agg(jsonb_build_object('id', pid, 'avg', av, 'n', n, 'place', pl)
                          order by pl, pid) from r where pl <= 3), '[]'::jsonb));
$$;
revoke all on function public.match_star_podium(text) from public, anon, authenticated;


create or replace function public.peer_rating_state(p_token text)
returns jsonb language plpgsql security definer stable
set search_path = public as $$
declare
  l public.peer_rating_links;
  r public.peer_rating_rounds;
  mine public.peer_ratings;
  pname text;
  tname text;
  motm jsonb;
  is_open boolean;
begin
  select * into l from public.peer_rating_links where token = p_token;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'invalid');
  end if;
  select name into tname from public.teams where id = l.team_id;
  select coalesce(nullif(trim(coalesce(p.first_name, '') || ' ' ||
         coalesce(p.last_name, '')), ''), '')
    into pname from public.players p where p.id::text = l.player_id;

  select * into r from public.peer_rating_rounds
   where team_id = l.team_id
     and players @> jsonb_build_array(jsonb_build_object('id', l.player_id))
   order by closes_at desc limit 1;
  if not found then
    return jsonb_build_object('ok', true, 'player_id', l.player_id,
      'player_name', pname, 'team', tname, 'round', null);
  end if;

  if coalesce(pname, '') = '' then
    select e->>'name' into pname from jsonb_array_elements(r.players) e
     where e->>'id' = l.player_id limit 1;
  end if;
  is_open := now() <= r.closes_at;
  select * into mine from public.peer_ratings
   where match_id = r.match_id and rater_player_id = l.player_id;

  if not is_open then
    -- Nur die Spitze (bei Gleichstand mehrere); Spieler + Trainer gemeinsam.
    select coalesce(jsonb_agg(v), '[]'::jsonb) into motm
      from jsonb_array_elements(public.motm_votes(r.match_id)) v
     where (v->>'votes')::int = (select max((x->>'votes')::int)
                                   from jsonb_array_elements(public.motm_votes(r.match_id)) x);
  end if;

  return jsonb_build_object(
    'ok', true,
    'player_id', l.player_id,
    'player_name', pname,
    'team', tname,
    'round', jsonb_build_object(
      'match_id', r.match_id,
      'title', r.title,
      'match_date', r.match_date,
      'closes_at', r.closes_at,
      'open', is_open,
      'players', r.players
    ),
    'mine', case when mine.match_id is null then null else jsonb_build_object(
      'stars', mine.stars,
      'self_stars', mine.self_stars,
      'self_note', mine.self_note,
      'match_stars', mine.match_stars,
      'match_note', mine.match_note,
      'motm_player_id', mine.motm_player_id,
      'updated_at', mine.updated_at
    ) end,
    'motm', motm,
    'podium', case when is_open then null else public.match_star_podium(r.match_id) end
  );
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
    select coalesce(jsonb_agg(jsonb_build_object('id', e->>'id', 'avg', (e->>'avg')::numeric)), '[]'::jsonb)
      into motm
      from jsonb_array_elements(public.match_star_podium(r.match_id)->'ranking') e
     where (e->>'place')::int = 1;
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

create or replace function public.coach_rating_detail(p_token text, p_match_id text)
returns jsonb language plpgsql security definer stable
set search_path = public as $$
declare
  l public.coach_rating_links;
  r public.peer_rating_rounds;
  mr public.match_ratings;
  is_open boolean;
  mine jsonb;
  stars jsonb;
  my_motm text;
  results jsonb;
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
  is_open := now() <= r.closes_at;

  select * into mr from public.match_ratings
   where match_id = r.match_id and user_id = l.rater_id limit 1;
  select coalesce(jsonb_object_agg(player_id, rating), '{}'::jsonb) into stars
    from public.player_ratings
   where match_id = r.match_id and user_id = l.rater_id;
  select player_id into my_motm from public.coach_motm
   where match_id = r.match_id and rater_id = l.rater_id;
  if mr.id is not null or stars <> '{}'::jsonb or my_motm is not null then
    mine := jsonb_build_object(
      'stars', stars,
      'match_stars', mr.rating,
      'note', mr.note,
      'motm_player_id', my_motm,
      'abstained', coalesce(mr.abstained, 0) = 1);
  end if;

  if mine is not null or not is_open then
    select jsonb_build_object(
      'trainer_avg', coalesce((select jsonb_object_agg(pid, jsonb_build_object('avg', a, 'n', c))
         from (select player_id pid, avg(rating) a, count(*) c
                 from public.player_ratings where match_id = r.match_id
                group by player_id) x), '{}'::jsonb),
      'team_avg', coalesce((select jsonb_object_agg(pid, jsonb_build_object('avg', a, 'n', c))
         from (select e.key pid, avg((e.value #>> '{}')::numeric) a, count(*) c
                 from public.peer_ratings pr, jsonb_each(pr.stars) e
                where pr.match_id = r.match_id group by e.key) x), '{}'::jsonb),
      'motm', public.motm_votes(r.match_id),
      'podium', public.match_star_podium(r.match_id),
      'motm_coaches', (select count(*) from public.coach_motm where match_id = r.match_id),
      'trainer_match_avg', (select avg(rating) from public.match_ratings
                             where match_id = r.match_id and rating is not null),
      'trainer_match_n', (select count(rating) from public.match_ratings
                           where match_id = r.match_id),
      'team_match_avg', (select avg(match_stars) from public.peer_ratings
                          where match_id = r.match_id and match_stars is not null),
      'team_match_n', (select count(match_stars) from public.peer_ratings
                        where match_id = r.match_id),
      'voters', (select count(*) from public.peer_ratings where match_id = r.match_id),
      'reports', coalesce((select jsonb_agg(jsonb_build_object(
           'name', public.coach_rater_name(r.team_id, user_id),
           'stars', rating, 'note', note) order by updated_at nulls last)
         from public.match_ratings
        where match_id = r.match_id and coalesce(trim(note), '') <> ''), '[]'::jsonb),
      'team_notes', coalesce((select jsonb_agg(match_note order by md5(match_note))
         from public.peer_ratings
        where match_id = r.match_id and match_note is not null), '[]'::jsonb),
      'self', coalesce((select jsonb_agg(jsonb_build_object('id', rater_player_id,
           'stars', self_stars, 'note', self_note) order by rater_player_id)
         from public.peer_ratings where match_id = r.match_id
          and (self_stars is not null or self_note is not null)), '[]'::jsonb)
    ) into results;
  end if;

  return jsonb_build_object(
    'ok', true,
    'round', jsonb_build_object('match_id', r.match_id, 'title', r.title,
      'match_date', r.match_date, 'closes_at', r.closes_at, 'open', is_open,
      'players', r.players),
    'self_player_id', public.coach_link_player(l),
    'mine', mine,
    'results', results);
end; $$;

create or replace function public.peer_rating_summary(p_match_id text)
returns jsonb language plpgsql security definer stable
set search_path = public as $$
declare
  r public.peer_rating_rounds;
  res jsonb;
begin
  select * into r from public.peer_rating_rounds where match_id = p_match_id;
  if not found then return null; end if;
  if not public.is_team_trainer(r.team_id) then
    raise exception 'Nur fuer Trainer';
  end if;
  select jsonb_build_object(
    'match_id', r.match_id,
    'title', r.title,
    'closes_at', r.closes_at,
    'open', now() <= r.closes_at,
    'players', r.players,
    'voters', coalesce((select jsonb_agg(rater_player_id order by rater_player_id)
       from public.peer_ratings where match_id = r.match_id), '[]'::jsonb),
    'avg', coalesce((select jsonb_object_agg(pid, jsonb_build_object('avg', a, 'n', c))
       from (select e.key pid, avg((e.value #>> '{}')::numeric) a, count(*) c
               from public.peer_ratings pr, jsonb_each(pr.stars) e
              where pr.match_id = r.match_id group by e.key) x), '{}'::jsonb),
    'motm', public.motm_votes(r.match_id),
    'podium', public.match_star_podium(r.match_id),
    'match_avg', (select avg(match_stars) from public.peer_ratings
                   where match_id = r.match_id and match_stars is not null),
    'match_n', (select count(match_stars) from public.peer_ratings
                 where match_id = r.match_id),
    'match_notes', coalesce((select jsonb_agg(match_note order by md5(match_note))
       from public.peer_ratings
      where match_id = r.match_id and match_note is not null), '[]'::jsonb),
    'self', coalesce((select jsonb_agg(jsonb_build_object('id', rater_player_id,
         'stars', self_stars, 'note', self_note) order by rater_player_id)
       from public.peer_ratings where match_id = r.match_id
        and (self_stars is not null or self_note is not null)), '[]'::jsonb)
  ) into res;
  return res;
end; $$;

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
      'motm', (select jsonb_build_object('id', e->>'id', 'avg', (e->>'avg')::numeric,
                 'tie', (select count(*) from jsonb_array_elements(public.match_star_podium(r.match_id)->'ranking') z
                          where (z->>'place')::int = 1),
                 'name', coalesce(nullif(trim(coalesce(p.first_name, '') || ' ' || coalesce(p.last_name, '')), ''),
                                  (select x->>'name' from jsonb_array_elements(r.players) x
                                    where x->>'id' = e->>'id' limit 1)),
                 'number', p.number, 'photo', p.photo_fupa)
                 from jsonb_array_elements(public.match_star_podium(r.match_id)->'ranking') with ordinality y(e, i)
                 left join public.players p on p.id::text = e->>'id'
                where (e->>'place')::int = 1
                order by i limit 1),
      'motm_votes', (select jsonb_build_object('id', v->>'id', 'votes', (v->>'votes')::int)
                 from jsonb_array_elements(public.motm_votes(r.match_id)) with ordinality x(v, i)
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