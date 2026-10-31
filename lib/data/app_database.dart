import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Zentraler Datenbank-Zugang. SQLite läuft auf Mobile nativ und auf
/// Windows/Desktop über die FFI-Implementierung.
class AppDatabase {
  AppDatabase._() : _inMemory = false, _customPath = null;

  /// Nur für Tests: In-Memory, oder (mit [path]) eine echte Datei –
  /// um Neustart-/Persistenz-Verhalten nachzustellen.
  AppDatabase.test({String? path})
    : _inMemory = path == null,
      _customPath = path;

  static final AppDatabase instance = AppDatabase._();

  final bool _inMemory;
  final String? _customPath;
  Database? _db;

  static const _dbName = 'coach_companion.db';
  static const _dbVersion = 53;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _open();
    return _db!;
  }

  Future<Database> _open() async {
    // Desktop (Windows/Linux/macOS) und Tests benötigen die FFI-Factory.
    if (_inMemory ||
        _customPath != null ||
        Platform.isWindows ||
        Platform.isLinux ||
        Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    final path =
        _customPath ??
        (_inMemory
            ? inMemoryDatabasePath
            : p.join((await getApplicationDocumentsDirectory()).path, _dbName));

    return databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: _dbVersion,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: _createSchema,
        onUpgrade: _upgradeSchema,
      ),
    );
  }

  Future<void> _upgradeSchema(Database db, int oldV, int newV) async {
    // v1 -> v2: Vereinslogo am Team.
    if (oldV < 2) {
      await db.execute('ALTER TABLE teams ADD COLUMN logo_path TEXT');
    }
    // v2 -> v3: Gegner-Link und -Logo am Spiel (für Auto-Import/Anzeige).
    if (oldV < 3) {
      await db.execute('ALTER TABLE matches ADD COLUMN opponent_fupa_url TEXT');
      await db.execute(
        'ALTER TABLE matches ADD COLUMN opponent_logo_path TEXT',
      );
    }
    // v3 -> v4: Spieler-Saison-Statistik.
    if (oldV < 4) {
      await db.execute(_playerStatsTableSql);
    }
    // v4 -> v5: Spielerfoto.
    if (oldV < 5) {
      await db.execute('ALTER TABLE players ADD COLUMN photo_path TEXT');
    }
    // v5 -> v6: Nominierung/Verfügbarkeit je Spiel.
    if (oldV < 6) {
      await db.execute(_nominationsTableSql);
      await db.execute(
        'CREATE UNIQUE INDEX idx_nom_match_player ON match_nominations (match_id, player_id)',
      );
    }
    // v6 -> v7: Karten je Spieler.
    if (oldV < 7) {
      await db.execute(_cardEntriesTableSql);
      await db.execute(
        'CREATE INDEX idx_cards_player ON card_entries (player_id)',
      );
    }
    // v8 -> v9: Nachspielzeit am Live-Ereignis.
    if (oldV < 9) {
      await db.execute(
        'ALTER TABLE match_events ADD COLUMN minute_extra INTEGER NOT NULL DEFAULT 0',
      );
    }
    // v9 -> v10: freie Positionen in der Aufstellung.
    if (oldV < 10) {
      await db.execute('ALTER TABLE lineup_entries ADD COLUMN pos_x REAL');
      await db.execute('ALTER TABLE lineup_entries ADD COLUMN pos_y REAL');
    }
    // v10 -> v11: Nachspielzeit an der Karte.
    if (oldV < 11) {
      await db.execute(
        'ALTER TABLE card_entries ADD COLUMN minute_extra INTEGER NOT NULL DEFAULT 0',
      );
    }
    // v11 -> v12: Spieler-Status, Kapitäns-Rolle, Wunschposition.
    if (oldV < 12) {
      await db.execute(
        "ALTER TABLE players ADD COLUMN status TEXT NOT NULL DEFAULT 'fit'",
      );
      await db.execute(
        "ALTER TABLE players ADD COLUMN captain_role TEXT NOT NULL DEFAULT 'none'",
      );
      await db.execute('ALTER TABLE players ADD COLUMN wish_position TEXT');
    }
    // v12 -> v13: Notiz-Rubriken (zentral) + Rubrik an der Notiz.
    if (oldV < 13) {
      await db.execute(_noteCategoriesTableSql);
      // Notizen vor < v8 bekommen die Spalte bereits beim Anlegen der Tabelle
      // im v8-Block; ältere Bestände (v8..v12) brauchen das ALTER.
      if (oldV >= 8) {
        await db.execute(
          'ALTER TABLE player_notes ADD COLUMN category_id TEXT',
        );
      }
    }
    // v13 -> v14: Scouting-Marker für (Gegner-)Spieler.
    if (oldV < 14) {
      await db.execute(_playerMarkersTableSql);
    }
    // v14 -> v15: Eigene To-Dos für „Nachholen".
    if (oldV < 15) {
      await db.execute(_todosTableSql);
    }
    // v15 -> v16: Abwesenheiten (Verletzt/Krank/Gesperrt/Urlaub) mit Zeitraum.
    if (oldV < 16) {
      await db.execute(_playerAbsencesTableSql);
      await db.execute(
        'CREATE INDEX idx_absences_player ON player_absences (player_id)',
      );
    }
    // v16 -> v17: Fälligkeit, Erledigt-Zeitpunkt und Archiv an To-Dos.
    // Nur für Bestände, deren todos-Tabelle ohne diese Spalten angelegt wurde
    // (v15/v16). Ältere Bestände (< v15) bekommen die Tabelle im v15-Block
    // bereits mit den neuen Spalten über _todosTableSql.
    if (oldV < 17 && oldV >= 15) {
      await db.execute('ALTER TABLE todos ADD COLUMN due_date TEXT');
      await db.execute('ALTER TABLE todos ADD COLUMN completed_at TEXT');
      await db.execute(
        'ALTER TABLE todos ADD COLUMN archived INTEGER NOT NULL DEFAULT 0',
      );
    }
    // v17 -> v18: Geburtsdatum am Spieler (u.a. für Ball-/Materialdienst).
    if (oldV < 18) {
      await db.execute('ALTER TABLE players ADD COLUMN birthdate TEXT');
    }
    // v18 -> v19: aktuelle Positionen (Mehrfach) + Stammelf-Kennzeichen.
    if (oldV < 19) {
      await db.execute('ALTER TABLE players ADD COLUMN positions TEXT');
      await db.execute(
        'ALTER TABLE players ADD COLUMN is_starter INTEGER NOT NULL DEFAULT 0',
      );
    }
    // v19 -> v20: Trainerteam-Rolle am Spieler (null = Spieler).
    if (oldV < 20) {
      await db.execute('ALTER TABLE players ADD COLUMN staff_role TEXT');
    }
    // v20 -> v21: Spieltag-Nummer am Spiel (aus FuPa round.number).
    if (oldV < 21) {
      await db.execute('ALTER TABLE matches ADD COLUMN matchday INTEGER');
    }
    // v21 -> v22: Spitzname am Spieler.
    if (oldV < 22) {
      await db.execute('ALTER TABLE players ADD COLUMN nickname TEXT');
    }
    // v22 -> v23: Themen für Aufgaben + Zuordnung/Verantwortliche an der Aufgabe.
    if (oldV < 23) {
      await db.execute(_todoTopicsTableSql);
    }
    // Nur für DBs, deren todos-Tabelle noch ohne die neuen Spalten erzeugt
    // wurde (ab v15). Bei oldV < 15 kommen sie bereits über _todosTableSql.
    if (oldV < 23 && oldV >= 15) {
      await db.execute('ALTER TABLE todos ADD COLUMN topic_id TEXT');
      await db.execute('ALTER TABLE todos ADD COLUMN responsible TEXT');
    }
    // v23 -> v24: Notiz optional mit einem Spiel verknüpfen.
    // Nur für DBs mit player_notes-Tabelle (ab v8); bei oldV < 8 kommt die
    // Spalte bereits über _playerNotesTableSql.
    if (oldV < 24 && oldV >= 8) {
      await db.execute('ALTER TABLE player_notes ADD COLUMN match_id TEXT');
    }
    // v24 -> v25: Spielergespräche (ersetzen die Termine im Menü).
    if (oldV < 25) {
      await db.execute(_playerTalksTableSql);
    }
    // v25 -> v26: „durchgeführt"-Haken am Spielergespräch.
    // Nur für DBs mit player_talks-Tabelle (ab v25); bei oldV < 25 kommt die
    // Spalte bereits über _playerTalksTableSql.
    if (oldV < 26 && oldV >= 25) {
      await db.execute(
        'ALTER TABLE player_talks ADD COLUMN done INTEGER NOT NULL DEFAULT 0',
      );
    }
    // v26 -> v27: Spieler in Ereignissen/Kommentaren erwähnen (n:m).
    if (oldV < 27) {
      await db.execute(_eventMentionsTableSql);
    }
    // v27 -> v28: „selbst verwaltet"-Kennzeichen am Spiel (zurückgesetzte/live
    // getrackte Spiele nicht vom FuPa-Import überschreiben).
    if (oldV < 28) {
      await db.execute(
        'ALTER TABLE matches ADD COLUMN locally_managed INTEGER NOT NULL DEFAULT 0',
      );
    }
    // v28 -> v29: Live-Steuerung – wer steuert gerade das Live-Spiel.
    if (oldV < 29) {
      await db.execute('ALTER TABLE matches ADD COLUMN live_controller TEXT');
      await db.execute(
        'ALTER TABLE matches ADD COLUMN live_controller_name TEXT',
      );
    }
    // v29 -> v30: Sponsoren (teamweit, für die Startelf-Grafik).
    if (oldV < 30) {
      await db.execute(_sponsorsTableSql);
    }
    // v30 -> v31: Anpassbare Startelf-Grafik (Titel/Logo/Hintergrund, teamweit).
    if (oldV < 31) {
      await db.execute(_graphicSettingsTableSql);
    }
    // v31 -> v32: optionales Gegner-Logo auf der Startelf-Grafik.
    if (oldV < 32) {
      await db.execute(
        'ALTER TABLE graphic_settings ADD COLUMN show_opponent_logo INTEGER',
      );
    }
    // v32 -> v33: Bewertungen pro Benutzer + Spiel-Gesamtnote/Abwesenheit.
    if (oldV < 33) {
      await db.execute('ALTER TABLE player_ratings ADD COLUMN user_id TEXT');
      await db.execute('DROP INDEX IF EXISTS idx_rating_match_player');
      await db.execute(
        'CREATE UNIQUE INDEX idx_rating_match_player_user ON player_ratings (match_id, player_id, user_id)',
      );
      await db.execute(_matchRatingsTableSql);
      await db.execute(
        'CREATE UNIQUE INDEX idx_match_rating_user ON match_ratings (match_id, user_id)',
      );
    }
    // v33 -> v34: Spieler des Monats (Kürung je Monat).
    if (oldV < 34) {
      await db.execute(_playerOfMonthTableSql);
      await db.execute(
        'CREATE UNIQUE INDEX idx_potm_month ON player_of_month (year_month)',
      );
    }
    // v34 -> v35: Spielerbewertung wieder EINE je Spiel/Spieler (nicht pro
    // Benutzer). Mehrfach-/Alt-Zeilen deduplizieren (jüngste behalten).
    if (oldV < 35) {
      await db.execute('''
        DELETE FROM player_ratings WHERE rowid NOT IN (
          SELECT rowid FROM player_ratings pr WHERE NOT EXISTS (
            SELECT 1 FROM player_ratings p2
            WHERE p2.match_id = pr.match_id AND p2.player_id = pr.player_id
              AND (p2.created_at > pr.created_at
                   OR (p2.created_at = pr.created_at AND p2.rowid > pr.rowid))
          )
        )
      ''');
      await db.execute('DROP INDEX IF EXISTS idx_rating_match_player_user');
      await db.execute(
        'CREATE UNIQUE INDEX idx_rating_match_player ON player_ratings (match_id, player_id)',
      );
    }
    // v35 -> v36: FuPa-Match-Slug am Spiel (Link auf die FuPa-Spielseite).
    if (oldV < 36) {
      await db.execute('ALTER TABLE matches ADD COLUMN fupa_match_slug TEXT');
    }
    // v36 -> v37: Sperren-Zähler am Spieler (noch abzusitzende Spiele).
    if (oldV < 37) {
      await db.execute(
        'ALTER TABLE players ADD COLUMN suspended_games INTEGER NOT NULL DEFAULT 0',
      );
    }
    // v37 -> v38: Spielerbewertung wieder pro Trainer (jeder bewertet eigen-
    // ständig, Schnitt über alle). Unique je (match, player, user). Verwaiste
    // Zeilen ohne Benutzer entfernen, damit sie den Schnitt nicht verfälschen.
    if (oldV < 38) {
      await db.execute(
        "DELETE FROM player_ratings WHERE user_id IS NULL OR user_id = ''",
      );
      await db.execute('DROP INDEX IF EXISTS idx_rating_match_player');
      await db.execute(
        'CREATE UNIQUE INDEX idx_rating_match_player_user ON player_ratings (match_id, player_id, user_id)',
      );
    }
    // v38 -> v39: Sperre je Wettbewerb + Startdatum.
    if (oldV < 39) {
      await db.execute(
        'ALTER TABLE players ADD COLUMN suspension_competition TEXT',
      );
      await db.execute('ALTER TABLE players ADD COLUMN suspension_from TEXT');
    }
    // v39 -> v40: Mehrere Aufstellungen je Spiel (eine je Trainer) + Freigabe.
    if (oldV < 40) {
      await db.execute('ALTER TABLE lineups ADD COLUMN created_by TEXT');
      await db.execute('ALTER TABLE lineups ADD COLUMN creator_name TEXT');
      await db.execute(
        'ALTER TABLE lineups ADD COLUMN released INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute('ALTER TABLE lineups ADD COLUMN suggestion_of TEXT');
      // Bestehende (einzige) Aufstellung je Spiel als freigegeben markieren,
      // damit „Live" weiter funktioniert.
      await db.execute('UPDATE lineups SET released = 1');
      await db.execute('DROP INDEX IF EXISTS idx_lineup_match_team');
      await db.execute(
        'CREATE UNIQUE INDEX idx_lineup_match_team_user ON lineups (match_id, team_id, created_by)',
      );
    }
    // v40 -> v41: Vorschläge (suggestion_of) zulassen – Eindeutigkeit „eine je
    // Trainer" gilt nur für echte Aufstellungen (nicht für Vorschläge).
    if (oldV < 41) {
      await db.execute('DROP INDEX IF EXISTS idx_lineup_match_team_user');
      await db.execute(
        'CREATE UNIQUE INDEX idx_lineup_match_team_user ON lineups (match_id, team_id, created_by) WHERE suggestion_of IS NULL',
      );
    }
    // v41 -> v42: Zwei Fotos je Spieler (FuPa + eigenes) + Auswahl. Bestehendes
    // Foto als „mein Foto" übernehmen (verlustfrei); FuPa-Slot füllt der Import.
    if (oldV < 42) {
      await db.execute('ALTER TABLE players ADD COLUMN photo_fupa TEXT');
      await db.execute('ALTER TABLE players ADD COLUMN photo_custom TEXT');
      await db.execute(
        'ALTER TABLE players ADD COLUMN use_custom_photo INTEGER NOT NULL DEFAULT 1',
      );
      await db.execute(
        'UPDATE players SET photo_custom = photo_path WHERE photo_path IS NOT NULL',
      );
    }
    // v42 -> v43: FuPa-Torwart-Position „Tor" → „Torwart".
    if (oldV < 43) {
      await db.execute(
        "UPDATE players SET position = 'Torwart' WHERE position = 'Tor'",
      );
    }
    // v43 -> v44: Aktivitäten-Feed (team-weit, cloud-synchron).
    if (oldV < 44) {
      await db.execute(_activitiesTableSql);
      await db.execute(
        'CREATE INDEX idx_activities_created ON activities (created_at)',
      );
    }
    // v44 -> v45: Zeitstempel der letzten Bearbeitung einer Spiel-Bewertung/
    // eines Spielberichts (für die Anzeige „geschrieben/bearbeitet am").
    if (oldV < 45) {
      await db.execute('ALTER TABLE match_ratings ADD COLUMN updated_at TEXT');
    }
    // v45 -> v46: persönlicher Posteingang (Benachrichtigungen je Trainer).
    if (oldV < 46) {
      await db.execute(_inboxTableSql);
      await db.execute('CREATE INDEX idx_inbox_created ON inbox (created_at)');
    }
    // v46 -> v47: Grundstatus (Fit/Inaktiv) getrennt vom effektiven Status.
    // Backfill: inaktiv bleibt inaktiv, alles andere wird fit.
    if (oldV < 47) {
      await db.execute(
        "ALTER TABLE players ADD COLUMN base_status TEXT NOT NULL DEFAULT 'fit'",
      );
      await db.execute(
        "UPDATE players SET base_status = 'inaktiv' WHERE status = 'inaktiv'",
      );
    }
    // v47 -> v48: Trainings-Planer (Übungs-Bibliothek + Einheiten).
    if (oldV < 48) {
      await db.execute(_exercisesTableSql);
      await db.execute(_trainingSessionsTableSql);
      await db.execute(_sessionItemsTableSql);
      await db.execute(
        'CREATE INDEX idx_session_items_session ON session_items (session_id)',
      );
    }
    // v48 -> v49: Favoriten/Archiv an Übungen; Archiv an Einheiten.
    if (oldV < 49 && oldV >= 48) {
      await db.execute(
        'ALTER TABLE exercises ADD COLUMN favorite INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute(
        'ALTER TABLE exercises ADD COLUMN archived INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute(
        'ALTER TABLE training_sessions ADD COLUMN archived INTEGER NOT NULL DEFAULT 0',
      );
    }
    // v49 -> v50: Torhüter-Anzahl an der Übung.
    if (oldV < 50 && oldV >= 48) {
      await db.execute('ALTER TABLE exercises ADD COLUMN goalkeepers INTEGER');
    }
    // v50 -> v51: Mehrere benannte Aufstellungen je Spiel. Name + Reihenfolge;
    // die oberste (sort_index minimal) ist die Start-11. „Eine je Trainer"-
    // Unique-Index entfällt.
    if (oldV < 51) {
      await db.execute('ALTER TABLE lineups ADD COLUMN name TEXT');
      await db.execute(
        'ALTER TABLE lineups ADD COLUMN sort_index INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute('DROP INDEX IF EXISTS idx_lineup_match_team_user');
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_lineup_match_team ON lineups (match_id, team_id)',
      );
      // Bestehende Aufstellungen ordnen: freigegebene bzw. ältere zuerst (oben),
      // damit die bisher gültige Aufstellung die Start-11 bleibt.
      final rows = await db.query(
        'lineups',
        columns: ['id', 'match_id', 'team_id', 'released', 'created_at'],
        where: 'suggestion_of IS NULL',
        orderBy: 'match_id, team_id, released DESC, created_at ASC',
      );
      final counter = <String, int>{};
      for (final r in rows) {
        final key = '${r['match_id']}|${r['team_id']}';
        final idx = counter[key] ?? 0;
        counter[key] = idx + 1;
        await db.update(
          'lineups',
          {'sort_index': idx, 'released': idx == 0 ? 1 : 0},
          where: 'id = ?',
          whereArgs: [r['id']],
        );
      }
    }
    // v51 -> v52: zweiter Live-Controller für die Gegner-Erfassung. Wer die
    // eigene Mannschaft/Uhr steuert, erfasst nicht mehr automatisch auch den
    // Gegner – das ist jetzt pro Seite übernehmbar. Laufende Spiele: der
    // bisherige Controller behält beide Seiten.
    if (oldV < 52) {
      await db.execute(
        'ALTER TABLE matches ADD COLUMN live_controller_opp TEXT',
      );
      await db.execute(
        'ALTER TABLE matches ADD COLUMN live_controller_opp_name TEXT',
      );
      await db.execute(
        'UPDATE matches SET live_controller_opp = live_controller, '
        'live_controller_opp_name = live_controller_name '
        'WHERE live_controller IS NOT NULL',
      );
    }
    // v52 -> v53: offene Übernahme-Anfrage am Spiel (Anfrage/Genehmigung statt
    // sofortiger Übernahme der Erfassung).
    if (oldV < 53) {
      await db.execute('ALTER TABLE matches ADD COLUMN live_request_by TEXT');
      await db.execute(
        'ALTER TABLE matches ADD COLUMN live_request_by_name TEXT',
      );
      await db.execute(
        'ALTER TABLE matches ADD COLUMN live_request_scope TEXT',
      );
    }
    // v7 -> v8: Spieler-Notizen, Mannschafts-Termine + Teilnahme.
    if (oldV < 8) {
      await db.execute(_playerNotesTableSql);
      await db.execute(
        'CREATE INDEX idx_notes_player ON player_notes (player_id)',
      );
      await db.execute(_teamEventsTableSql);
      await db.execute('CREATE INDEX idx_events_team ON team_events (team_id)');
      await db.execute(_eventAttendanceTableSql);
      await db.execute(
        'CREATE UNIQUE INDEX idx_att_event_player ON event_attendance (event_id, player_id)',
      );
    }
  }

  // Aktivitäten-Feed: team-weit protokollierte Aktionen (lokal ohne team_id;
  // die Cloud-Zeile bekommt beim Push team_id ergänzt).
  static const _activitiesTableSql = '''
      CREATE TABLE activities (
        id TEXT PRIMARY KEY,
        actor_id TEXT,
        actor_name TEXT,
        type TEXT,
        title TEXT,
        subtitle TEXT,
        created_at TEXT NOT NULL
      )
    ''';

  // Persönlicher Posteingang je Trainer (lokal nur die eigenen Einträge; die
  // Cloud-Zeile bekommt beim Push team_id, der Pull liefert dank RLS nur meine).
  static const _inboxTableSql = '''
      CREATE TABLE inbox (
        id TEXT PRIMARY KEY,
        recipient_id TEXT,
        actor_id TEXT,
        actor_name TEXT,
        type TEXT,
        title TEXT,
        subtitle TEXT,
        link_type TEXT,
        link_id TEXT,
        created_at TEXT NOT NULL,
        read_at TEXT
      )
    ''';

  // Trainings-Planer: Übungs-Bibliothek + geplante Einheiten (lokal ohne
  // team_id; die Cloud-Zeile bekommt beim Push team_id).
  static const _exercisesTableSql = '''
      CREATE TABLE exercises (
        id TEXT PRIMARY KEY,
        title TEXT,
        categories TEXT,
        aufbau TEXT,
        ablauf TEXT,
        coaching_points TEXT,
        varianten TEXT,
        min_players INTEGER,
        needs_goalkeeper INTEGER NOT NULL DEFAULT 0,
        goalkeepers INTEGER,
        duration_min INTEGER,
        material TEXT,
        diagram TEXT,
        video_links TEXT,
        sketch_photo TEXT,
        source TEXT,
        created_by TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        favorite INTEGER NOT NULL DEFAULT 0,
        archived INTEGER NOT NULL DEFAULT 0
      )
    ''';

  static const _trainingSessionsTableSql = '''
      CREATE TABLE training_sessions (
        id TEXT PRIMARY KEY,
        date TEXT NOT NULL,
        field_players INTEGER NOT NULL DEFAULT 0,
        goalkeepers INTEGER NOT NULL DEFAULT 0,
        categories TEXT,
        note TEXT,
        created_at TEXT NOT NULL,
        archived INTEGER NOT NULL DEFAULT 0
      )
    ''';

  static const _sessionItemsTableSql = '''
      CREATE TABLE session_items (
        id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        exercise_id TEXT NOT NULL,
        order_index INTEGER NOT NULL DEFAULT 0,
        duration_min INTEGER,
        note TEXT
      )
    ''';

  static const _playerNotesTableSql = '''
      CREATE TABLE player_notes (
        id TEXT PRIMARY KEY,
        player_id TEXT NOT NULL,
        text TEXT NOT NULL,
        created_at TEXT NOT NULL,
        category_id TEXT,
        match_id TEXT,
        FOREIGN KEY (player_id) REFERENCES players (id) ON DELETE CASCADE
      )
  ''';

  static const _noteCategoriesTableSql = '''
      CREATE TABLE note_categories (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        sort_order INTEGER NOT NULL DEFAULT 0
      )
  ''';

  static const _playerMarkersTableSql = '''
      CREATE TABLE player_markers (
        player_id TEXT NOT NULL,
        marker TEXT NOT NULL,
        PRIMARY KEY (player_id, marker),
        FOREIGN KEY (player_id) REFERENCES players (id) ON DELETE CASCADE
      )
  ''';

  static const _todosTableSql = '''
      CREATE TABLE todos (
        id TEXT PRIMARY KEY,
        text TEXT NOT NULL,
        done INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        due_date TEXT,
        completed_at TEXT,
        archived INTEGER NOT NULL DEFAULT 0,
        topic_id TEXT,
        responsible TEXT
      )
  ''';

  static const _todoTopicsTableSql = '''
      CREATE TABLE todo_topics (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        sort_order INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL
      )
  ''';

  static const _playerTalksTableSql = '''
      CREATE TABLE player_talks (
        id TEXT PRIMARY KEY,
        player_id TEXT NOT NULL,
        title TEXT NOT NULL,
        scheduled_at TEXT NOT NULL,
        notes TEXT,
        done INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        FOREIGN KEY (player_id) REFERENCES players (id) ON DELETE CASCADE
      )
  ''';

  // Erwähnte Spieler in einem Ereignis (v.a. Kommentare): n:m.
  static const _eventMentionsTableSql = '''
      CREATE TABLE event_mentions (
        event_id TEXT NOT NULL,
        player_id TEXT NOT NULL,
        PRIMARY KEY (event_id, player_id),
        FOREIGN KEY (event_id) REFERENCES match_events (id) ON DELETE CASCADE,
        FOREIGN KEY (player_id) REFERENCES players (id) ON DELETE CASCADE
      )
  ''';

  static const _playerAbsencesTableSql = '''
      CREATE TABLE player_absences (
        id TEXT PRIMARY KEY,
        player_id TEXT NOT NULL,
        status TEXT NOT NULL,
        from_date TEXT NOT NULL,
        until_date TEXT NOT NULL,
        note TEXT,
        created_at TEXT NOT NULL,
        FOREIGN KEY (player_id) REFERENCES players (id) ON DELETE CASCADE
      )
  ''';

  static const _teamEventsTableSql = '''
      CREATE TABLE team_events (
        id TEXT PRIMARY KEY,
        team_id TEXT NOT NULL,
        title TEXT NOT NULL,
        type TEXT NOT NULL,
        date TEXT NOT NULL,
        location TEXT,
        note TEXT,
        created_at TEXT NOT NULL,
        FOREIGN KEY (team_id) REFERENCES teams (id) ON DELETE CASCADE
      )
  ''';

  static const _eventAttendanceTableSql = '''
      CREATE TABLE event_attendance (
        id TEXT PRIMARY KEY,
        event_id TEXT NOT NULL,
        player_id TEXT NOT NULL,
        status TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (event_id) REFERENCES team_events (id) ON DELETE CASCADE,
        FOREIGN KEY (player_id) REFERENCES players (id) ON DELETE CASCADE
      )
  ''';

  static const _cardEntriesTableSql = '''
      CREATE TABLE card_entries (
        id TEXT PRIMARY KEY,
        player_id TEXT NOT NULL,
        type TEXT NOT NULL,
        date TEXT NOT NULL,
        match_id TEXT,
        match_event_id TEXT,
        minute INTEGER,
        minute_extra INTEGER NOT NULL DEFAULT 0,
        note TEXT,
        FOREIGN KEY (player_id) REFERENCES players (id) ON DELETE CASCADE
      )
  ''';

  static const _nominationsTableSql = '''
      CREATE TABLE match_nominations (
        id TEXT PRIMARY KEY,
        match_id TEXT NOT NULL,
        player_id TEXT NOT NULL,
        status TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (match_id) REFERENCES matches (id) ON DELETE CASCADE,
        FOREIGN KEY (player_id) REFERENCES players (id) ON DELETE CASCADE
      )
  ''';

  // Sponsoren (teamweit) für die Startelf-Grafik. Logo als Base64-Data-URL.
  // is_main = Haupt-Sponsor („Präsentiert von"). Lokal ohne team_id (Cache hält
  // genau ein Team – wie die übrigen aux-Tabellen).
  static const _sponsorsTableSql = '''
      CREATE TABLE sponsors (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        logo TEXT,
        is_main INTEGER NOT NULL DEFAULT 0,
        sort_order INTEGER NOT NULL DEFAULT 0
      )
  ''';

  // Anpassbare Startelf-Grafik (eine Zeile pro Team; id = Cloud-Team-id, damit
  // die Cloud-PK eindeutig ist). Lokal ohne team_id (Cache = ein Team).
  static const _graphicSettingsTableSql = '''
      CREATE TABLE graphic_settings (
        id TEXT PRIMARY KEY,
        title TEXT,
        logo TEXT,
        bg_image TEXT,
        grad_top TEXT,
        grad_bottom TEXT,
        overlay_opacity INTEGER,
        show_opponent_logo INTEGER
      )
  ''';

  // Spieler des Monats (teamweit, einer je Monat; lokal ohne team_id).
  static const _playerOfMonthTableSql = '''
      CREATE TABLE player_of_month (
        id TEXT PRIMARY KEY,
        year_month TEXT NOT NULL,
        player_id TEXT NOT NULL,
        created_at TEXT NOT NULL
      )
  ''';

  // Spiel-Gesamtnote + Abwesenheit je Benutzer (lokal ohne team_id).
  static const _matchRatingsTableSql = '''
      CREATE TABLE match_ratings (
        id TEXT PRIMARY KEY,
        match_id TEXT NOT NULL,
        user_id TEXT,
        rating REAL,
        abstained INTEGER NOT NULL DEFAULT 0,
        note TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT,
        FOREIGN KEY (match_id) REFERENCES matches (id) ON DELETE CASCADE
      )
  ''';

  static const _playerStatsTableSql = '''
      CREATE TABLE player_stats (
        id TEXT PRIMARY KEY,
        team_id TEXT NOT NULL,
        external_id TEXT,
        first_name TEXT NOT NULL,
        last_name TEXT NOT NULL,
        matches INTEGER NOT NULL DEFAULT 0,
        goals INTEGER NOT NULL DEFAULT 0,
        assists INTEGER NOT NULL DEFAULT 0,
        yellow_cards INTEGER NOT NULL DEFAULT 0,
        yellow_red_cards INTEGER NOT NULL DEFAULT 0,
        red_cards INTEGER NOT NULL DEFAULT 0,
        minutes INTEGER NOT NULL DEFAULT 0,
        top_eleven INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY (team_id) REFERENCES teams (id) ON DELETE CASCADE
      )
  ''';

  Future<void> _createSchema(Database db, int version) async {
    await db.execute('''
      CREATE TABLE teams (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        short_name TEXT,
        fupa_url TEXT,
        fupa_ref TEXT,
        logo_path TEXT,
        is_own_team INTEGER NOT NULL DEFAULT 0,
        source TEXT NOT NULL,
        last_synced_at TEXT,
        created_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE players (
        id TEXT PRIMARY KEY,
        team_id TEXT NOT NULL,
        first_name TEXT NOT NULL,
        last_name TEXT NOT NULL,
        nickname TEXT,
        number INTEGER,
        position TEXT,
        wish_position TEXT,
        status TEXT NOT NULL DEFAULT 'fit',
        base_status TEXT NOT NULL DEFAULT 'fit',
        captain_role TEXT NOT NULL DEFAULT 'none',
        birthdate TEXT,
        positions TEXT,
        is_starter INTEGER NOT NULL DEFAULT 0,
        staff_role TEXT,
        external_id TEXT,
        photo_path TEXT,
        photo_fupa TEXT,
        photo_custom TEXT,
        use_custom_photo INTEGER NOT NULL DEFAULT 1,
        source TEXT NOT NULL,
        active INTEGER NOT NULL DEFAULT 1,
        suspended_games INTEGER NOT NULL DEFAULT 0,
        suspension_competition TEXT,
        suspension_from TEXT,
        created_at TEXT NOT NULL,
        FOREIGN KEY (team_id) REFERENCES teams (id) ON DELETE CASCADE
      )
    ''');
    await db.execute('CREATE INDEX idx_players_team ON players (team_id)');

    await db.execute('''
      CREATE TABLE matches (
        id TEXT PRIMARY KEY,
        own_team_id TEXT NOT NULL,
        opponent_team_id TEXT,
        opponent_name TEXT NOT NULL,
        opponent_fupa_url TEXT,
        opponent_logo_path TEXT,
        kickoff TEXT,
        venue TEXT NOT NULL,
        competition TEXT,
        matchday INTEGER,
        external_id TEXT,
        fupa_match_slug TEXT,
        status TEXT NOT NULL,
        own_score INTEGER NOT NULL DEFAULT 0,
        opponent_score INTEGER NOT NULL DEFAULT 0,
        opponent_imported INTEGER NOT NULL DEFAULT 0,
        locally_managed INTEGER NOT NULL DEFAULT 0,
        live_controller TEXT,
        live_controller_name TEXT,
        live_controller_opp TEXT,
        live_controller_opp_name TEXT,
        live_request_by TEXT,
        live_request_by_name TEXT,
        live_request_scope TEXT,
        created_at TEXT NOT NULL,
        FOREIGN KEY (own_team_id) REFERENCES teams (id) ON DELETE CASCADE,
        FOREIGN KEY (opponent_team_id) REFERENCES teams (id) ON DELETE SET NULL
      )
    ''');
    await db.execute('CREATE INDEX idx_matches_own ON matches (own_team_id)');

    await db.execute('''
      CREATE TABLE lineups (
        id TEXT PRIMARY KEY,
        match_id TEXT NOT NULL,
        team_id TEXT NOT NULL,
        formation TEXT NOT NULL,
        name TEXT,
        sort_index INTEGER NOT NULL DEFAULT 0,
        created_by TEXT,
        creator_name TEXT,
        released INTEGER NOT NULL DEFAULT 0,
        suggestion_of TEXT,
        created_at TEXT NOT NULL,
        FOREIGN KEY (match_id) REFERENCES matches (id) ON DELETE CASCADE,
        FOREIGN KEY (team_id) REFERENCES teams (id) ON DELETE CASCADE
      )
    ''');
    // Mehrere benannte Aufstellungen je Spiel/Team (auch je Trainer) – daher
    // KEIN Unique-Index mehr auf (match_id, team_id, created_by), nur ein
    // normaler Suchindex.
    await db.execute(
      'CREATE INDEX idx_lineup_match_team ON lineups (match_id, team_id)',
    );

    await db.execute('''
      CREATE TABLE lineup_entries (
        id TEXT PRIMARY KEY,
        lineup_id TEXT NOT NULL,
        player_id TEXT NOT NULL,
        role TEXT NOT NULL,
        position_label TEXT,
        order_index INTEGER NOT NULL DEFAULT 0,
        pos_x REAL,
        pos_y REAL,
        FOREIGN KEY (lineup_id) REFERENCES lineups (id) ON DELETE CASCADE,
        FOREIGN KEY (player_id) REFERENCES players (id) ON DELETE CASCADE
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_entries_lineup ON lineup_entries (lineup_id)',
    );

    await db.execute('''
      CREATE TABLE match_events (
        id TEXT PRIMARY KEY,
        match_id TEXT NOT NULL,
        team_id TEXT NOT NULL,
        minute INTEGER NOT NULL,
        minute_extra INTEGER NOT NULL DEFAULT 0,
        type TEXT NOT NULL,
        player_id TEXT,
        assist_player_id TEXT,
        note TEXT,
        created_at TEXT NOT NULL,
        FOREIGN KEY (match_id) REFERENCES matches (id) ON DELETE CASCADE
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_events_match ON match_events (match_id)',
    );

    await db.execute('''
      CREATE TABLE player_ratings (
        id TEXT PRIMARY KEY,
        match_id TEXT NOT NULL,
        player_id TEXT NOT NULL,
        user_id TEXT,
        rating REAL NOT NULL,
        note TEXT,
        created_at TEXT NOT NULL,
        FOREIGN KEY (match_id) REFERENCES matches (id) ON DELETE CASCADE,
        FOREIGN KEY (player_id) REFERENCES players (id) ON DELETE CASCADE
      )
    ''');
    await db.execute(
      'CREATE UNIQUE INDEX idx_rating_match_player_user ON player_ratings (match_id, player_id, user_id)',
    );

    await db.execute(_matchRatingsTableSql);
    await db.execute(
      'CREATE UNIQUE INDEX idx_match_rating_user ON match_ratings (match_id, user_id)',
    );

    await db.execute(_playerOfMonthTableSql);
    await db.execute(
      'CREATE UNIQUE INDEX idx_potm_month ON player_of_month (year_month)',
    );

    await db.execute(_playerStatsTableSql);
    await db.execute('CREATE INDEX idx_stats_team ON player_stats (team_id)');

    await db.execute(_nominationsTableSql);
    await db.execute(
      'CREATE UNIQUE INDEX idx_nom_match_player ON match_nominations (match_id, player_id)',
    );

    await db.execute(_cardEntriesTableSql);
    await db.execute(
      'CREATE INDEX idx_cards_player ON card_entries (player_id)',
    );

    await db.execute(_playerNotesTableSql);
    await db.execute(
      'CREATE INDEX idx_notes_player ON player_notes (player_id)',
    );
    await db.execute(_noteCategoriesTableSql);
    await db.execute(_playerMarkersTableSql);
    await db.execute(_todosTableSql);
    await db.execute(_todoTopicsTableSql);
    await db.execute(_playerTalksTableSql);
    await db.execute(_sponsorsTableSql);
    await db.execute(_graphicSettingsTableSql);
    await db.execute(_eventMentionsTableSql);
    await db.execute(_playerAbsencesTableSql);
    await db.execute(
      'CREATE INDEX idx_absences_player ON player_absences (player_id)',
    );
    await db.execute(_teamEventsTableSql);
    await db.execute('CREATE INDEX idx_events_team ON team_events (team_id)');
    await db.execute(_eventAttendanceTableSql);
    await db.execute(
      'CREATE UNIQUE INDEX idx_att_event_player ON event_attendance (event_id, player_id)',
    );
    await db.execute(_activitiesTableSql);
    await db.execute(
      'CREATE INDEX idx_activities_created ON activities (created_at)',
    );
    await db.execute(_inboxTableSql);
    await db.execute('CREATE INDEX idx_inbox_created ON inbox (created_at)');
    await db.execute(_exercisesTableSql);
    await db.execute(_trainingSessionsTableSql);
    await db.execute(_sessionItemsTableSql);
    await db.execute(
      'CREATE INDEX idx_session_items_session ON session_items (session_id)',
    );

    await db.execute('''
      CREATE TABLE settings (
        key TEXT PRIMARY KEY,
        value TEXT
      )
    ''');
  }

  /// Schließt die DB (v.a. für Tests).
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
