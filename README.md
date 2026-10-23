# Coach Companion

Trainer-App (Flutter) für Amateurfußball: Kader- und Spielplanverwaltung mit
optionalem FuPa-Import, automatischem Gegner-Sync und Live-Spielerfassung für
**beide** Mannschaften.

## Funktionen

- **FuPa-Teamlink verbinden** (Einstellungen): Link einfügen → „Mannschaft
  verbinden". Die App identifiziert die Mannschaft aus dem Link und importiert –
  sofern ein genehmigter Datenzugang hinterlegt ist – Kader und Spielplan.
  Manuelle Re-Synchronisierung per Knopfdruck.
- **Gegner automatisch vorbereiten**: Beim Öffnen eines Spiels prüft der
  `OpponentSyncService`, ob der Gegner bereits vorhanden ist. Falls nicht, löst
  er den genehmigten Import aus. Mehrfaches Synchronisieren erzeugt keine
  Dubletten (Dedup über externe ID bzw. normalisierten Namen).
- **Spielcenter**: zeigt beide Kader; Gegnerspieler lassen sich jederzeit
  manuell ergänzen.
- **Aufstellung**: Startelf, Formation und Ersatzbank bestimmt ausschließlich
  der Trainer. FuPa liefert nur Stammdaten, nie die Aufstellung.
- **Live-Modus**: Live-Uhr mit automatischer Spielminute; Tore (inkl.
  Torschütze + Vorlage), Karten und Wechsel für beide Teams mit wenigen Klicks;
  der Spielstand aktualisiert sich bei Toren automatisch.

## FuPa-Import

**Zentral in den Einstellungen:** Du fügst einen **FuPa-Teamlink** ein und
tippst „Verbinden & alles laden" – die App zieht daraus automatisch
Teamname & Logo, den **Kader inklusive Spielerfotos**, den **Spielplan**
(mit Ergebnissen und Gegner-Wappen) und die **Spieler-Statistik**.
„Neu synchronisieren" wiederholt das. Zusätzlich gibt es pro Bereich
(Kader/Spielplan/Statistik) weiterhin Einzel-Import-Buttons zum gezielten
Nachladen.

Technisch identischer Ansatz wie im Schwesterprojekt *Coach Studio*:

- Im Einfügen-Import (Kader bzw. Gegner) fügst du ein, beliebig gemischt:
  - einen **FuPa-Teamlink** (`…/team/…`) → holt den **ganzen Kader** auf einmal
    (`dataHistory[].TeamPlayersPage.data.players`) sowie **Vereinsname,
    Kurzname und Logo** (`data.info.club`, Logo als PNG-Data-URL),
  - **FuPa-Spielerlinks** (`…/player/…`) → je ein Spieler,
  - oder **Klartextzeilen** (`7 Max Mustermann Sturm`).
- Für jeden Link lädt die App die öffentliche Seite, extrahiert den
  eingebetteten `window.REDUX_DATA`-Block (`FupaReduxImporter`) und übernimmt
  **Name, Position und Trikotnummer**. Kein HTML-Scraping – es wird das von
  FuPa selbst gelieferte JSON gelesen; deaktivierte Spieler werden übersprungen.
- **Abhängigkeit:** Ändert FuPa das Seitenlayout, muss die Extraktion
  angepasst werden (wie bei Coach Studio auch).

Daneben gibt es weiterhin:

- den **Textparser** (`SquadPasteParser`) für kopierte Klartext-Listen
  (`7 Max Mustermann Sturm`),
- eine optionale **genehmigte Schnittstelle** (`ApprovedApiFupaDataSource`,
  Basis-URL + Token in den Einstellungen) für Team-/Spielplan-Importe,
- und reine **manuelle Pflege** – die App bleibt ohne jeden Online-Zugriff
  voll nutzbar.

Alle Importe laufen durch dieselbe **Duplikaterkennung** (`FupaPersistence`):
Abgleich über externe ID bzw. normalisierten Namen, kein Doppel-Import.

### Spielplan, Gegner-Kader und Statistik aus dem Teamlink

- **Spielplan** (Spielplan-Tab → „FuPa-Spielplan importieren"): liest
  `TeamMatchesPage.items` von `…/team/<slug>/matches` – alle Spiele mit Gegner,
  Datum, Heim/Auswärts, Wettbewerb, **Ergebnis** (gespielte Spiele als
  „beendet" inkl. Spielstand), Gegner-Teamlink und -Wappen.
- **Gegner-Kader automatisch**: Beim Öffnen eines Spiels lädt der
  `OpponentSyncService` den Gegnerkader über den im Spielplan gespeicherten
  FuPa-Teamlink (inkl. Name/Logo). Ohne Link: Platzhalter + manuelle Pflege.
- **Spieler-Statistik** (Kader-Tab → Diagramm-Symbol): liest
  `TeamPlayerStatsPage.season.players` von `…/team/<slug>/playerstats` –
  Spiele, Tore, Vorlagen, Karten, Minuten, Elf-des-Tages; sortierbare Tabelle.

Alle drei akzeptieren den Basis-Teamlink und hängen die passende Unterseite
selbst an.

## Architektur

```
lib/
  models/      Datenmodelle (Team, Player, Match, Lineup, Event, Rating)
  data/        SQLite-Datenbank + Repository
  services/
    fupa/      Import-Service, Quellen, Link-Parser, Persistenz, Registry
    opponent_sync_service.dart
  state/       AppState (ChangeNotifier) – verdrahtet alles
  screens/     Spielplan, Kader, Einstellungen, Spielcenter, Aufstellung, Live
  widgets/     wiederverwendbare UI (Kaderliste, Spieler-Dialog)
```

Persistenz: SQLite (`sqflite`, auf Desktop via `sqflite_common_ffi`). State:
`provider`.

## Entwicklung

```bash
flutter pub get
flutter run          # Android oder Windows
flutter analyze
flutter test
```
