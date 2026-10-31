-- stage41: Haupt-Ticker behält immer die volle Kontrolle; Delegierte sind
-- ZUSAETZLICH (nehmen ihm nichts weg). live_controller = Haupt-Ticker (Starter,
-- beide Seiten + Uhr), live_controller_opp = Gegner-Delegierter,
-- live_delegate_own = Eigen-Delegierter. Im Supabase SQL-Editor ausfuehren.

alter table public.matches
  add column if not exists live_delegate_own text,
  add column if not exists live_delegate_own_name text;
