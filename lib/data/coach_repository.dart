import 'package:sqflite/sqflite.dart';

import '../models/card_entry.dart';
import '../models/enums.dart';
import '../models/lineup.dart';
import '../models/match.dart';
import '../models/match_event.dart';
import '../models/nomination.dart';
import '../models/player.dart';
import '../models/note_category.dart';
import '../models/player_absence.dart';
import '../models/player_note.dart';
import '../models/player_rating.dart';
import '../models/player_stat.dart';
import '../models/team.dart';
import '../models/team_event.dart';
import '../models/player_talk.dart';
import '../models/todo.dart';
import '../models/todo_topic.dart';
import 'app_database.dart';

/// Spiegel-Haken: wird nach jeder team-relevanten Schreiboperation gerufen,
/// damit AppState die Zeile in die Cloud spiegeln kann. Genau einer von
/// [upsertRow]/[deleteFilter] ist gesetzt: [upsertRow] = volle Spalten-Map
/// (Insert/Update), [deleteFilter] = Spalten-Filter der Löschung.
typedef CloudSyncHook = void Function(
  String table,
  Map<String, Object?>? upsertRow,
  Map<String, Object?>? deleteFilter,
);

/// Einziger Zugang zur Persistenz. Gruppiert nach Entität; jede Entität
/// hat ihr eigenes Datenmodell und ihre eigene Tabelle.
class CoachRepository {
  CoachRepository({AppDatabase? db}) : _appDb = db ?? AppDatabase.instance;

  final AppDatabase _appDb;

  Future<Database> get _db async => _appDb.database;

  /// Von AppState gesetzt; spiegelt Schreibzugriffe in die Cloud. Lesevorgänge
  /// und die Pull-Helfer ([insertRawForPull]/[upsertRawById]) lösen ihn NICHT
  /// aus, damit aus der Cloud geladene Daten nicht zurückgespiegelt werden.
  CloudSyncHook? onCloudSync;

  void _syncUpsert(String table, Map<String, Object?> row) =>
      onCloudSync?.call(table, row, null);
  void _syncDelete(String table, Map<String, Object?> filter) =>
      onCloudSync?.call(table, null, filter);

  /// Fügt eine aus der Cloud geladene Zeile direkt ein (ersetzend, OHNE
  /// Sync-Haken). Nur für den vollständigen Pull/Download nach einem Wipe –
  /// `replace` würde bei Eltern-Tabellen Kinddaten per CASCADE löschen.
  Future<void> insertRawForPull(String table, Map<String, Object?> map) async {
    final db = await _db;
    await db.insert(table, map, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Update-oder-Insert per id OHNE Sync-Haken und OHNE Kaskaden-Löschung
  /// (für den inkrementellen Realtime-Abgleich bestehender Daten).
  Future<void> upsertRawById(String table, Map<String, Object?> map) async {
    final db = await _db;
    final updated =
        await db.update(table, map, where: 'id = ?', whereArgs: [map['id']]);
    if (updated == 0) await db.insert(table, map);
  }

  /// Löscht eine Zeile per id (generisch, ohne Sync-Haken) – für den per-Zeile-
  /// Realtime-Abgleich (DELETE eines anderen Geräts übernehmen).
  Future<void> deleteByIdRaw(String table, String id) async {
    final db = await _db;
    await db.delete(table, where: 'id = ?', whereArgs: [id]);
  }

  /// Löscht lokale Zeilen, deren id NICHT in [keepIds] steht (für den Realtime-
  /// Abgleich: in der Cloud gelöschte Datensätze auch lokal entfernen). Der
  /// lokale Cache hält genau ein Team, daher team-weit sicher.
  Future<void> deleteRowsNotIn(String table, List<String> keepIds) async {
    final db = await _db;
    if (keepIds.isEmpty) {
      await db.delete(table);
      return;
    }
    final ph = List.filled(keepIds.length, '?').join(',');
    await db.delete(table, where: 'id NOT IN ($ph)', whereArgs: keepIds);
  }

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
    _syncUpsert(table, map);
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

  /// Leert alle lokalen Teamdaten (Teams → Spieler/Spiele/… via CASCADE).
  /// Für den cloud-first-Cache: lokales Abbild eines Cloud-Teams neu aufbauen.
  Future<void> wipeTeams() async {
    final db = await _db;
    await db.delete('teams');
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
    // Gibt es (durch Sync verschiedener Geräte) mehrere Aufstellungen für dies
    // Spiel/Team, die mit den MEISTEN Einträgen bevorzugen – sonst würde eine
    // leere lokale Zeile die übernommene (volle) Aufstellung verdecken.
    final rows = await db.rawQuery('''
      SELECT l.* FROM lineups l
      LEFT JOIN (
        SELECT lineup_id, COUNT(*) AS c FROM lineup_entries GROUP BY lineup_id
      ) e ON e.lineup_id = l.id
      WHERE l.match_id = ? AND l.team_id = ?
      ORDER BY COALESCE(e.c, 0) DESC, l.created_at ASC
      LIMIT 1
    ''', [matchId, teamId]);
    return rows.isEmpty ? null : Lineup.fromMap(rows.first);
  }

  Future<void> upsertLineup(Lineup lineup) =>
      _upsertById('lineups', lineup.toMap());

  /// Löscht die Aufstellung eines Teams für ein Spiel (inkl. Einträge).
  Future<void> deleteLineup(String matchId, String teamId) async {
    final db = await _db;
    await db.delete('lineups',
        where: 'match_id = ? AND team_id = ?', whereArgs: [matchId, teamId]);
    _syncDelete('lineups', {'match_id': matchId, 'team_id': teamId});
  }

  /// Löscht alle Nominierungen eines Spiels.
  Future<void> deleteNominationsForMatch(String matchId) async {
    final db = await _db;
    await db.delete('match_nominations',
        where: 'match_id = ?', whereArgs: [matchId]);
    _syncDelete('match_nominations', {'match_id': matchId});
  }

  Future<List<LineupEntry>> getLineupEntries(String lineupId) async {
    final db = await _db;
    final rows = await db.query('lineup_entries',
        where: 'lineup_id = ?',
        whereArgs: [lineupId],
        orderBy: 'order_index ASC');
    return rows.map(LineupEntry.fromMap).toList();
  }

  /// Ersetzt die Einträge einer Aufstellung. Lokal atomar; der Cloud-Spiegel
  /// löscht NUR tatsächlich entfernte Einträge gezielt (statt Bulk-Delete nach
  /// lineup_id) und upsertet die aktuellen. So kann eine nachlaufende DELETE-
  /// Anfrage nicht die frisch eingefügten Einträge wieder entfernen (Race →
  /// leere Aufstellung bei allen); die Ziele der Deletes/Upserts sind disjunkt.
  Future<void> replaceLineupEntries(
      String lineupId, List<LineupEntry> entries) async {
    final db = await _db;
    final old = await getLineupEntries(lineupId);
    final keep = {for (final e in entries) e.id};
    final removed = [for (final e in old) if (!keep.contains(e.id)) e.id];
    await db.transaction((txn) async {
      for (final id in removed) {
        await txn.delete('lineup_entries', where: 'id = ?', whereArgs: [id]);
      }
      for (final e in entries) {
        await txn.insert('lineup_entries', e.toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
    for (final id in removed) {
      _syncDelete('lineup_entries', {'id': id});
    }
    for (final e in entries) {
      _syncUpsert('lineup_entries', e.toMap());
    }
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

  /// Erwähnte Spieler eines Ereignisses setzen (ersetzt vorhandene).
  Future<void> setEventMentions(
      String eventId, List<String> playerIds) async {
    final db = await _db;
    final unique = playerIds.toSet();
    await db.transaction((txn) async {
      await txn.delete('event_mentions',
          where: 'event_id = ?', whereArgs: [eventId]);
      for (final pid in unique) {
        await txn.insert('event_mentions',
            {'event_id': eventId, 'player_id': pid},
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    });
    _syncDelete('event_mentions', {'event_id': eventId});
    for (final pid in unique) {
      _syncUpsert('event_mentions', {'event_id': eventId, 'player_id': pid});
    }
  }

  /// Kommentare, in denen der Spieler erwähnt wurde.
  Future<List<MatchEvent>> getMentionComments(String playerId) async {
    final db = await _db;
    final rows = await db.rawQuery(
      'SELECT e.* FROM match_events e '
      'JOIN event_mentions m ON m.event_id = e.id '
      'WHERE m.player_id = ? AND e.type = ? '
      'ORDER BY e.created_at DESC',
      [playerId, MatchEventType.comment.storageKey],
    );
    return rows.map(MatchEvent.fromMap).toList();
  }

  /// Zählt die Tore je Team für ein Spiel (Grundlage des Spielstands).
  Future<Map<String, int>> goalCountByTeam(String matchId) async {
    final db = await _db;
    // Tore und verwandelte Elfmeter zählen für den Spielstand.
    final rows = await db.rawQuery(
      'SELECT team_id, COUNT(*) AS c FROM match_events '
      'WHERE match_id = ? AND type IN (?, ?) GROUP BY team_id',
      [
        matchId,
        MatchEventType.goal.storageKey,
        MatchEventType.penalty.storageKey,
      ],
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
    _syncUpsert('player_ratings', rating.toMap());
  }

  Future<void> deleteRating(String id) async {
    final db = await _db;
    await db.delete('player_ratings', where: 'id = ?', whereArgs: [id]);
    _syncDelete('player_ratings', {'id': id});
  }

  /// Bewertungen eines Spielers je Spiel: matchId -> Sterne.
  Future<Map<String, double>> ratingsByPlayer(String playerId) async {
    final db = await _db;
    final rows = await db.query('player_ratings',
        columns: ['match_id', 'rating'],
        where: 'player_id = ?',
        whereArgs: [playerId]);
    return {
      for (final r in rows)
        r['match_id'] as String: (r['rating'] as num).toDouble()
    };
  }

  /// Vollständige Bewertungen eines Spielers je Spiel (inkl. Kommentar).
  Future<Map<String, PlayerRating>> ratingsFullByPlayer(
      String playerId) async {
    final db = await _db;
    final rows = await db.query('player_ratings',
        where: 'player_id = ?', whereArgs: [playerId]);
    return {
      for (final r in rows) r['match_id'] as String: PlayerRating.fromMap(r)
    };
  }

  /// Gesamt-Bewertung eines Spielers: (Durchschnitt, Anzahl). Durchschnitt
  /// ist null, wenn noch keine Bewertung vorliegt.
  Future<(double?, int)> ratingAverage(String playerId) async {
    final db = await _db;
    final rows = await db.rawQuery(
      'SELECT AVG(rating) AS a, COUNT(*) AS c FROM player_ratings '
      'WHERE player_id = ?',
      [playerId],
    );
    final c = (rows.first['c'] as int?) ?? 0;
    final a = (rows.first['a'] as num?)?.toDouble();
    return (c == 0 ? null : a, c);
  }

  /// Durchschnittsbewertung aller Spieler eines Teams: pid -> (Schnitt, Anzahl).
  Future<Map<String, (double, int)>> ratingAveragesForTeam(
      String teamId) async {
    final db = await _db;
    final rows = await db.rawQuery(
      'SELECT r.player_id AS pid, AVG(r.rating) AS a, COUNT(*) AS c '
      'FROM player_ratings r JOIN players p ON p.id = r.player_id '
      'WHERE p.team_id = ? GROUP BY r.player_id',
      [teamId],
    );
    return {
      for (final r in rows)
        r['pid'] as String:
            ((r['a'] as num).toDouble(), (r['c'] as int?) ?? 0),
    };
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
    _syncUpsert('match_nominations', nomination.toMap());
  }

  Future<void> deleteNomination(String matchId, String playerId) async {
    final db = await _db;
    await db.delete('match_nominations',
        where: 'match_id = ? AND player_id = ?', whereArgs: [matchId, playerId]);
    _syncDelete('match_nominations', {'match_id': matchId, 'player_id': playerId});
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
    _syncUpsert('card_entries', card.toMap());
  }

  Future<void> deleteCard(String id) async {
    final db = await _db;
    await db.delete('card_entries', where: 'id = ?', whereArgs: [id]);
    _syncDelete('card_entries', {'id': id});
  }

  /// Löscht die zu einem Live-Ereignis gehörende Karte (falls vorhanden).
  Future<void> deleteCardByEvent(String matchEventId) async {
    final db = await _db;
    await db.delete('card_entries',
        where: 'match_event_id = ?', whereArgs: [matchEventId]);
    _syncDelete('card_entries', {'match_event_id': matchEventId});
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
    _syncUpsert('player_notes', note.toMap());
  }

  Future<void> deleteNote(String id) async {
    final db = await _db;
    await db.delete('player_notes', where: 'id = ?', whereArgs: [id]);
    _syncDelete('player_notes', {'id': id});
  }

  /// Neuester Notiz-/Kommentartext je Spieler eines Teams (für Gegner-Scouting).
  Future<Map<String, String>> commentsForTeam(String teamId) async {
    final db = await _db;
    final rows = await db.rawQuery(
      'SELECT n.player_id AS pid, n.text AS txt FROM player_notes n '
      'JOIN players p ON p.id = n.player_id '
      'WHERE p.team_id = ? ORDER BY n.created_at DESC',
      [teamId],
    );
    final out = <String, String>{};
    for (final r in rows) {
      out.putIfAbsent(r['pid'] as String, () => r['txt'] as String);
    }
    return out;
  }

  // -------------------------------------------------------- Note categories
  Future<List<NoteCategory>> getNoteCategories() async {
    final db = await _db;
    final rows =
        await db.query('note_categories', orderBy: 'sort_order ASC, name ASC');
    return rows.map(NoteCategory.fromMap).toList();
  }

  Future<void> upsertNoteCategory(NoteCategory cat) =>
      _upsertById('note_categories', cat.toMap());

  /// Löscht eine Rubrik und entkoppelt alle Notizen, die sie nutzen
  /// (Notizen bleiben erhalten, landen aber unter „Ohne Rubrik").
  Future<void> deleteNoteCategory(String id) async {
    final db = await _db;
    await db.transaction((txn) async {
      await txn.update('player_notes', {'category_id': null},
          where: 'category_id = ?', whereArgs: [id]);
      await txn.delete('note_categories', where: 'id = ?', whereArgs: [id]);
    });
    _syncDelete('note_categories', {'id': id});
  }

  // ---------------------------------------------------------- Scout markers
  Future<Set<String>> getMarkers(String playerId) async {
    final db = await _db;
    final rows = await db.query('player_markers',
        columns: ['marker'], where: 'player_id = ?', whereArgs: [playerId]);
    return {for (final r in rows) r['marker'] as String};
  }

  /// Marker aller Spieler eines Teams: playerId -> Menge der Marker-Keys.
  Future<Map<String, Set<String>>> markersForTeam(String teamId) async {
    final db = await _db;
    final rows = await db.rawQuery(
      'SELECT m.player_id AS pid, m.marker AS marker '
      'FROM player_markers m JOIN players p ON p.id = m.player_id '
      'WHERE p.team_id = ?',
      [teamId],
    );
    final out = <String, Set<String>>{};
    for (final r in rows) {
      out.putIfAbsent(r['pid'] as String, () => {}).add(r['marker'] as String);
    }
    return out;
  }

  Future<void> setMarker(String playerId, String marker) async {
    final db = await _db;
    await db.insert('player_markers', {'player_id': playerId, 'marker': marker},
        conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> removeMarker(String playerId, String marker) async {
    final db = await _db;
    await db.delete('player_markers',
        where: 'player_id = ? AND marker = ?', whereArgs: [playerId, marker]);
  }

  // ----------------------------------------------------------------- To-Dos
  /// Aktive To-Dos (nicht archiviert): offene zuerst, dann nach Fälligkeit
  /// (frühestes zuerst, ohne Datum zuletzt), sonst nach Anlagedatum.
  Future<List<Todo>> getTodos() async {
    final db = await _db;
    final rows = await db.query('todos',
        where: 'archived = 0',
        orderBy:
            'done ASC, (due_date IS NULL) ASC, due_date ASC, created_at DESC');
    return rows.map(Todo.fromMap).toList();
  }

  /// Archivierte To-Dos (zuletzt erledigte/angelegte zuerst).
  Future<List<Todo>> getArchivedTodos() async {
    final db = await _db;
    final rows = await db.query('todos',
        where: 'archived = 1',
        orderBy: 'completed_at DESC, created_at DESC');
    return rows.map(Todo.fromMap).toList();
  }

  Future<int> openTodoCount() async {
    final db = await _db;
    final rows = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM todos WHERE done = 0 AND archived = 0');
    return (rows.first['c'] as int?) ?? 0;
  }

  Future<void> upsertTodo(Todo todo) => _upsertById('todos', todo.toMap());

  Future<void> deleteTodo(String id) async {
    final db = await _db;
    await db.delete('todos', where: 'id = ?', whereArgs: [id]);
    _syncDelete('todos', {'id': id});
  }

  // ----------------------------------------------------- Aufgaben-Themen
  Future<List<TodoTopic>> getTodoTopics() async {
    final db = await _db;
    final rows = await db.query('todo_topics',
        orderBy: 'sort_order ASC, created_at ASC');
    return rows.map(TodoTopic.fromMap).toList();
  }

  Future<void> upsertTodoTopic(TodoTopic topic) =>
      _upsertById('todo_topics', topic.toMap());

  /// Löscht ein Thema; zugeordnete Aufgaben werden auf „ohne Thema" gesetzt.
  Future<void> deleteTodoTopic(String id) async {
    final db = await _db;
    await db.update('todos', {'topic_id': null},
        where: 'topic_id = ?', whereArgs: [id]);
    await db.delete('todo_topics', where: 'id = ?', whereArgs: [id]);
    _syncDelete('todo_topics', {'id': id});
  }

  // --------------------------------------------------- Spielergespräche
  Future<List<PlayerTalk>> getTalks() async {
    final db = await _db;
    final rows =
        await db.query('player_talks', orderBy: 'scheduled_at DESC');
    return rows.map(PlayerTalk.fromMap).toList();
  }

  Future<List<PlayerTalk>> getTalksForPlayer(String playerId) async {
    final db = await _db;
    final rows = await db.query('player_talks',
        where: 'player_id = ?',
        whereArgs: [playerId],
        orderBy: 'scheduled_at DESC');
    return rows.map(PlayerTalk.fromMap).toList();
  }

  Future<void> upsertTalk(PlayerTalk talk) =>
      _upsertById('player_talks', talk.toMap());

  Future<void> deleteTalk(String id) async {
    final db = await _db;
    await db.delete('player_talks', where: 'id = ?', whereArgs: [id]);
    _syncDelete('player_talks', {'id': id});
  }

  // ------------------------------------------------------------ Absences
  Future<List<PlayerAbsence>> getAbsences(String playerId) async {
    final db = await _db;
    final rows = await db.query('player_absences',
        where: 'player_id = ?', whereArgs: [playerId], orderBy: 'from_date DESC');
    return rows.map(PlayerAbsence.fromMap).toList();
  }

  Future<void> upsertAbsence(PlayerAbsence a) =>
      _upsertById('player_absences', a.toMap());

  /// Alle Abwesenheiten der Spieler eines Teams, optional nach Status.
  Future<List<PlayerAbsence>> absencesForTeam(String teamId,
      {PlayerStatus? status}) async {
    final db = await _db;
    final args = <Object?>[teamId];
    var sql = 'SELECT a.* FROM player_absences a '
        'JOIN players p ON p.id = a.player_id WHERE p.team_id = ?';
    if (status != null) {
      sql += ' AND a.status = ?';
      args.add(status.storageKey);
    }
    final rows = await db.rawQuery(sql, args);
    return rows.map(PlayerAbsence.fromMap).toList();
  }

  Future<void> deleteAbsence(String id) async {
    final db = await _db;
    await db.delete('player_absences', where: 'id = ?', whereArgs: [id]);
    _syncDelete('player_absences', {'id': id});
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
