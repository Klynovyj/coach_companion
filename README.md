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

## Umgang mit FuPa-Daten (wichtig)

Es werden **ausschließlich offiziell erlaubte Datenzugänge** verwendet. Die
FuPa-Widgets werden **nicht** als versteckte Daten-API missbraucht.

Die Datenbeschaffung läuft über austauschbare Quellen
(`FupaDataSource`), geordnet nach Priorität:

1. `ApprovedApiFupaDataSource` – nur aktiv, wenn in den Einstellungen eine
   genehmigte Schnittstelle (Basis-URL + Token) hinterlegt ist.
2. `ManualFupaDataSource` – immer vorhanden, ruft nichts ab. Ohne genehmigten
   Zugang bleibt die App voll nutzbar: ein klarer Importstatus wird angezeigt,
   die Datenpflege erfolgt manuell.

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
