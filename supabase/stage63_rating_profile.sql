-- Stufe 63: Profil fuer die Bewertungsseiten – Foto (FuPa) des Link-Inhabers und
-- Uebersicht seiner eigenen Abgaben je Spiel (letzte 6 Runden).
-- Trainer-Token: rater_id 'staff:<player_id>' hat ein Kader-Foto, App-Konten nicht.
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
  if cl.rater_id like 'staff:%' then
    pid := substr(cl.rater_id, 7);
    select coalesce(p.photo_fupa, p.photo) into ph from public.players p where p.id::text = pid;
  end if;
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

revoke all on function public.rating_profile(text) from public;
grant execute on function public.rating_profile(text) to anon, authenticated;
