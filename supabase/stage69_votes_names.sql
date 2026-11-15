-- Stufe 69: Trainer-Stimmen liefern Namen/Fotos aller bewerteten Spieler mit
-- (sonst erscheint ein Spieler ausserhalb der Runde als 'Unbekannt').

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
