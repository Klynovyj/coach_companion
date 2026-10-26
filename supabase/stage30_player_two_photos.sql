-- myCoach – Stufe 30: Zwei Fotos je Spieler (FuPa + eigenes) + Auswahl.
-- Der FuPa-Import schreibt nur photo_fupa; das selbst hochgeladene Foto
-- (photo_custom) bleibt erhalten. use_custom_photo entscheidet, welches gilt.
-- Nach den bisherigen Stages im SQL-Editor ausfuehren.

alter table public.players
  add column if not exists photo_fupa text,
  add column if not exists photo_custom text,
  add column if not exists use_custom_photo int not null default 1;

-- Bestehendes Foto verlustfrei als „mein Foto" uebernehmen; der FuPa-Slot
-- fuellt sich beim naechsten Import automatisch.
update public.players
   set photo_custom = photo
 where photo is not null and photo_custom is null;
