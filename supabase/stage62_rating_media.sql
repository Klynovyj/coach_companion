-- Stufe 62: Logos und Spielerfotos fuer die Bewertungsseiten.
-- rating_media(token, match_id) nimmt Spieler- (peer_rating_links) und
-- Trainer-Token (coach_rating_links) an und liefert nur Daten des eigenen Teams:
-- Teamlogo, Gegnerlogo, Ergebnis, Heim/Auswaerts, FuPa-Fotos der Spieler der
-- Runde und die Gegnerlogos der letzten Runden (Spiel-Kacheln).
create or replace function public.rating_media(p_token text, p_match_id text)
returns jsonb language plpgsql security definer stable
set search_path = public as $$
declare
  t uuid;
  r public.peer_rating_rounds;
  m public.matches;
  tm public.teams;
  photos jsonb;
  logos jsonb;
begin
  select team_id into t from public.peer_rating_links where token = p_token;
  if t is null then
    select team_id into t from public.coach_rating_links where token = p_token;
  end if;
  if t is null then
    return jsonb_build_object('ok', false, 'error', 'invalid');
  end if;
  select * into tm from public.teams where id = t;

  select coalesce(jsonb_object_agg(x.match_id, x.opponent_logo), '{}'::jsonb)
    into logos
    from (select rr.match_id, mm.opponent_logo
            from public.peer_rating_rounds rr
            join public.matches mm on mm.id::text = rr.match_id
           where rr.team_id = t and mm.opponent_logo is not null
           order by rr.match_date desc nulls last limit 6) x;

  select * into r from public.peer_rating_rounds
   where match_id = p_match_id and team_id = t;
  if not found then
    return jsonb_build_object('ok', true,
      'us', jsonb_build_object('name', tm.name, 'logo', tm.logo),
      'logos', logos);
  end if;
  select * into m from public.matches where id::text = r.match_id;

  select coalesce(jsonb_object_agg(p.id::text, p.photo_fupa), '{}'::jsonb)
    into photos
    from public.players p
   where p.team_id = t and p.photo_fupa is not null
     and p.id::text in (select e->>'id' from jsonb_array_elements(r.players) e);

  return jsonb_build_object(
    'ok', true,
    'us', jsonb_build_object('name', coalesce(tm.short_name, tm.name), 'logo', tm.logo),
    'opp', jsonb_build_object('name', m.opponent, 'logo', m.opponent_logo),
    'home', coalesce(m.venue, 'Heim') not in ('away', 'Auswärts'),
    'own_score', m.own_score,
    'opp_score', m.opponent_score,
    'photos', photos,
    'logos', logos);
end; $$;

revoke all on function public.rating_media(text, text) from public;
grant execute on function public.rating_media(text, text) to anon, authenticated;
