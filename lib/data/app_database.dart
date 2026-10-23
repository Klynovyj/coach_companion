import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Zentraler Datenbank-Zugang. SQLite läuft auf Mobile nativ und auf
/// Windows/Desktop über die FFI-Implementierung.
class AppDatabase {
  AppDatabase._()
      : _inMemory = false,
        _customPath = null;

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
  static const _dbVersion = 17;

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

    final path = _customPath ??
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
      await db.execute('ALTER TABLE matches ADD COLUMN opponent_logo_path TEXT');
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
          'CREATE UNIQUE INDEX idx_nom_match_player ON match_nominations (match_id, player_id)');
    }
    // v6 -> v7: Karten je Spieler.
    if (oldV < 7) {
      await db.execute(_cardEntriesTableSql);
      await db.execute('CREATE INDEX idx_cards_player ON card_entries (player_id)');
    }
    // v8 -> v9: Nachspielzeit am Live-Ereignis.
    if (oldV < 9) {
      await db.execute(
          'ALTER TABLE match_events ADD COLUMN minute_extra INTEGER NOT NULL DEFAULT 0');
    }
    // v9 -> v10: freie Positionen in der Aufstellung.
    if (oldV < 10) {
      await db.execute('ALTER TABLE lineup_entries ADD COLUMN pos_x REAL');
      await db.execute('ALTER TABLE lineup_entries ADD COLUMN pos_y REAL');
    }
    // v10 -> v11: Nachspielzeit an der Karte.
    if (oldV < 11) {
      await db.execute(
          'ALTER TABLE card_entries ADD COLUMN minute_extra INTEGER NOT NULL DEFAULT 0');
    }
    // v11 -> v12: Spieler-Status, Kapitäns-Rolle, Wunschposition.
    if (oldV < 12) {
      await db.execute(
          "ALTER TABLE players ADD COLUMN status TEXT NOT NULL DEFAULT 'fit'");
      await db.execute(
          "ALTER TABLE players ADD COLUMN captain_role TEXT NOT NULL DEFAULT 'none'");
      await db.execute('ALTER TABLE players ADD COLUMN wish_position TEXT');
    }
    // v12 -> v13: Notiz-Rubriken (zentral) + Rubrik an der Notiz.
    if (oldV < 13) {
      await db.execute(_noteCategoriesTableSql);
      // Notizen vor < v8 bekommen die Spalte bereits beim Anlegen der Tabelle
      // im v8-Block; ältere Bestände (v8..v12) brauchen das ALTER.
      if (oldV >= 8) {
        await db.execute('ALTER TABLE player_notes ADD COLUMN category_id TEXT');
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
          'CREATE INDEX idx_absences_player ON player_absences (player_id)');
    }
    // v16 -> v17: Fälligkeit, Erledigt-Zeitpunkt und Archiv an To-Dos.
    // Nur für Bestände, deren todos-Tabelle ohne diese Spalten angelegt wurde
    // (v15/v16). Ältere Bestände (< v15) bekommen die Tabelle im v15-Block
    // bereits mit den neuen Spalten über _todosTableSql.
    if (oldV < 17 && oldV >= 15) {
      await db.execute('ALTER TABLE todos ADD COLUMN due_date TEXT');
      await db.execute('ALTER TABLE todos ADD COLUMN completed_at TEXT');
      await db.execute(
          'ALTER TABLE todos ADD COLUMN archived INTEGER NOT NULL DEFAULT 0');
    }
    // v7 -> v8: Spieler-Notizen, Mannschafts-Termine + Teilnahme.
    if (oldV < 8) {
      await db.execute(_playerNotesTableSql);
      await db.execute('CREATE INDEX idx_notes_player ON player_notes (player_id)');
      await db.execute(_teamEventsTableSql);
      await db.execute('CREATE INDEX idx_events_team ON team_events (team_id)');
      await db.execute(_eventAttendanceTableSql);
      await db.execute(
          'CREATE UNIQUE INDEX idx_att_event_player ON event_attendance (event_id, player_id)');
    }
  }

  static const _playerNotesTableSql = '''
      CREATE TABLE player_notes (
        id TEXT PRIMARY KEY,
        player_id TEXT NOT NULL,
        text TEXT NOT NULL,
        created_at TEXT NOT NULL,
        category_id TEXT,
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
        archived INTEGER NOT NULL DEFAULT 0
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
        number INTEGER,
        position TEXT,
        wish_position TEXT,
        status TEXT NOT NULL DEFAULT 'fit',
        captain_role TEXT NOT NULL DEFAULT 'none',
        external_id TEXT,
        photo_path TEXT,
        source TEXT NOT NULL,
        active INTEGER NOT NULL DEFAULT 1,
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
        external_id TEXT,
        status TEXT NOT NULL,
        own_score INTEGER NOT NULL DEFAULT 0,
        opponent_score INTEGER NOT NULL DEFAULT 0,
        opponent_imported INTEGER NOT NULL DEFAULT 0,
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
        created_at TEXT NOT NULL,
        FOREIGN KEY (match_id) REFERENCES matches (id) ON DELETE CASCADE,
        FOREIGN KEY (team_id) REFERENCES teams (id) ON DELETE CASCADE
      )
    ''');
    await db.execute(
        'CREATE UNIQUE INDEX idx_lineup_match_team ON lineups (match_id, team_id)');

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
        'CREATE INDEX idx_entries_lineup ON lineup_entries (lineup_id)');

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
        'CREATE INDEX idx_events_match ON match_events (match_id)');

    await db.execute('''
      CREATE TABLE player_ratings (
        id TEXT PRIMARY KEY,
        match_id TEXT NOT NULL,
        player_id TEXT NOT NULL,
        rating REAL NOT NULL,
        note TEXT,
        created_at TEXT NOT NULL,
        FOREIGN KEY (match_id) REFERENCES matches (id) ON DELETE CASCADE,
        FOREIGN KEY (player_id) REFERENCES players (id) ON DELETE CASCADE
      )
    ''');
    await db.execute(
        'CREATE UNIQUE INDEX idx_rating_match_player ON player_ratings (match_id, player_id)');

    await db.execute(_playerStatsTableSql);
    await db.execute(
        'CREATE INDEX idx_stats_team ON player_stats (team_id)');

    await db.execute(_nominationsTableSql);
    await db.execute(
        'CREATE UNIQUE INDEX idx_nom_match_player ON match_nominations (match_id, player_id)');

    await db.execute(_cardEntriesTableSql);
    await db.execute('CREATE INDEX idx_cards_player ON card_entries (player_id)');

    await db.execute(_playerNotesTableSql);
    await db.execute('CREATE INDEX idx_notes_player ON player_notes (player_id)');
    await db.execute(_noteCategoriesTableSql);
    await db.execute(_playerMarkersTableSql);
    await db.execute(_todosTableSql);
    await db.execute(_playerAbsencesTableSql);
    await db.execute(
        'CREATE INDEX idx_absences_player ON player_absences (player_id)');
    await db.execute(_teamEventsTableSql);
    await db.execute('CREATE INDEX idx_events_team ON team_events (team_id)');
    await db.execute(_eventAttendanceTableSql);
    await db.execute(
        'CREATE UNIQUE INDEX idx_att_event_player ON event_attendance (event_id, player_id)');

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
