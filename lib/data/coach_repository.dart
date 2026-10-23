import 'package:sqflite/sqflite.dart';

import '../models/card_entry.dart';
import '../models/enums.dart';
import '../models/lineup.dart';
import '../models/match.dart';
import '../models/match_event.dart';
import '../models/nomination.dart';
import '../models/player.dart';
import '../models/player_note.dart';
import '../models/player_rating.dart';
import '../models/player_stat.dart';
import '../models/team.dart';
import '../models/team_event.dart';
import 'app_database.dart';

/// Einziger Zugang zur Persistenz. Gruppiert nach Entität; jede Entität
/// hat ihr eigenes Datenmodell und ihre eigene Tabelle.
class CoachRepository {
  CoachRepository({AppDatabase? db}) : _appDb = db ?? AppDatabase.instance;

  final AppDatabase _appDb;

  Future<Database> get _db async => _appDb.database;

  /// Echtes Upsert per Primärschlüssel OHNE Löschen: erst UPDATE, sonst INSERT.
  ///
  /// Wichtig für Eltern-Tabellen (teams/players/matches/lineups/team_events):
  /// `ConflictAlgorithm.replace` würde die Zeile löschen und neu einfügen und
  /// dabei via `ON DELETE CASCADE` alle Kinddaten (Events, Nominierungen,
  /// Karten, Notizen, Aufstellungen …) mitlöschen.
  Future<void> _upsertById(String table, Map<String, Object?> map) async {
    final db = await _db;
    final updated = await db
        .update(table, map, where: 'id = ?', whereArgs: [map['id']]);
    if (updated == 0) {
      await db.insert(table, map);
    }
  }

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

  Future<void> upsertTeam(Team team) => _upsertById('teams', team.toMap());

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

  Future<void> upsertPlayer(Player player) =>
      _upsertById('players', player.toMap());

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

  Future<void> upsertMatch(GameMatch match) =>
      _upsertById('matches', match.toMap());

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

  Future<void> upsertLineup(Lineup lineup) =>
      _upsertById('lineups', lineup.toMap());

  /// Löscht die Aufstellung eines Teams für ein Spiel (inkl. Einträge).
  Future<void> deleteLineup(String matchId, String teamId) async {
    final db = await _db;
    await db.delete('lineups',
        where: 'match_id = ? AND team_id = ?', whereArgs: [matchId, teamId]);
  }

  /// Löscht alle Nominierungen eines Spiels.
  Future<void> deleteNominationsForMatch(String matchId) async {
    final db = await _db;
    await db.delete('match_nominations',
        where: 'match_id = ?', whereArgs: [matchId]);
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

  /// Löscht alle Ereignisse eines Spiels und die daran verknüpften Karten.
  Future<void> resetMatchEvents(String matchId) async {
    final db = await _db;
    await db.transaction((txn) async {
      await txn.rawDelete(
        'DELETE FROM card_entries WHERE match_event_id IN '
        '(SELECT id FROM match_events WHERE match_id = ?)',
        [matchId],
      );
      await txn
          .delete('match_events', where: 'match_id = ?', whereArgs: [matchId]);
    });
  }

  /// Alle Spiel-Ereignisse eines Spielers (als Schütze oder Vorlagengeber),
  /// über alle Spiele hinweg.
  Future<List<MatchEvent>> getPlayerMatchEvents(String playerId) async {
    final db = await _db;
    final rows = await db.query('match_events',
        where: 'player_id = ? OR assist_player_id = ?',
        whereArgs: [playerId, playerId],
        orderBy: 'created_at DESC');
    return rows.map(MatchEvent.fromMap).toList();
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

  // ------------------------------------------------------------ Player stats
  Future<List<PlayerStat>> getStats(String teamId) async {
    final db = await _db;
    final rows = await db.query('player_stats',
        where: 'team_id = ?', whereArgs: [teamId]);
    return rows.map(PlayerStat.fromMap).toList();
  }

  /// Ersetzt die Statistik eines Teams atomar (ein Import = ein Stand).
  Future<void> replaceStats(String teamId, List<PlayerStat> stats) async {
    final db = await _db;
    await db.transaction((txn) async {
      await txn
          .delete('player_stats', where: 'team_id = ?', whereArgs: [teamId]);
      for (final s in stats) {
        await txn.insert('player_stats', s.toMap());
      }
    });
  }

  // ------------------------------------------------------------- Nominations
  Future<List<Nomination>> getNominations(String matchId) async {
    final db = await _db;
    final rows = await db.query('match_nominations',
        where: 'match_id = ?', whereArgs: [matchId]);
    return rows.map(Nomination.fromMap).toList();
  }

  Future<void> upsertNomination(Nomination nomination) async {
    final db = await _db;
    await db.insert('match_nominations', nomination.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteNomination(String matchId, String playerId) async {
    final db = await _db;
    await db.delete('match_nominations',
        where: 'match_id = ? AND player_id = ?', whereArgs: [matchId, playerId]);
  }

  // ------------------------------------------------------------------- Cards
  Future<List<CardEntry>> getCards(String playerId) async {
    final db = await _db;
    final rows = await db.query('card_entries',
        where: 'player_id = ?', whereArgs: [playerId], orderBy: 'date DESC');
    return rows.map(CardEntry.fromMap).toList();
  }

  Future<void> upsertCard(CardEntry card) async {
    final db = await _db;
    await db.insert('card_entries', card.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteCard(String id) async {
    final db = await _db;
    await db.delete('card_entries', where: 'id = ?', whereArgs: [id]);
  }

  /// Löscht die zu einem Live-Ereignis gehörende Karte (falls vorhanden).
  Future<void> deleteCardByEvent(String matchEventId) async {
    final db = await _db;
    await db.delete('card_entries',
        where: 'match_event_id = ?', whereArgs: [matchEventId]);
  }

  /// Kartenzahl je Spieler eines Teams, als Map playerId -> {type: count}.
  Future<Map<String, Map<CardType, int>>> cardCountsForTeam(
      String teamId) async {
    final db = await _db;
    final rows = await db.rawQuery(
      'SELECT c.player_id AS pid, c.type AS type, COUNT(*) AS c '
      'FROM card_entries c JOIN players p ON p.id = c.player_id '
      'WHERE p.team_id = ? GROUP BY c.player_id, c.type',
      [teamId],
    );
    final out = <String, Map<CardType, int>>{};
    for (final r in rows) {
      final pid = r['pid'] as String;
      final type = CardType.fromKey(r['type'] as String?);
      out.putIfAbsent(pid, () => {})[type] = r['c'] as int;
    }
    return out;
  }

  // ------------------------------------------------------------- Player notes
  Future<List<PlayerNote>> getNotes(String playerId) async {
    final db = await _db;
    final rows = await db.query('player_notes',
        where: 'player_id = ?', whereArgs: [playerId], orderBy: 'created_at DESC');
    return rows.map(PlayerNote.fromMap).toList();
  }

  Future<void> upsertNote(PlayerNote note) async {
    final db = await _db;
    await db.insert('player_notes', note.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteNote(String id) async {
    final db = await _db;
    await db.delete('player_notes', where: 'id = ?', whereArgs: [id]);
  }

  // ------------------------------------------------------------- Team events
  Future<List<TeamEvent>> getTeamEvents(String teamId) async {
    final db = await _db;
    final rows = await db.query('team_events',
        where: 'team_id = ?', whereArgs: [teamId], orderBy: 'date ASC');
    return rows.map(TeamEvent.fromMap).toList();
  }

  Future<TeamEvent?> getTeamEvent(String id) async {
    final db = await _db;
    final rows = await db
        .query('team_events', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : TeamEvent.fromMap(rows.first);
  }

  Future<void> upsertTeamEvent(TeamEvent event) =>
      _upsertById('team_events', event.toMap());

  Future<void> deleteTeamEvent(String id) async {
    final db = await _db;
    await db.delete('team_events', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<EventAttendance>> getEventAttendance(String eventId) async {
    final db = await _db;
    final rows = await db.query('event_attendance',
        where: 'event_id = ?', whereArgs: [eventId]);
    return rows.map(EventAttendance.fromMap).toList();
  }

  Future<void> upsertEventAttendance(EventAttendance a) async {
    final db = await _db;
    await db.insert('event_attendance', a.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteEventAttendance(String eventId, String playerId) async {
    final db = await _db;
    await db.delete('event_attendance',
        where: 'event_id = ? AND player_id = ?', whereArgs: [eventId, playerId]);
  }
}
