-- myCoach – Stufe 16: Anpassbare Startelf-Grafik (teamweit)
-- Nach den vorherigen Stufen im Supabase SQL-Editor ausführen.
--
-- Eine Zeile pro Team (id = Team-id). Spiegelt die lokale SQLite-Tabelle
-- `graphic_settings` (+ team_id für RLS). logo/bg_image = Base64-Data-URLs,
-- grad_top/grad_bottom = Hex-Farben, overlay_opacity = int (0–100).
-- Lesen: alle Team-Mitglieder. Schreiben: Trainer/Admin.

create table if not exists public.graphic_settings (
  id text primary key,
  team_id uuid not null references public.teams(id) on delete cascade,
  title text,
  logo text,
  bg_image text,
  grad_top text,
  grad_bottom text,
  overlay_opacity int
);

alter table public.graphic_settings enable row level security;

drop policy if exists "read graphic_settings" on public.graphic_settings;
create policy "read graphic_settings" on public.graphic_settings
  for select using (public.is_team_member(team_id));

drop policy if exists "trainer write graphic_settings" on public.graphic_settings;
create policy "trainer write graphic_settings" on public.graphic_settings
  for all
  using (public.is_team_trainer(team_id))
  with check (public.is_team_trainer(team_id));

do $$
begin
  alter publication supabase_realtime add table public.graphic_settings;
exception when duplicate_object then null;
end $$;
