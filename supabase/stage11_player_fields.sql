-- Stufe 11: Spieler-Felder teilen (Status/Deaktivierung, Kapitän, Positionen …).
--
-- Bisher lagen diese Felder nur lokal; eine Deaktivierung (Status „inaktiv")
-- kam daher auf anderen Geräten nicht an. Jetzt synchronisieren sie über die
-- players-Tabelle mit.
--
-- Im Supabase SQL-Editor ausführen. Idempotent (mehrfach ausführbar).

alter table public.players add column if not exists status text;        -- fit/verletzt/krank/urlaub/inaktiv
alter table public.players add column if not exists active boolean;      -- false = deaktiviert
alter table public.players add column if not exists captain_role text;   -- Kapitän/Vize
alter table public.players add column if not exists nickname text;       -- Spitzname
alter table public.players add column if not exists positions text;      -- aktuelle Position(en), kommagetrennt
alter table public.players add column if not exists wish_position text;  -- Wunschposition
alter table public.players add column if not exists staff_role text;     -- Trainer/Co-Trainer etc.
