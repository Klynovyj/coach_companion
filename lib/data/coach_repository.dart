import 'package:sqflite/sqflite.dart';

import '../models/enums.dart';
import '../models/lineup.dart';
import '../models/match.dart';
import '../models/match_event.dart';
import '../models/player.dart';
import '../models/player_rating.dart';
import '../models/team.dart';
import 'app_database.dart';

/// Einziger Zugang zur Persistenz. Gruppiert nach Entität; jede Entität
/// hat ihr eigenes Datenmodell und ihre eigene Tabelle.
class CoachRepository {
  CoachRepository({AppDatabase? db}) : _appDb = db ?? AppDatabase.instance;

  final AppDatabase _appDb;

  Future<Database> get _db async => _appDb.database;

  // ---------------------------------------------------------------- Settings
  Future<String?> getSetting(String key) async {
    final db = await _db;
    final rows = await db.query('settings',
        where: 'key = ?', whereArgs: [key], limit: 1);
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  Future<void> setSetting(String key, String? value) async {
    final db = await _db;
    await db.insert('settings', {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ------------------------------------------------------------------- Teams
  Future<List<Team>> getTeams() async {
    final db = await _db;
    final rows = await db.query('teams', orderBy: 'is_own_team DESC, name ASC');
    return rows.map(Team.fromMap).toList();
  }

  Future<Team?> getTeam(String id) async {
    final db = await _db;
    final rows =
        await db.query('teams', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Team.fromMap(rows.first);
  }

  Future<Team?> getOwnTeam() async {
    final db = await _db;
    final rows = await db.query('teams',
        where: 'is_own_team = 1', orderBy: 'created_at ASC', limit: 1);
    return rows.isEmpty ? null : Team.fromMap(rows.first);
  }

  /// Findet einen Gegner anhand von FuPa-Ref oder normalisiertem Namen.
  Future<Team?> findOpponentTeam({String? fupaRef, String? name}) async {
    final db = await _db;
    if (fupaRef != null && fupaRef.isNotEmpty) {
      final rows = await db.query('teams',
          where: 'is_own_team = 0 AND fupa_ref = ?',
          whereArgs: [fupaRef],
          limit: 1);
      if (rows.isNotEmpty) return Team.fromMap(rows.first);
    }
    if (name != null && name.trim().isNotEmpty) {
      final rows = await db.query('teams',
          where: 'is_own_team = 0 AND LOWER(name) = ?',
          whereArgs: [name.trim().toLowerCase()],
          limit: 1);
      if (rows.isNotEmpty) return Team.fromMap(rows.first);
    }
    return null;
  }

  Future<void> upsertTeam(Team team) async {
    final db = await _db;
    await db.insert('teams', team.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteTeam(String id) async {
    final db = await _db;
    await db.delete('teams', where: 'id = ?', whereArgs: [id]);
  }

  // ----------------------------------------------------------------- Players
  Future<List<Player>> getPlayers(String teamId,
      {bool onlyActive = false}) async {
    final db = await _db;
    final rows = await db.query(
      'players',
      where: onlyActive ? 'team_id = ? AND active = 1' : 'team_id = ?',
      whereArgs: [teamId],
      orderBy: 'number IS NULL, number ASC, last_name ASC',
    );
    return rows.map(Player.fromMap).toList();
  }

  Future<Player?> getPlayer(String id) async {
    final db = await _db;
    final rows =
        await db.query('players', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Player.fromMap(rows.first);
  }

  Future<void> upsertPlayer(Player player) async {
    final db = await _db;
    await db.insert('players', player.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deletePlayer(String id) async {
    final db = await _db;
    await db.delete('players', where: 'id = ?', whereArgs: [id]);
  }

  // ----------------------------------------------------------------- Matches
  Future<List<GameMatch>> getMatches(String ownTeamId) async {
    final db = await _db;
    final rows = await db.query('matches',
        where: 'own_team_id = ?',
        whereArgs: [ownTeamId],
        orderBy: 'kickoff IS NULL, kickoff ASC');
    return rows.map(GameMatch.fromMap).toList();
  }

  Future<GameMatch?> getMatch(String id) async {
    final db = await _db;
    final rows =
        await db.query('matches', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : GameMatch.fromMap(rows.first);
  }

  Future<void> upsertMatch(GameMatch match) async {
    final db = await _db;
    await db.insert('matches', match.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteMatch(String id) async {
    final db = await _db;
    await db.delete('matches', where: 'id = ?', whereArgs: [id]);
  }

  // ----------------------------------------------------------------- Lineups
  Future<Lineup?> getLineup(String matchId, String teamId) async {
    final db = await _db;
    final rows = await db.query('lineups',
        where: 'match_id = ? AND team_id = ?',
        whereArgs: [matchId, teamId],
        limit: 1);
    return rows.isEmpty ? null : Lineup.fromMap(rows.first);
  }

  Future<void> upsertLineup(Lineup lineup) async {
    final db = await _db;
    await db.insert('lineups', lineup.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<LineupEntry>> getLineupEntries(String lineupId) async {
    final db = await _db;
    final rows = await db.query('lineup_entries',
        where: 'lineup_id = ?',
        whereArgs: [lineupId],
        orderBy: 'order_index ASC');
    return rows.map(LineupEntry.fromMap).toList();
  }

  /// Ersetzt sämtliche Einträge einer Aufstellung atomar.
  Future<void> replaceLineupEntries(
      String lineupId, List<LineupEntry> entries) async {
    final db = await _db;
    await db.transaction((txn) async {
      await txn
          .delete('lineup_entries', where: 'lineup_id = ?', whereArgs: [lineupId]);
      for (final e in entries) {
        await txn.insert('lineup_entries', e.toMap());
      }
    });
  }

  // ------------------------------------------------------------------ Events
  Future<List<MatchEvent>> getEvents(String matchId) async {
    final db = await _db;
    final rows = await db.query('match_events',
        where: 'match_id = ?',
        whereArgs: [matchId],
        orderBy: 'minute ASC, created_at ASC');
    return rows.map(MatchEvent.fromMap).toList();
  }

  Future<void> upsertEvent(MatchEvent event) async {
    final db = await _db;
    await db.insert('match_events', event.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteEvent(String id) async {
    final db = await _db;
    await db.delete('match_events', where: 'id = ?', whereArgs: [id]);
  }

  /// Zählt die Tore je Team für ein Spiel (Grundlage des Spielstands).
  Future<Map<String, int>> goalCountByTeam(String matchId) async {
    final db = await _db;
    final rows = await db.rawQuery(
      'SELECT team_id, COUNT(*) AS c FROM match_events '
      'WHERE match_id = ? AND type = ? GROUP BY team_id',
      [matchId, MatchEventType.goal.storageKey],
    );
    return {for (final r in rows) r['team_id'] as String: r['c'] as int};
  }

  // ----------------------------------------------------------------- Ratings
  Future<List<PlayerRating>> getRatings(String matchId) async {
    final db = await _db;
    final rows = await db
        .query('player_ratings', where: 'match_id = ?', whereArgs: [matchId]);
    return rows.map(PlayerRating.fromMap).toList();
  }

  Future<void> upsertRating(PlayerRating rating) async {
    final db = await _db;
    await db.insert('player_ratings', rating.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteRating(String id) async {
    final db = await _db;
    await db.delete('player_ratings', where: 'id = ?', whereArgs: [id]);
  }
}
