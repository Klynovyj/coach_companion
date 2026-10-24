-- myCouch – Cloud-Daten zurücksetzen (Team/Kader/Spiele/Ereignisse)
-- Im Supabase SQL-Editor ausführen. Das LOGIN-KONTO bleibt bestehen
-- (auth.users + profiles werden NICHT gelöscht).
-- Reihenfolge wegen Fremdschlüsseln; teams löscht den Rest via CASCADE mit,
-- aber explizit ist sauberer.

delete from public.match_events;
delete from public.matches;
delete from public.players;
delete from public.team_members;
delete from public.teams;
