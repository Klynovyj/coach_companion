-- Stufe 65: halbe Sterne (0,5 ... 5 in halben Schritten) bei allen Bewertungen.
-- peer_ratings: Spiel- und Selbstnote als numeric; Abgaben runden auf 0,5.
alter table public.peer_ratings
  alter column self_stars type numeric(2,1) using self_stars::numeric,
  alter column match_stars type numeric(2,1) using match_stars::numeric;

create or replace function public.peer_rating_submit(
  p_token text, p_match_id text, p jsonb)
returns jsonb language plpgsql security definer volatile
set search_path = public as $$
declare
  l public.peer_rating_links;
  r public.peer_rating_rounds;
  ids text[];
  clean jsonb := '{}'::jsonb;
  k text;
  v jsonb;
  n numeric;
  s_self numeric;
  s_match numeric;
  motm text;
begin
  select * into l from public.peer_rating_links where token = p_token;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'invalid');
  end if;
  select * into r from public.peer_rating_rounds
   where match_id = p_match_id and team_id = l.team_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_round');
  end if;
  select array_agg(e->>'id') into ids from jsonb_array_elements(r.players) e;
  if ids is null or not (l.player_id = any(ids)) then
    return jsonb_build_object('ok', false, 'error', 'not_in_round');
  end if;
  if now() > r.closes_at then
    return jsonb_build_object('ok', false, 'error', 'closed');
  end if;

  if jsonb_typeof(p->'stars') = 'object' then
    for k, v in select * from jsonb_each(p->'stars') loop
      if k <> l.player_id and k = any(ids) and jsonb_typeof(v) = 'number' then
        n := round((v #>> '{}')::numeric * 2) / 2;
        if n between 0.5 and 5 then
          clean := clean || jsonb_build_object(k, n);
        end if;
      end if;
    end loop;
  end if;

  if jsonb_typeof(p->'self_stars') = 'number' then
    s_self := round((p->>'self_stars')::numeric * 2) / 2;
    if s_self not between 0.5 and 5 then s_self := null; end if;
  end if;
  if jsonb_typeof(p->'match_stars') = 'number' then
    s_match := round((p->>'match_stars')::numeric * 2) / 2;
    if s_match not between 0.5 and 5 then s_match := null; end if;
  end if;
  motm := p->>'motm_player_id';
  if motm is not null and (motm = l.player_id or not (motm = any(ids))) then
    motm := null;
  end if;

  insert into public.peer_ratings as t (match_id, rater_player_id, team_id,
    stars, self_stars, self_note, match_stars, match_note, motm_player_id,
    updated_at)
  values (r.match_id, l.player_id, l.team_id, clean, s_self,
    nullif(left(trim(coalesce(p->>'self_note', '')), 1000), ''),
    s_match,
    nullif(left(trim(coalesce(p->>'match_note', '')), 1000), ''),
    motm, now())
  on conflict (match_id, rater_player_id) do update set
    stars = excluded.stars,
    self_stars = excluded.self_stars,
    self_note = excluded.self_note,
    match_stars = excluded.match_stars,
    match_note = excluded.match_note,
    motm_player_id = excluded.motm_player_id,
    updated_at = now();
  return jsonb_build_object('ok', true);
end; $$;

create or replace function public.coach_rating_submit(
  p_token text, p_match_id text, p jsonb)
returns jsonb language plpgsql security definer volatile
set search_path = public as $$
declare
  l public.coach_rating_links;
  r public.peer_rating_rounds;
  ids text[];
  me text;
  k text;
  v jsonb;
  n numeric;
  keep text[] := '{}';
  abst boolean;
  ms double precision;
  nt text;
  mv text;
  now_iso text := to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
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
  if now() > r.closes_at then
    return jsonb_build_object('ok', false, 'error', 'closed');
  end if;
  select array_agg(e->>'id') into ids from jsonb_array_elements(r.players) e;
  ids := coalesce(ids, '{}');
  me := public.coach_link_player(l);
  abst := coalesce((p->>'abstained')::boolean, false);

  if not abst and jsonb_typeof(p->'stars') = 'object' then
    for k, v in select * from jsonb_each(p->'stars') loop
      if k = any(ids) and k is distinct from me and jsonb_typeof(v) = 'number' then
        n := round((v #>> '{}')::numeric * 2) / 2;
        if n between 0.5 and 5 then
          keep := keep || k;
          insert into public.player_ratings as t
            (id, team_id, match_id, player_id, user_id, rating, created_at)
          values (gen_random_uuid()::text, l.team_id, r.match_id, k,
                  l.rater_id, n, now_iso)
          on conflict (match_id, player_id, user_id)
            do update set rating = excluded.rating;
        end if;
      end if;
    end loop;
  end if;
  -- Zurueckgenommene Sterne (bzw. alle bei Abwesenheit) entfernen.
  delete from public.player_ratings
   where match_id = r.match_id and user_id = l.rater_id
     and not (player_id = any(keep));

  if not abst and jsonb_typeof(p->'match_stars') = 'number' then
    ms := round((p->>'match_stars')::numeric * 2) / 2;
    if ms not between 0.5 and 5 then ms := null; end if;
  end if;
  nt := nullif(left(trim(coalesce(p->>'note', '')), 4000), '');

  insert into public.match_ratings as t
    (id, team_id, match_id, user_id, rating, abstained, note, created_at, updated_at)
  values (gen_random_uuid()::text, l.team_id, r.match_id, l.rater_id, ms,
          case when abst then 1 else 0 end, nt, now_iso, now())
  on conflict (match_id, user_id) do update set
    rating = excluded.rating,
    abstained = excluded.abstained,
    note = excluded.note,
    updated_at = now();
  -- Spieler des Spiels (gemeinsame Wahl); bei Abwesenheit keine Stimme.
  mv := p->>'motm_player_id';
  if abst or mv is null or not (mv = any(ids)) or mv is not distinct from me then
    delete from public.coach_motm
     where match_id = r.match_id and rater_id = l.rater_id;
  else
    insert into public.coach_motm (match_id, rater_id, team_id, player_id, updated_at)
    values (r.match_id, l.rater_id, l.team_id, mv, now())
    on conflict (match_id, rater_id) do update set
      player_id = excluded.player_id, updated_at = now();
  end if;
  return jsonb_build_object('ok', true);
end; $$;
