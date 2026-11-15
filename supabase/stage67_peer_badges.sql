-- Stufe 67: Abzeichen auf der Spieler-Seite.
-- Spieler des Spiels = aktueller Zwischenstand der neuesten Runde des Spielers
-- (Spitze inkl. Gleichstand, Spieler + Trainer gemeinsam), Spieler des Monats =
-- zuletzt gekuerter. Die Seite fragt das regelmaessig ab.
create or replace function public.peer_badges(p_token text)
returns jsonb language plpgsql security definer stable
set search_path = public as $$
declare
  l public.peer_rating_links;
  r public.peer_rating_rounds;
  motm jsonb := '[]'::jsonb;
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
  return jsonb_build_object(
    'ok', true,
    'match_id', r.match_id,
    'motm', motm,
    'pom', (select jsonb_build_object('id', h.player_id, 'year_month', h.year_month)
              from public.player_of_month h
             where h.team_id = l.team_id
             order by h.year_month desc limit 1));
end; $$;

revoke all on function public.peer_badges(text) from public;
grant execute on function public.peer_badges(text) to anon, authenticated;
