-- Stufe 61: Bewertungsfrist einer Runde kann nur verlaengert, nie verkuerzt
-- werden. Die App schreibt beim Nachtragen immer die 3-Tage-Frist – eine
-- von Hand verlaengerte Frist bleibt dadurch erhalten.
create or replace function public.peer_round_keep_longer()
returns trigger language plpgsql as $$
begin
  if new.closes_at < old.closes_at then
    new.closes_at := old.closes_at;
  end if;
  return new;
end; $$;

drop trigger if exists trg_peer_round_keep_longer on public.peer_rating_rounds;
create trigger trg_peer_round_keep_longer
  before update on public.peer_rating_rounds
  for each row execute function public.peer_round_keep_longer();

-- Einmalig (2026-11-15): die letzten 3 Spiele bis zum Anpfiff des naechsten
-- Spiels (SC Unterbach, 29.11.2026 13:15 Uhr) zur Bewertung freigeben.
update public.peer_rating_rounds
   set closes_at = '2026-11-29T12:15:00+00:00', updated_at = now()
 where match_id in ('26aadfe0-cd83-436d-a748-a80b1c188d53',
                    'd78d9c14-ed21-4c9d-abc2-263407a90e58',
                    '72fbaf40-0728-4e93-9964-15475755036d');
