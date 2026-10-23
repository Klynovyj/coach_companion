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

Spielerstammdaten lassen sich über **FuPa-Links** importieren – gleicher
Ansatz wie im Schwesterprojekt *Coach Studio*:

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
