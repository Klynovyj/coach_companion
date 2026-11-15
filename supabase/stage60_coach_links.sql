-- Stufe 60: Bewertungs-Link auch fuer Trainer (mit oder ohne App-Konto).
-- Trainer bewerten ueber die Webseite wie in der App: Spielnote + Bericht
-- (match_ratings) und alle Spieler mit Einsatz (player_ratings). Die Noten
-- zaehlen in den Trainer-Schnitt. rater_id = auth-User-ID (App-Trainer) oder
-- 'staff:<player_id>' (Trainer/Betreuer aus dem Kader ohne Konto).
-- Voraussetzung: Stufe 59 (peer_rating_rounds).

create table if not exists public.coach_rating_links (
  rater_id text primary key,
  team_id uuid not null references public.teams(id) on delete cascade,
  token text not null unique,
  name text not null default '',
  created_at timestamptz not null default now()
);
create index if not exists idx_coach_links_team on public.coach_rating_links(team_id);

alter table public.coach_rating_links enable row level security;
drop policy if exists "trainer coach links" on public.coach_rating_links;
create policy "trainer coach links" on public.coach_rating_links
  for all using (public.is_team_trainer(team_id))
  with check (public.is_team_trainer(team_id));

-- Anzeigename eines Bewerters (Link-Name, Profil, sonst 'Trainer').
create or replace function public.coach_rater_name(t uuid, rid text)
returns text language sql security definer stable
set search_path = public as $$
  select coalesce(
    (select nullif(name, '') from public.coach_rating_links
      where team_id = t and rater_id = rid),
    (select nullif(display_name, '') from public.profiles where id::text = rid),
    'Trainer');
$$;

-- Runden fuer den Trainer-Link: offene + die letzten beendeten (max. 6).
create or replace function public.coach_rating_rounds(p_token text)
returns jsonb language plpgsql security definer stable
set search_path = public as $$
declare
  l public.coach_rating_links;
  res jsonb;
begin
  select * into l from public.coach_rating_links where token = p_token;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'invalid');
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'match_id', match_id, 'title', title, 'match_date', match_date,
      'closes_at', closes_at, 'open', now() <= closes_at)
      order by (now() <= closes_at) desc, match_date desc nulls last), '[]'::jsonb)
    into res
    from (select * from public.peer_rating_rounds where team_id = l.team_id
           order by (now() <= closes_at) desc, match_date desc nulls last
           limit 6) r;
  return jsonb_build_object('ok', true, 'name', l.name,
    'team', (select name from public.teams where id = l.team_id),
    'rounds', res);
end; $$;

-- Ein Spiel fuer den Trainer-Link: Spieler, eigene Abgabe und – nach eigener
-- Abgabe oder Fristende – die volle Auswertung.
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
  if mr.id is not null or stars <> '{}'::jsonb then
    mine := jsonb_build_object(
      'stars', stars,
      'match_stars', mr.rating,
      'note', mr.note,
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
      'motm', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'votes', n)
                         order by n desc, id)
         from (select motm_player_id id, count(*) n from public.peer_ratings
                where match_id = r.match_id and motm_player_id is not null
                group by motm_player_id) m), '[]'::jsonb),
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
    'self_player_id', case when l.rater_id like 'staff:%'
                           then substr(l.rater_id, 7) end,
    'mine', mine,
    'results', results);
end; $$;

-- Abgabe des Trainers: schreibt in player_ratings/match_ratings (wie die App).
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
  n int;
  keep text[] := '{}';
  abst boolean;
  ms double precision;
  nt text;
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
  me := case when l.rater_id like 'staff:%' then substr(l.rater_id, 7) end;
  abst := coalesce((p->>'abstained')::boolean, false);

  if not abst and jsonb_typeof(p->'stars') = 'object' then
    for k, v in select * from jsonb_each(p->'stars') loop
      if k = any(ids) and k is distinct from me and jsonb_typeof(v) = 'number' then
        n := round((v #>> '{}')::numeric);
        if n between 1 and 5 then
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
    ms := round((p->>'match_stars')::numeric);
    if ms not between 1 and 5 then ms := null; end if;
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
  return jsonb_build_object('ok', true);
end; $$;

revoke all on function public.coach_rater_name(uuid, text) from public, anon, authenticated;
revoke all on function public.coach_rating_rounds(text) from public;
revoke all on function public.coach_rating_detail(text, text) from public;
revoke all on function public.coach_rating_submit(text, text, jsonb) from public;
grant execute on function public.coach_rating_rounds(text) to anon, authenticated;
grant execute on function public.coach_rating_detail(text, text) to anon, authenticated;
grant execute on function public.coach_rating_submit(text, text, jsonb) to anon, authenticated;
