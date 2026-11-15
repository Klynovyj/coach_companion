-- Stufe 64: Spieler des Spiels gemeinsam (Spieler + Trainer), Spieler des
-- Monats auf den Bewertungsseiten (Rangliste, Kuerung per Link) und ein Link je
-- Trainer (App-Konto mit Kader-Foto). Voraussetzung: Stufen 59, 60, 62, 63.

-- Trainer-Stimmen fuer den Spieler des Spiels (eigene Tabelle, nicht im App-Sync).
create table if not exists public.coach_motm (
  match_id text not null,
  rater_id text not null,
  team_id uuid not null references public.teams(id) on delete cascade,
  player_id text not null,
  updated_at timestamptz not null default now(),
  primary key (match_id, rater_id)
);
alter table public.coach_motm enable row level security; -- nur ueber RPCs

-- Trainer-Link mit Kader-Person (Foto, eigene Person in der Spielerliste).
alter table public.coach_rating_links add column if not exists player_id text;

-- Gemeinsame Stimmen (Spieler + Trainer) eines Spiels, absteigend.
create or replace function public.motm_votes(p_match_id text)
returns jsonb language sql security definer stable
set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'votes', n)
                  order by n desc, id), '[]'::jsonb)
    from (select id, count(*) n from (
            select motm_player_id id from public.peer_ratings
             where match_id = p_match_id and motm_player_id is not null
            union all
            select player_id from public.coach_motm where match_id = p_match_id
          ) v group by id) x;
$$;
revoke all on function public.motm_votes(text) from public, anon, authenticated;

-- Kader-Person eines Trainer-Links (player_id, sonst aus 'staff:<id>').
create or replace function public.coach_link_player(l public.coach_rating_links)
returns text language sql immutable as $$
  select coalesce(l.player_id,
    case when l.rater_id like 'staff:%' then substr(l.rater_id, 7) end);
$$;


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
    'motm', motm
  );
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


-- Spieler des Monats (Trainer-Link): Rangliste nach Trainer-Schnitt (wie die
-- App: Monat aus matches.kickoff), Mannschafts-Schnitt, Gekuerter, Verlauf.
create or replace function public.coach_month(p_token text, p_year_month text)
returns jsonb language plpgsql security definer stable
set search_path = public as $$
declare
  l public.coach_rating_links;
  ym text;
begin
  select * into l from public.coach_rating_links where token = p_token;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'invalid');
  end if;
  ym := coalesce(nullif(p_year_month, ''),
                 to_char(now() at time zone 'Europe/Berlin', 'YYYY-MM'));
  return jsonb_build_object(
    'ok', true,
    'year_month', ym,
    'months', coalesce((select jsonb_agg(m order by m desc) from (
        select distinct to_char(kickoff at time zone 'Europe/Berlin', 'YYYY-MM') m
          from public.matches where team_id = l.team_id and kickoff is not null
           and kickoff <= now() + interval '1 day'
        union select ym) x), '[]'::jsonb),
    'ranking', coalesce((select jsonb_agg(jsonb_build_object(
        'id', p.id::text,
        'name', trim(coalesce(p.first_name, '') || ' ' || coalesce(p.last_name, '')),
        'number', p.number,
        'photo', p.photo_fupa,
        't', jsonb_build_object('avg', t.a, 'n', t.c),
        'm', case when pm.c is null then null else jsonb_build_object('avg', pm.a, 'n', pm.c) end)
        order by t.a desc, t.c desc)
      from (select pr.player_id pid, avg(pr.rating) a, count(*) c
              from public.player_ratings pr
              join public.matches mt on mt.id::text = pr.match_id
             where mt.team_id = l.team_id
               and to_char(mt.kickoff at time zone 'Europe/Berlin', 'YYYY-MM') = ym
             group by pr.player_id) t
      join public.players p on p.id::text = t.pid and p.team_id = l.team_id
      left join (select e.key pid, avg((e.value #>> '{}')::numeric) a, count(*) c
                   from public.peer_ratings x
                   join public.peer_rating_rounds rr on rr.match_id = x.match_id
                   , jsonb_each(x.stars) e
                  where rr.team_id = l.team_id
                    and to_char(rr.match_date at time zone 'Europe/Berlin', 'YYYY-MM') = ym
                  group by e.key) pm on pm.pid = t.pid), '[]'::jsonb),
    'honored', (select jsonb_build_object('year_month', h.year_month, 'id', h.player_id,
        'name', trim(coalesce(p.first_name, '') || ' ' || coalesce(p.last_name, '')),
        'number', p.number, 'photo', p.photo_fupa)
      from public.player_of_month h
      left join public.players p on p.id::text = h.player_id
     where h.team_id = l.team_id and h.year_month = ym),
    'history', coalesce((select jsonb_agg(jsonb_build_object('year_month', h.year_month,
        'id', h.player_id,
        'name', trim(coalesce(p.first_name, '') || ' ' || coalesce(p.last_name, '')),
        'number', p.number, 'photo', p.photo_fupa) order by h.year_month desc)
      from (select * from public.player_of_month where team_id = l.team_id
             order by year_month desc limit 6) h
      left join public.players p on p.id::text = h.player_id), '[]'::jsonb));
end; $$;

-- Spieler des Monats kueren (Trainer-Link); player_id null = Kuerung aufheben.
create or replace function public.coach_crown_month(
  p_token text, p_year_month text, p_player_id text)
returns jsonb language plpgsql security definer volatile
set search_path = public as $$
declare
  l public.coach_rating_links;
begin
  select * into l from public.coach_rating_links where token = p_token;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'invalid');
  end if;
  if p_year_month !~ '^[0-9]{4}-[0-9]{2}$' then
    return jsonb_build_object('ok', false, 'error', 'month');
  end if;
  if p_player_id is null then
    delete from public.player_of_month
     where team_id = l.team_id and year_month = p_year_month;
    return jsonb_build_object('ok', true);
  end if;
  if not exists (select 1 from public.players
                  where id::text = p_player_id and team_id = l.team_id) then
    return jsonb_build_object('ok', false, 'error', 'player');
  end if;
  insert into public.player_of_month (id, team_id, year_month, player_id, created_at)
  values (gen_random_uuid()::text, l.team_id, p_year_month, p_player_id,
          to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'))
  on conflict (team_id, year_month) do update set player_id = excluded.player_id;
  return jsonb_build_object('ok', true);
end; $$;

-- Gekuerter Spieler des Monats fuer die Spieler-Seite (aktueller, sonst letzter).
create or replace function public.peer_month(p_token text)
returns jsonb language plpgsql security definer stable
set search_path = public as $$
declare
  l public.peer_rating_links;
begin
  select * into l from public.peer_rating_links where token = p_token;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'invalid');
  end if;
  return jsonb_build_object('ok', true, 'honored',
    (select jsonb_build_object('year_month', h.year_month, 'id', h.player_id,
        'name', trim(coalesce(p.first_name, '') || ' ' || coalesce(p.last_name, '')),
        'number', p.number, 'photo', p.photo_fupa)
       from public.player_of_month h
       left join public.players p on p.id::text = h.player_id
      where h.team_id = l.team_id
      order by h.year_month desc limit 1));
end; $$;

revoke all on function public.coach_month(text, text) from public;
revoke all on function public.coach_crown_month(text, text, text) from public;
revoke all on function public.peer_month(text) from public;
grant execute on function public.coach_month(text, text) to anon, authenticated;
grant execute on function public.coach_crown_month(text, text, text) to anon, authenticated;
grant execute on function public.peer_month(text) to anon, authenticated;



-- Einmalig (2026-11-15, Team Garather SV): ein Link je Trainer.
-- Andrej: App-Konto-Link bekommt Kader-Name/-Foto; Kader-Link (ohne Abgaben) weg.
-- Jan: sein geteilter Kader-Link schreibt kuenftig als sein App-Konto.
do $$
declare
  t uuid := 'e8f6ee4d-4a71-4eaa-86db-8b97a5057a6b';
  andrej_pid text := 'acbdd807-6d6f-4700-8c4f-583498962dab';
  jan_pid text := '81893bdb-0b85-4aa6-aef6-1cb396755df7';
  andrej_uid text;
  jan_uid text;
begin
  select tm.created_by::text into andrej_uid from public.teams tm where tm.id = t;
  select m.user_id::text into jan_uid
    from public.team_members m join auth.users u on u.id = m.user_id
   where m.team_id = t and u.email ilike 'jan%' and m.user_id::text <> andrej_uid
   limit 1;
  if andrej_uid is not null and exists (select 1 from public.coach_rating_links
       where rater_id = andrej_uid) then
    update public.coach_rating_links set name = 'Andrej Chenfeld', player_id = andrej_pid
     where rater_id = andrej_uid;
    delete from public.coach_rating_links where rater_id = 'staff:' || andrej_pid
       and not exists (select 1 from public.player_ratings where user_id = 'staff:' || andrej_pid)
       and not exists (select 1 from public.match_ratings where user_id = 'staff:' || andrej_pid);
  end if;
  if jan_uid is not null and not exists (select 1 from public.coach_rating_links
       where rater_id = jan_uid) then
    update public.coach_rating_links set rater_id = jan_uid, player_id = jan_pid
     where rater_id = 'staff:' || jan_pid
       and not exists (select 1 from public.player_ratings where user_id = 'staff:' || jan_pid)
       and not exists (select 1 from public.match_ratings where user_id = 'staff:' || jan_pid);
  end if;
end $$;
