-- Stufe 59: Spieler-Bewertung ohne App-Zugang (persoenlicher Web-Link je Spieler).
-- Spieler ohne Konto bewerten nach dem Spiel ueber eine Webseite:
-- Mitspieler (1-5 Sterne), eigene Leistung, Spielnote, Spieler des Spiels.
-- Die Webseite nutzt nur die RPCs peer_rating_state / peer_rating_submit
-- (anon, Token-Pruefung). Trainer sehen nur Schnitte (peer_rating_summary).

-- ------------------------------------------------------------- Tabellen
-- Dauerhafter persoenlicher Link je Spieler (Token erzeugt die App).
create table if not exists public.peer_rating_links (
  player_id text primary key,
  team_id uuid not null references public.teams(id) on delete cascade,
  token text not null unique,
  created_at timestamptz not null default now()
);
create index if not exists idx_peer_links_team on public.peer_rating_links(team_id);

-- Bewertungsrunde je Spiel (Teilnehmer = Spieler mit Einsatz, von der App).
create table if not exists public.peer_rating_rounds (
  match_id text primary key,
  team_id uuid not null references public.teams(id) on delete cascade,
  title text not null default '',
  match_date timestamptz,
  closes_at timestamptz not null,
  players jsonb not null default '[]'::jsonb, -- [{id, name, number}]
  updated_at timestamptz not null default now()
);
create index if not exists idx_peer_rounds_team on public.peer_rating_rounds(team_id);

-- Abgaben: eine Zeile je (Spiel, bewertender Spieler). Kein direkter Lesezugriff
-- (Anonymitaet) – nur ueber die RPCs unten.
create table if not exists public.peer_ratings (
  match_id text not null,
  rater_player_id text not null,
  team_id uuid not null references public.teams(id) on delete cascade,
  stars jsonb not null default '{}'::jsonb, -- {playerId: 1..5}
  self_stars int,
  self_note text,
  match_stars int,
  match_note text,
  motm_player_id text,
  updated_at timestamptz not null default now(),
  primary key (match_id, rater_player_id)
);

-- ------------------------------------------------------------- RLS
alter table public.peer_rating_links enable row level security;
alter table public.peer_rating_rounds enable row level security;
alter table public.peer_ratings enable row level security; -- bewusst ohne Policy

drop policy if exists "trainer peer links" on public.peer_rating_links;
create policy "trainer peer links" on public.peer_rating_links
  for all using (public.is_team_trainer(team_id))
  with check (public.is_team_trainer(team_id));

drop policy if exists "trainer peer rounds" on public.peer_rating_rounds;
create policy "trainer peer rounds" on public.peer_rating_rounds
  for all using (public.is_team_trainer(team_id))
  with check (public.is_team_trainer(team_id));

-- ------------------------------------------------------------- Webseite (anon)
-- Zustand fuer den persoenlichen Link: Spieler, neueste Runde mit ihm,
-- eigene Abgabe, nach Fristende der Spieler des Spiels.
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
    with c as (
      select motm_player_id id, count(*) n from public.peer_ratings
       where match_id = r.match_id and motm_player_id is not null
       group by motm_player_id
    )
    select coalesce(jsonb_agg(jsonb_build_object('id', id, 'votes', n)), '[]'::jsonb)
      into motm from c where n = (select max(n) from c);
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
    'motm', motm
  );
end; $$;

-- Abgabe speichern (bis Fristende aenderbar). Ungueltige Teile werden verworfen.
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
  n int;
  s_self int;
  s_match int;
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
        n := round((v #>> '{}')::numeric);
        if n between 1 and 5 then
          clean := clean || jsonb_build_object(k, n);
        end if;
      end if;
    end loop;
  end if;

  if jsonb_typeof(p->'self_stars') = 'number' then
    s_self := round((p->>'self_stars')::numeric);
    if s_self not between 1 and 5 then s_self := null; end if;
  end if;
  if jsonb_typeof(p->'match_stars') = 'number' then
    s_match := round((p->>'match_stars')::numeric);
    if s_match not between 1 and 5 then s_match := null; end if;
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

-- ------------------------------------------------------------- App (Trainer)
-- Auswertung eines Spiels: nur Schnitte (nicht wer wem was gab).
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
    'motm', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'votes', n)
                       order by n desc, id)
       from (select motm_player_id id, count(*) n from public.peer_ratings
              where match_id = r.match_id and motm_player_id is not null
              group by motm_player_id) m), '[]'::jsonb),
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

-- Verlauf der Selbsteinschaetzung eines Spielers (Spieler-Detail, nur Trainer).
create or replace function public.peer_self_ratings(p_player_id text)
returns jsonb language sql security definer stable
set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'match_id', r.match_id, 'title', r.title, 'match_date', r.match_date,
      'stars', pr.self_stars, 'note', pr.self_note)
      order by r.match_date desc nulls last), '[]'::jsonb)
    from public.peer_ratings pr
    join public.peer_rating_rounds r on r.match_id = pr.match_id
   where pr.rater_player_id = p_player_id
     and public.is_team_trainer(r.team_id)
     and (pr.self_stars is not null or pr.self_note is not null);
$$;

revoke all on function public.peer_rating_state(text) from public;
revoke all on function public.peer_rating_submit(text, text, jsonb) from public;
revoke all on function public.peer_rating_summary(text) from public;
revoke all on function public.peer_self_ratings(text) from public;
grant execute on function public.peer_rating_state(text) to anon, authenticated;
grant execute on function public.peer_rating_submit(text, text, jsonb) to anon, authenticated;
grant execute on function public.peer_rating_summary(text) to authenticated;
grant execute on function public.peer_self_ratings(text) to authenticated;
