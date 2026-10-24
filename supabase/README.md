# myCouch – Mehrbenutzer (Supabase) · Stufe 1

Ziel von Stufe 1: **Konten/Login**, Team per **Einladungscode** beitreten und
ein **gemeinsames Live-Spiel** (ein Trainer tippt Ereignisse, alle sehen sie in
Echtzeit). Spieler sehen in Stufe 1 nur mit (keine Bearbeitung).

## Einrichtung (einmalig)

1. Auf https://supabase.com ein **neues Projekt** anlegen (Name z. B. `mycouch`).
   Region nah an Deutschland (z. B. `eu-central`).
2. Im Projekt den **SQL-Editor** öffnen und den Inhalt von
   [`schema.sql`](schema.sql) einfügen und ausführen (**Run**).
3. Unter **Authentication → Providers** `Email` aktiviert lassen. Für den Start
   am einfachsten: **„Confirm email" aus** (Einstellungen → Email), damit sich
   Trainer/Spieler ohne Bestätigungs-Mail anmelden können. Später wieder an.
4. Unter **Project Settings → API** findest du:
   - **Project URL** (z. B. `https://xxxx.supabase.co`)
   - **anon public** Key
   Diese beiden gib mir – damit binde ich die App an (sie landen in einer
   `lib/supabase_config.dart`, die nicht ins öffentliche Repo kommt).

## Rollen

- **trainer**: voller Zugriff (Spiele/Ereignisse anlegen und bearbeiten).
- **spieler**: nur Ansicht (lesen).

Der Ersteller eines Teams wird Trainer; weitere Trainer kann der Ersteller
später hochstufen (kommt in einer späteren Stufe als UI; vorerst per SQL).

## Nächste Schritte (nachdem du URL + anon-Key geliefert hast)

- `supabase_flutter` einbinden, Login/Registrierung, „Team anlegen"/„Beitreten".
- Online-Spiel: Ereignisse nach Supabase schreiben + Realtime-Abo für alle.
- Einmaliger Upload des lokalen Kaders (Namen) in die Cloud.
- Lokaler Offline-Modus bleibt als Rückfall erhalten.
