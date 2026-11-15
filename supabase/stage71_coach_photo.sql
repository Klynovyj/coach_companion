-- Stufe 71: Foto direkt am Trainer-Link (reine Trainer ohne Spieler-Zeile in der
-- Cloud haben sonst kein Foto). Die App laedt eine kleine Kopie hoch.
alter table public.coach_rating_links add column if not exists photo text;

create or replace function public.rating_profile(p_token text)
returns jsonb language plpgsql security definer stable
set search_path = public as $$
declare
  pl public.peer_rating_links;
  cl public.coach_rating_links;
  pid text;
  nm text;
  ph text;
  entries jsonb;
begin
  select * into pl from public.peer_rating_links where token = p_token;
  if found then
    select coalesce(nullif(trim(coalesce(p.first_name, '') || ' ' || coalesce(p.last_name, '')), ''), ''),
           coalesce(p.photo_fupa, p.photo)
      into nm, ph from public.players p where p.id::text = pl.player_id;
    select coalesce(jsonb_agg(jsonb_build_object(
        'match_id', r.match_id, 'title', r.title, 'match_date', r.match_date,
        'open', now() <= r.closes_at,
        'done', pr.match_id is not null,
        'match_stars', pr.match_stars,
        'self_stars', pr.self_stars,
        'rated', coalesce((select count(*) from jsonb_object_keys(pr.stars)), 0),
        'total', jsonb_array_length(r.players) - 1,
        'motm', pr.motm_player_id is not null)
        order by r.match_date desc nulls last), '[]'::jsonb)
      into entries
      from (select * from public.peer_rating_rounds
             where team_id = pl.team_id
               and players @> jsonb_build_array(jsonb_build_object('id', pl.player_id))
             order by match_date desc nulls last limit 6) r
      left join public.peer_ratings pr
        on pr.match_id = r.match_id and pr.rater_player_id = pl.player_id;
    return jsonb_build_object('ok', true, 'kind', 'player', 'name', nm,
      'photo', ph, 'entries', entries);
  end if;

  select * into cl from public.coach_rating_links where token = p_token;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'invalid');
  end if;
  pid := public.coach_link_player(cl);
  if pid is not null then
    select coalesce(p.photo_fupa, p.photo) into ph from public.players p where p.id::text = pid;
  end if;
  -- Trainer ohne Spieler-Zeile in der Cloud: Foto direkt am Link.
  ph := coalesce(ph, cl.photo);
  select coalesce(jsonb_agg(jsonb_build_object(
      'match_id', r.match_id, 'title', r.title, 'match_date', r.match_date,
      'open', now() <= r.closes_at,
      'done', mr.id is not null or exists (select 1 from public.player_ratings x
                where x.match_id = r.match_id and x.user_id = cl.rater_id),
      'abstained', coalesce(mr.abstained, 0) = 1,
      'match_stars', mr.rating,
      'report', coalesce(trim(mr.note), '') <> '',
      'rated', (select count(*) from public.player_ratings x
                 where x.match_id = r.match_id and x.user_id = cl.rater_id),
      'total', jsonb_array_length(r.players)
               - case when pid is not null and r.players @> jsonb_build_array(jsonb_build_object('id', pid)) then 1 else 0 end)
      order by r.match_date desc nulls last), '[]'::jsonb)
    into entries
    from (select * from public.peer_rating_rounds where team_id = cl.team_id
           order by match_date desc nulls last limit 6) r
    left join public.match_ratings mr
      on mr.match_id = r.match_id and mr.user_id = cl.rater_id;
  return jsonb_build_object('ok', true, 'kind', 'coach', 'name', cl.name,
    'photo', ph, 'entries', entries);
end; $$;

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
      'photo', (select coalesce(p.photo_fupa, p.photo, l.photo) from public.coach_rating_links l
                  left join public.players p on p.id::text = public.coach_link_player(l)
                 where l.rater_id = x.rid limit 1),
      'match_stars', mr.rating,
      'abstained', coalesce(mr.abstained, 0) = 1,
      'note', nullif(trim(coalesce(mr.note, '')), ''),
      'motm_player_id', (select player_id from public.coach_motm
                          where match_id = p_match_id and rater_id = x.rid),
      'stars', coalesce((select jsonb_object_agg(player_id, rating)
                           from public.player_ratings
                          where match_id = p_match_id and user_id = x.rid), '{}'::jsonb),
      -- Namen/Fotos aller bewerteten Spieler (auch wenn nicht in der Runde).
      'players', coalesce((select jsonb_object_agg(pr.player_id, jsonb_build_object(
                             'name', nullif(trim(coalesce(p.first_name, '') || ' ' || coalesce(p.last_name, '')), ''),
                             'number', p.number, 'photo', p.photo_fupa))
                           from public.player_ratings pr
                           left join public.players p on p.id::text = pr.player_id
                          where pr.match_id = p_match_id and pr.user_id = x.rid), '{}'::jsonb))
      order by public.coach_rater_name((select team_id from r), x.rid)), '[]'::jsonb)
    from raters x
    left join public.match_ratings mr on mr.match_id = p_match_id and mr.user_id = x.rid
   where x.rid is not null;
$$;
