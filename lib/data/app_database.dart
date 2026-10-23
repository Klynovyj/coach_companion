import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Zentraler Datenbank-Zugang. SQLite läuft auf Mobile nativ und auf
/// Windows/Desktop über die FFI-Implementierung.
class AppDatabase {
  AppDatabase._();
  static final AppDatabase instance = AppDatabase._();

  Database? _db;

  static const _dbName = 'coach_companion.db';
  static const _dbVersion = 1;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _open();
    return _db!;
  }

  Future<Database> _open() async {
    // Desktop (Windows/Linux/macOS) benötigt die FFI-Factory.
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, _dbName);

    return databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: _dbVersion,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: _createSchema,
      ),
    );
  }

  Future<void> _createSchema(Database db, int version) async {
    await db.execute('''
      CREATE TABLE teams (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        short_name TEXT,
        fupa_url TEXT,
        fupa_ref TEXT,
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
        external_id TEXT,
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
