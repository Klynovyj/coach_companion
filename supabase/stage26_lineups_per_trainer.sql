-- myCoach – Stufe 26: Mehrere Aufstellungen je Spiel (eine je Trainer) + Freigabe.
-- Macht aus „eine Aufstellung je Spiel/Team" -> „eine je Spiel/Team/Trainer".
-- Im Supabase SQL-Editor ausfuehren.

alter table public.lineups
  add column if not exists created_by text,
  add column if not exists creator_name text,
  add column if not exists released int not null default 0,
  add column if not exists suggestion_of text;

-- Bestehende (einzige) Aufstellung je Spiel/Team als freigegeben markieren.
update public.lineups set released = 1 where released is null or released = 0;

-- Alte Eindeutigkeit (match, team) entfernen – egal ob als Constraint oder Index.
do $$
begin
  if exists (select 1 from pg_constraint
             where conname = 'lineups_match_id_team_id_key') then
    alter table public.lineups drop constraint lineups_match_id_team_id_key;
  end if;
exception when others then null;
end $$;

drop index if exists public.lineups_match_team;
drop index if exists public.idx_lineup_match_team;

-- Neue Eindeutigkeit je (Spiel, Team, Trainer).
create unique index if not exists lineups_match_team_creator
  on public.lineups (match_id, team_id, created_by);
