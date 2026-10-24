import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../data/coach_repository.dart';
import '../models/card_entry.dart';
import '../models/enums.dart';
import '../models/lineup.dart';
import '../models/match.dart';
import '../models/match_event.dart';
import '../models/material_duty_config.dart';
import '../models/nomination.dart';
import '../models/note_category.dart';
import '../models/player.dart';
import '../models/player_absence.dart';
import '../models/player_note.dart';
import '../models/scout_marker.dart';
import '../models/team_event.dart';
import '../models/player_rating.dart';
import '../models/player_stat.dart';
import '../models/team.dart';
import '../models/player_talk.dart';
import '../models/todo.dart';
import '../models/todo_topic.dart';
import '../services/fupa/fupa_dtos.dart';
import '../services/fupa/fupa_persistence.dart';
import '../services/material_duty.dart';
import '../services/fupa/fupa_redux_importer.dart';
import '../services/opponent_sync_service.dart';

/// Zusammenfassung eines kompletten FuPa-Imports (für die Status-Anzeige).
class ConnectSummary {
  final String teamName;
  final int players;
  final int matches;
  final int newMatches;
  final int stats;
  const ConnectSummary({
    required this.teamName,
    required this.players,
    required this.matches,
    required this.newMatches,
    required this.stats,
  });
}

/// Art eines offenen „Nachholen"-Punkts.
enum NachholenKind { rating, nomination, lineup }

/// Ein offener Punkt für die „Nachholen"-Liste (verknüpft mit einem Spiel).
class NachholenItem {
  final NachholenKind kind;
  final String matchId;
  final String title;
  final String detail;
  final DateTime? kickoff;
  const NachholenItem({
    required this.kind,
    required this.matchId,
    required this.title,
    required this.detail,
    this.kickoff,
  });
}

/// Zentraler Anwendungszustand. Verdrahtet Persistenz, FuPa-Import und
/// Gegner-Sync und stellt der UI alle Operationen bereit.
class AppState extends ChangeNotifier {
  AppState({CoachRepository? repository})
      : _repo = repository ?? CoachRepository();

  final CoachRepository _repo;
  final _uuid = const Uuid();
  late final FupaPersistence _persist = FupaPersistence(_repo);
  final FupaReduxImporter _importer = FupaReduxImporter();

  CoachRepository get repository => _repo;

  bool _loading = true;
  bool get loading => _loading;

  Team? _ownTeam;
  Team? get ownTeam => _ownTeam;

  List<GameMatch> _matches = [];
  List<GameMatch> get matches => List.unmodifiable(_matches);

  late final OpponentSyncService opponentSync =
      OpponentSyncService(repository: _repo, importer: _importer);

  // ------------------------------------------------------------- Lifecycle
  Future<void> init() async {
    await _reload();
    await _autoRevertAbsences();
    _loading = false;
    notifyListeners();
  }

  Future<void> _reload() async {
    _ownTeam = await _repo.getOwnTeam();
    _matches = _ownTeam == null ? [] : await _repo.getMatches(_ownTeam!.id);
  }

  Future<void> refresh() async {
    await _reload();
    notifyListeners();
  }

  // ----------------------------------------------------------- FuPa-Import
  /// Verbindet das eigene Team über einen FuPa-Teamlink und lädt alles:
  /// Vereinsdaten + Logo, Kader + Fotos, Spielplan + Ergebnisse, Statistik.
  Future<ConnectSummary> connectOwnTeam(String url,
      {void Function(String)? onProgress}) async {
    onProgress?.call('Mannschaft & Kader werden geladen …');
    final teamImport = await _importer.importTeam(url);
    final team = await _persist.saveOwnTeam(url, teamImport);

    onProgress?.call('Spielerfotos werden geladen …');
    final playerData =
        await _importer.toPlayerDataWithPhotos(teamImport.players);
    await _persist.syncPlayers(team.id, playerData, DataSource.fupaApproved);

    onProgress?.call('Spielplan wird geladen (ganze Saison) …');
    final matches = await _fullSchedule(url);
    final newMatches = await _persist.syncSchedule(team.id, matches);

    onProgress?.call('Statistik wird geladen …');
    var statsCount = 0;
    try {
      statsCount = await _importStatsInto(team.id, url);
    } catch (_) {
      // Statistik ist optional – Rest des Imports bleibt gültig.
    }

    await _reload();
    notifyListeners();
    return ConnectSummary(
      teamName: team.name,
      players: playerData.length,
      matches: matches.length,
      newMatches: newMatches,
      stats: statsCount,
    );
  }

  /// Lädt alles für das bereits verbundene Team erneut.
  Future<ConnectSummary> resyncOwnTeam({void Function(String)? onProgress}) async {
    final url = _ownTeam?.fupaUrl;
    if (url == null || url.isEmpty) {
      throw StateError('Kein verbundenes Team mit FuPa-Link.');
    }
    return connectOwnTeam(url, onProgress: onProgress);
  }

  /// Importiert den Spielplan (inkl. Ergebnisse, Gegner-Link und -Logo) aus
  /// einem FuPa-Team-/Matches-Link. Gibt die Anzahl NEUER Spiele zurück.
  Future<int> importSchedule(String url) async {
    final team = await ensureOwnTeam();
    final matches = await _fullSchedule(url);
    final added = await _persist.syncSchedule(team.id, matches);
    await _reload();
    notifyListeners();
    return added;
  }

  /// Team-Spielplan (ab aktuellem Spieltag) + ganze Saison aus der Liga-API
  /// (inkl. vergangener Spieltage), dedupliziert pro Gegner und Spieltag.
  Future<List<ScheduledMatchData>> _fullSchedule(String url) async {
    final teamMatches = await _importer.importSchedule(url);
    var leagueMatches = const <ScheduledMatchData>[];
    try {
      leagueMatches = await _importer.importLeagueScheduleForTeam(url);
    } catch (_) {
      // Liga-Nachladen ist optional (z.B. ohne Liga-Kontext).
    }
    final seen = <String>{};
    final out = <ScheduledMatchData>[];
    for (final m in [...teamMatches, ...leagueMatches]) {
      final day = m.kickoff?.toIso8601String().substring(0, 10) ??
          m.externalId ??
          '';
      final key = '${m.opponentName.trim().toLowerCase()}|$day';
      if (seen.add(key)) out.add(m);
    }
    return out;
  }

  /// Importiert die Spieler-Saison-Statistik aus einem FuPa-Link und ersetzt
  /// den bisherigen Stand des Teams. Gibt die Anzahl Spieler zurück.
  Future<int> importStats(String teamId, String url) async {
    final n = await _importStatsInto(teamId, url);
    notifyListeners();
    return n;
  }

  /// Stellt sicher, dass für ein (Gegner-)Team eine Statistik vorliegt: fehlt
  /// sie und ist ein FuPa-Link hinterlegt, wird sie nachgeladen. So zeigt die
  /// Gegner-Analyse Torjäger & Co. auch ohne manuelles Neu-Synchronisieren.
  Future<void> ensureOpponentStats(String teamId) async {
    final existing = await _repo.getStats(teamId);
    if (existing.isNotEmpty) return;
    final team = await _repo.getTeam(teamId);
    final url = team?.fupaUrl;
    if (url == null || url.isEmpty) return;
    try {
      await _importStatsInto(teamId, url);
      notifyListeners();
    } catch (_) {
      // Statistik ist optional.
    }
  }

  Future<int> _importStatsInto(String teamId, String url) async {
    final data = await _importer.importStats(url);
    final stats = data
        .map((d) => PlayerStat(
              id: _uuid.v4(),
              teamId: teamId,
              externalId: d.externalId,
              firstName: d.firstName,
              lastName: d.lastName,
              matches: d.matches,
              goals: d.goals,
              assists: d.assists,
              yellowCards: d.yellowCards,
              yellowRedCards: d.yellowRedCards,
              redCards: d.redCards,
              minutes: d.minutes,
              topEleven: d.topEleven,
            ))
        .toList();
    await _repo.replaceStats(teamId, stats);
    return stats.length;
  }

  Future<List<PlayerStat>> statsOf(String teamId) => _repo.getStats(teamId);

  // -------------------------------------------------------- Team / Players
  Future<Team> ensureOwnTeam() async {
    _ownTeam ??= await _repo.getOwnTeam();
    if (_ownTeam == null) {
      final t = Team(
        id: _uuid.v4(),
        name: 'Meine Mannschaft',
        isOwnTeam: true,
        source: DataSource.manual,
        createdAt: DateTime.now(),
      );
      await _repo.upsertTeam(t);
      _ownTeam = t;
      notifyListeners();
    }
    return _ownTeam!;
  }

  Future<void> renameTeam(String teamId, String name, {String? shortName}) async {
    final t = await _repo.getTeam(teamId);
    if (t == null) return;
    await _repo.upsertTeam(t.copyWith(name: name, shortName: shortName));
    await _reload();
    notifyListeners();
  }

  /// Übernimmt importierte Vereinsdaten (Name/Kurzname/Logo) in ein Team.
  Future<void> updateTeamMeta(
    String teamId, {
    String? name,
    String? shortName,
    String? logoPath,
  }) async {
    final t = await _repo.getTeam(teamId);
    if (t == null) return;
    await _repo.upsertTeam(t.copyWith(
      name: (name != null && name.isNotEmpty) ? name : null,
      shortName: (shortName != null && shortName.isNotEmpty) ? shortName : null,
      logoPath: (logoPath != null && logoPath.isNotEmpty) ? logoPath : null,
    ));
    await _reload();
    notifyListeners();
  }

  Future<List<Player>> playersOf(String teamId, {bool onlyActive = false}) =>
      _repo.getPlayers(teamId, onlyActive: onlyActive);

  Future<void> addPlayer(
    String teamId, {
    required String firstName,
    required String lastName,
    int? number,
    String? position,
    String? wishPosition,
    PlayerStatus status = PlayerStatus.fit,
    CaptainRole captainRole = CaptainRole.none,
  }) async {
    final player = Player(
      id: _uuid.v4(),
      teamId: teamId,
      firstName: firstName.trim(),
      lastName: lastName.trim(),
      number: number,
      position: position,
      wishPosition: wishPosition,
      status: status,
      captainRole: captainRole,
      source: DataSource.manual,
      createdAt: DateTime.now(),
    );
    await _repo.upsertPlayer(player);
    await _enforceCaptainUniqueness(player);
    notifyListeners();
  }

  Future<void> updatePlayer(Player player) async {
    await _repo.upsertPlayer(player);
    await _enforceCaptainUniqueness(player);
    notifyListeners();
  }

  // ---------------------------------------------------------- Abwesenheiten
  Future<List<PlayerAbsence>> absencesOf(String playerId) =>
      _repo.getAbsences(playerId);

  /// Legt eine Abwesenheit an (Zeitraum + Grund) und setzt den Spielerstatus.
  Future<void> addAbsence({
    required Player player,
    required PlayerStatus status,
    required DateTime from,
    required DateTime until,
    String? note,
  }) async {
    await _repo.upsertAbsence(PlayerAbsence(
      id: _uuid.v4(),
      playerId: player.id,
      status: status,
      from: from,
      until: until,
      note: note,
      createdAt: DateTime.now(),
    ));
    await updatePlayer(player.copyWith(status: status));
  }

  Future<void> updateAbsence(PlayerAbsence a) async {
    await _repo.upsertAbsence(a);
    notifyListeners();
  }

  Future<void> deleteAbsence(String id) async {
    await _repo.deleteAbsence(id);
    notifyListeners();
  }

  /// FuPa-Saisonstatistik eines Spielers (über den Namen zugeordnet).
  Future<PlayerStat?> playerSeasonStat(String teamId, String dedupKey) async {
    final stats = await _repo.getStats(teamId);
    for (final s in stats) {
      final key =
          '${s.firstName.trim().toLowerCase()}|${s.lastName.trim().toLowerCase()}';
      if (key == dedupKey) return s;
    }
    return null;
  }

  /// Setzt Spieler, deren Abwesenheit abgelaufen ist, automatisch auf „Fit".
  Future<void> _autoRevertAbsences() async {
    final team = _ownTeam;
    if (team == null) return;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final players = await _repo.getPlayers(team.id);
    for (final p in players) {
      if (!p.status.isAbsence) continue;
      final abs = await _repo.getAbsences(p.id);
      PlayerAbsence? current;
      for (final a in abs) {
        if (a.status == p.status) {
          current = a;
          break;
        }
      }
      // Abgelaufen (letzter Tag liegt vor heute) -> wieder Fit.
      if (current != null && current.until.isBefore(today)) {
        await _repo.upsertPlayer(p.copyWith(status: PlayerStatus.fit));
      }
    }
  }

  /// Sorgt dafür, dass jede Kapitäns-Rolle pro Team nur einmal vergeben ist.
  Future<void> _enforceCaptainUniqueness(Player player) async {
    if (player.captainRole == CaptainRole.none) return;
    final mates = await _repo.getPlayers(player.teamId);
    for (final other in mates) {
      if (other.id != player.id && other.captainRole == player.captainRole) {
        await _repo.upsertPlayer(other.copyWith(captainRole: CaptainRole.none));
      }
    }
  }

  Future<void> deletePlayer(String id) async {
    await _repo.deletePlayer(id);
    notifyListeners();
  }

  /// Übernimmt per Einfügen erkannte Spieler mit Duplikatschutz
  /// (gleiche Dedup-Regeln wie der FuPa-Import). Gibt die Anzahl NEU
  /// angelegter Spieler zurück.
  Future<int> importPastedPlayers(
      String teamId, List<PlayerData> players) async {
    if (players.isEmpty) return 0;
    final persist = FupaPersistence(_repo);
    final added =
        await persist.syncPlayers(teamId, players, DataSource.manual);
    await _reload();
    notifyListeners();
    return added;
  }

  // ---------------------------------------------------------------- Matches
  Future<GameMatch> addMatch({
    required String opponentName,
    DateTime? kickoff,
    Venue venue = Venue.home,
    String? competition,
  }) async {
    final team = await ensureOwnTeam();
    final match = GameMatch(
      id: _uuid.v4(),
      ownTeamId: team.id,
      opponentName: opponentName.trim(),
      kickoff: kickoff,
      venue: venue,
      competition: competition,
      createdAt: DateTime.now(),
    );
    await _repo.upsertMatch(match);
    await _reload();
    notifyListeners();
    return match;
  }

  Future<void> updateMatch(GameMatch match) async {
    await _repo.upsertMatch(match);
    await _reload();
    notifyListeners();
  }

  Future<void> deleteMatch(String id) async {
    await _repo.deleteMatch(id);
    await _reload();
    notifyListeners();
  }

  Future<GameMatch?> getMatch(String id) => _repo.getMatch(id);

  /// Zusatz-Infos je Spiel für die Mannschafts-Kadernachricht (Spielstätte,
  /// Adresse, Treffpunkt). Pro Spiel als JSON in den Settings gehalten.
  Future<Map<String, String>> matchShareInfo(String matchId) async {
    final s = await _repo.getSetting('share_info_$matchId');
    if (s == null || s.isEmpty) return {};
    try {
      final m = jsonDecode(s) as Map<String, Object?>;
      return m.map((k, v) => MapEntry(k, (v ?? '').toString()));
    } catch (_) {
      return {};
    }
  }

  Future<void> saveMatchShareInfo(
      String matchId, Map<String, String> info) async {
    await _repo.setSetting('share_info_$matchId', jsonEncode(info));
  }

  /// Abweichende Rückennummern für genau ein Spiel (Spieler-ID → Nummer).
  /// Fehlt ein Eintrag, gilt die Standard-Nummer des Spielers.
  Future<Map<String, int>> matchNumbers(String matchId) async {
    final s = await _repo.getSetting('match_numbers_$matchId');
    if (s == null || s.isEmpty) return {};
    try {
      final m = jsonDecode(s) as Map<String, Object?>;
      final out = <String, int>{};
      m.forEach((k, v) {
        final n = v is num ? v.toInt() : int.tryParse('$v');
        if (n != null) out[k] = n;
      });
      return out;
    } catch (_) {
      return {};
    }
  }

  Future<void> setMatchNumber(
      String matchId, String playerId, int? number) async {
    final map = await matchNumbers(matchId);
    if (number == null) {
      map.remove(playerId);
    } else {
      map[playerId] = number;
    }
    await _repo.setSetting('match_numbers_$matchId', jsonEncode(map));
    notifyListeners();
  }

  /// Spieltags-Ankündigung je Spiel (Spieltag, Trikot, Adresse, Treffpunkte,
  /// Einleitungstext). Als JSON in den Settings.
  Future<Map<String, String>> matchAnnouncement(String matchId) async {
    final s = await _repo.getSetting('announce_$matchId');
    if (s == null || s.isEmpty) return {};
    try {
      final m = jsonDecode(s) as Map<String, Object?>;
      return m.map((k, v) => MapEntry(k, (v ?? '').toString()));
    } catch (_) {
      return {};
    }
  }

  Future<void> saveMatchAnnouncement(
      String matchId, Map<String, String> info) async {
    await _repo.setSetting('announce_$matchId', jsonEncode(info));
  }

  // ------------------------------------------------------------- Nominations
  /// Status je Spieler für ein Spiel (Spieler ohne Datensatz = offen).
  Future<Map<String, NominationStatus>> nominationsOf(String matchId) async {
    final rows = await _repo.getNominations(matchId);
    return {for (final n in rows) n.playerId: n.status};
  }

  Future<void> setNomination(
      String matchId, String playerId, NominationStatus status) async {
    if (status == NominationStatus.open) {
      await _repo.deleteNomination(matchId, playerId);
    } else {
      await _repo.upsertNomination(Nomination(
        id: _uuid.v4(),
        matchId: matchId,
        playerId: playerId,
        status: status,
        updatedAt: DateTime.now(),
      ));
    }
    notifyListeners();
  }

  /// Setzt für mehrere Spieler denselben Status (Bulk, z.B. „alle zusagen").
  Future<void> setNominationBulk(
      String matchId, List<String> playerIds, NominationStatus status) async {
    for (final id in playerIds) {
      if (status == NominationStatus.open) {
        await _repo.deleteNomination(matchId, id);
      } else {
        await _repo.upsertNomination(Nomination(
          id: _uuid.v4(),
          matchId: matchId,
          playerId: id,
          status: status,
          updatedAt: DateTime.now(),
        ));
      }
    }
    notifyListeners();
  }

  /// Wird beim Öffnen eines Spiels aufgerufen (Gegner sicherstellen).
  Future<ImportResult> openMatch(GameMatch match, {bool force = false}) async {
    final result =
        await opponentSync.ensureOpponentForMatch(match, force: force);
    // Bei frischem Gegner-Import auch die Torschützen-Statistik laden,
    // damit das Scouting die Toranzahl zeigen und Torjäger markieren kann.
    if (result.status == ImportStatus.success) {
      final updated = await _repo.getMatch(match.id);
      final url = updated?.opponentFupaUrl;
      final oppId = updated?.opponentTeamId;
      if (url != null && url.isNotEmpty && oppId != null) {
        try {
          await _importStatsInto(oppId, url);
        } catch (_) {
          // Statistik ist optional.
        }
      }
    }
    await _reload();
    notifyListeners();
    return result;
  }

  // ---------------------------------------------------------------- Lineups
  Future<Lineup> ensureLineup(String matchId, String teamId,
      {String formation = '4-4-2'}) async {
    final existing = await _repo.getLineup(matchId, teamId);
    if (existing != null) return existing;
    final lineup = Lineup(
      id: _uuid.v4(),
      matchId: matchId,
      teamId: teamId,
      formation: formation,
      createdAt: DateTime.now(),
    );
    await _repo.upsertLineup(lineup);
    return lineup;
  }

  Future<List<LineupEntry>> lineupEntries(String lineupId) =>
      _repo.getLineupEntries(lineupId);

  Future<void> saveLineup(Lineup lineup, List<LineupEntry> entries) async {
    await _repo.upsertLineup(lineup);
    await _repo.replaceLineupEntries(lineup.id, entries);
    notifyListeners();
  }

  String newEntryId() => _uuid.v4();

  // ----------------------------------------------------------------- Events
  Future<List<MatchEvent>> eventsOf(String matchId) => _repo.getEvents(matchId);

  /// Fügt ein Ereignis hinzu und aktualisiert bei Toren den Spielstand.
  /// Karten-Ereignisse mit bekanntem Spieler werden zusätzlich in den
  /// Spieler-Kartenverlauf übernommen (verknüpft über die Ereignis-ID).
  Future<void> addEvent({
    required String matchId,
    required String teamId,
    required int minute,
    int minuteExtra = 0,
    required MatchEventType type,
    String? playerId,
    String? assistPlayerId,
    String? note,
    List<String> mentions = const [],
  }) async {
    final eventId = _uuid.v4();
    await _repo.upsertEvent(MatchEvent(
      id: eventId,
      matchId: matchId,
      teamId: teamId,
      minute: minute,
      minuteExtra: minuteExtra,
      type: type,
      playerId: playerId,
      assistPlayerId: assistPlayerId,
      note: note,
      createdAt: DateTime.now(),
    ));
    if (mentions.isNotEmpty) {
      await _repo.setEventMentions(eventId, mentions);
    }

    final cardType = CardType.fromEvent(type);
    if (cardType != null && playerId != null) {
      final match = await _repo.getMatch(matchId);
      await _repo.upsertCard(CardEntry(
        id: _uuid.v4(),
        playerId: playerId,
        type: cardType,
        date: match?.kickoff ?? DateTime.now(),
        matchId: matchId,
        matchEventId: eventId,
        minute: minute,
        minuteExtra: minuteExtra,
        note: note,
      ));
    }

    await _recomputeScore(matchId);
    notifyListeners();
  }

  Future<void> updateEvent(MatchEvent event) async {
    await _repo.upsertEvent(event);
    await _recomputeScore(event.matchId);
    notifyListeners();
  }

  Future<void> deleteEvent(String matchId, String eventId) async {
    await _repo.deleteEvent(eventId);
    await _repo.deleteCardByEvent(eventId);
    await _recomputeScore(matchId);
    notifyListeners();
  }

  // ------------------------------------------------------------------- Cards
  Future<List<CardEntry>> cardsOf(String playerId) => _repo.getCards(playerId);

  Future<Map<String, Map<CardType, int>>> cardCountsForTeam(String teamId) =>
      _repo.cardCountsForTeam(teamId);

  Future<List<MatchEvent>> playerMatchEvents(String playerId) =>
      _repo.getPlayerMatchEvents(playerId);

  /// Kommentare, in denen der Spieler erwähnt wurde.
  Future<List<MatchEvent>> mentionComments(String playerId) =>
      _repo.getMentionComments(playerId);

  /// Spiele eines Teams als Map (matchId -> Spiel), zum Auflösen von Gegner/Datum.
  Future<Map<String, GameMatch>> matchMap(String teamId) async {
    final list = await _repo.getMatches(teamId);
    return {for (final m in list) m.id: m};
  }

  Future<void> addCard({
    required String playerId,
    required CardType type,
    required DateTime date,
    String? matchId,
    int? minute,
    String? note,
  }) async {
    await _repo.upsertCard(CardEntry(
      id: _uuid.v4(),
      playerId: playerId,
      type: type,
      date: date,
      matchId: matchId,
      minute: minute,
      note: note,
    ));
    notifyListeners();
  }

  Future<void> updateCard(CardEntry card) async {
    await _repo.upsertCard(card);
    notifyListeners();
  }

  Future<void> deleteCard(String id) async {
    await _repo.deleteCard(id);
    notifyListeners();
  }

  // ------------------------------------------------------------- Player notes
  Future<List<PlayerNote>> notesOf(String playerId) => _repo.getNotes(playerId);

  Future<void> addNote(String playerId, String text,
      {String? categoryId, String? matchId}) async {
    await _repo.upsertNote(PlayerNote(
      id: _uuid.v4(),
      playerId: playerId,
      text: text.trim(),
      createdAt: DateTime.now(),
      categoryId: categoryId,
      matchId: matchId,
    ));
    notifyListeners();
  }

  Future<void> updateNote(PlayerNote note) async {
    await _repo.upsertNote(note);
    notifyListeners();
  }

  Future<void> deleteNote(String id) async {
    await _repo.deleteNote(id);
    notifyListeners();
  }

  // --------------------------------------------------------- Note categories
  Future<List<NoteCategory>> noteCategories() => _repo.getNoteCategories();

  Future<void> addNoteCategory(String name) async {
    final existing = await _repo.getNoteCategories();
    await _repo.upsertNoteCategory(NoteCategory(
      id: _uuid.v4(),
      name: name.trim(),
      sortOrder: existing.length,
    ));
    notifyListeners();
  }

  Future<void> updateNoteCategory(NoteCategory cat) async {
    await _repo.upsertNoteCategory(cat);
    notifyListeners();
  }

  Future<void> deleteNoteCategory(String id) async {
    await _repo.deleteNoteCategory(id);
    notifyListeners();
  }

  // ------------------------------------------------------------- Team events
  Future<List<TeamEvent>> teamEvents() async {
    final team = await _repo.getOwnTeam();
    if (team == null) return [];
    return _repo.getTeamEvents(team.id);
  }

  Future<TeamEvent> addTeamEvent({
    required String title,
    required TeamEventType type,
    required DateTime date,
    String? location,
    String? note,
  }) async {
    final team = await ensureOwnTeam();
    final event = TeamEvent(
      id: _uuid.v4(),
      teamId: team.id,
      title: title.trim(),
      type: type,
      date: date,
      location: location,
      note: note,
      createdAt: DateTime.now(),
    );
    await _repo.upsertTeamEvent(event);
    notifyListeners();
    return event;
  }

  Future<TeamEvent?> getTeamEvent(String id) => _repo.getTeamEvent(id);

  Future<void> updateTeamEvent(TeamEvent event) async {
    await _repo.upsertTeamEvent(event);
    notifyListeners();
  }

  Future<void> deleteTeamEvent(String id) async {
    await _repo.deleteTeamEvent(id);
    notifyListeners();
  }

  Future<Map<String, NominationStatus>> eventAttendance(String eventId) async {
    final rows = await _repo.getEventAttendance(eventId);
    return {for (final a in rows) a.playerId: a.status};
  }

  Future<void> setEventAttendance(
      String eventId, String playerId, NominationStatus status) async {
    if (status == NominationStatus.open) {
      await _repo.deleteEventAttendance(eventId, playerId);
    } else {
      await _repo.upsertEventAttendance(EventAttendance(
        id: _uuid.v4(),
        eventId: eventId,
        playerId: playerId,
        status: status,
        updatedAt: DateTime.now(),
      ));
    }
    notifyListeners();
  }

  /// Leitet den Spielstand aus den Tor-Ereignissen ab und speichert ihn.
  Future<void> _recomputeScore(String matchId) async {
    final match = await _repo.getMatch(matchId);
    if (match == null) return;
    final counts = await _repo.goalCountByTeam(matchId);
    final own = counts[match.ownTeamId] ?? 0;
    var opp = 0;
    counts.forEach((teamId, c) {
      if (teamId != match.ownTeamId) opp += c;
    });
    await _repo.upsertMatch(match.copyWith(ownScore: own, opponentScore: opp));
    await _reload();
  }

  /// Setzt ausgewählte Teile eines Spiels zurück.
  Future<void> resetMatchParts(
    String matchId,
    String teamId, {
    bool verlauf = true,
    bool aufstellung = false,
    bool nominierung = false,
  }) async {
    if (verlauf) {
      await _repo.resetMatchEvents(matchId);
      final match = await _repo.getMatch(matchId);
      if (match != null) {
        await _repo.upsertMatch(match.copyWith(
          status: MatchStatus.scheduled,
          ownScore: 0,
          opponentScore: 0,
        ));
      }
    }
    if (aufstellung) await _repo.deleteLineup(matchId, teamId);
    if (nominierung) await _repo.deleteNominationsForMatch(matchId);
    await _reload();
    notifyListeners();
  }

  Future<void> setMatchStatus(String matchId, MatchStatus status) async {
    final match = await _repo.getMatch(matchId);
    if (match == null) return;
    await _repo.upsertMatch(match.copyWith(status: status));
    await _reload();
    notifyListeners();
  }

  // ---------------------------------------------------------------- Ratings
  Future<List<PlayerRating>> ratingsOf(String matchId) =>
      _repo.getRatings(matchId);

  /// Bewertungen eines Spiels als Map spielerId -> Bewertung.
  Future<Map<String, PlayerRating>> ratingsMapOf(String matchId) async {
    final list = await _repo.getRatings(matchId);
    return {for (final r in list) r.playerId: r};
  }

  Future<void> setRating({
    required String matchId,
    required String playerId,
    required double rating,
    String? note,
    bool keepNote = true,
  }) async {
    final existing = await _repo.getRatings(matchId);
    final prior =
        existing.where((r) => r.playerId == playerId).firstOrNull;
    await _repo.upsertRating(PlayerRating(
      id: prior?.id ?? _uuid.v4(),
      matchId: matchId,
      playerId: playerId,
      rating: rating,
      note: note ?? (keepNote ? prior?.note : null),
      createdAt: prior?.createdAt ?? DateTime.now(),
    ));
    notifyListeners();
  }

  /// Entfernt die Bewertung eines Spielers für ein Spiel (falls vorhanden).
  Future<void> removeRating(String matchId, String playerId) async {
    final existing = await _repo.getRatings(matchId);
    for (final r in existing.where((r) => r.playerId == playerId)) {
      await _repo.deleteRating(r.id);
    }
    notifyListeners();
  }

  /// Bewertungen eines Spielers je Spiel (matchId -> Sterne) – fürs Nachholen
  /// und Korrigieren im Profil.
  Future<Map<String, double>> playerRatingsByMatch(String playerId) =>
      _repo.ratingsByPlayer(playerId);

  /// Vollständige Bewertungen je Spiel (inkl. Kommentar) – fürs Profil.
  Future<Map<String, PlayerRating>> playerRatingsFull(String playerId) =>
      _repo.ratingsFullByPlayer(playerId);

  /// Gesamtschnitt eines Spielers über alle Spiele: (Durchschnitt, Anzahl).
  Future<(double?, int)> ratingAverage(String playerId) =>
      _repo.ratingAverage(playerId);

  Future<Map<String, (double, int)>> ratingAveragesForTeam(String teamId) =>
      _repo.ratingAveragesForTeam(teamId);

  // --------------------------------------------------------------- Scouting
  Future<Set<ScoutMarker>> scoutMarkersOf(String playerId) async {
    final keys = await _repo.getMarkers(playerId);
    return keys.map(ScoutMarker.fromKey).whereType<ScoutMarker>().toSet();
  }

  Future<Map<String, Set<ScoutMarker>>> scoutMarkersForTeam(
      String teamId) async {
    final raw = await _repo.markersForTeam(teamId);
    return raw.map((pid, keys) => MapEntry(
        pid, keys.map(ScoutMarker.fromKey).whereType<ScoutMarker>().toSet()));
  }

  /// Kommentare je Spieler eines Teams (playerId -> neuester Text).
  Future<Map<String, String>> scoutCommentsForTeam(String teamId) =>
      _repo.commentsForTeam(teamId);

  /// Liga-Tabelle (komplett) + Platz + Form (letzte 5) des Gegners.
  Future<(StandingRow?, List<FormMatch>, List<StandingRow>)> opponentAnalysis(
      String ownTeamId, String opponentTeamId) async {
    final own = await _repo.getTeam(ownTeamId);
    final opp = await _repo.getTeam(opponentTeamId);
    final oppSlug = FupaReduxImporter.teamSlugFromUrl(opp?.fupaUrl);
    const empty = (null, <FormMatch>[], <StandingRow>[]);
    if (oppSlug == null) return empty;
    // Liga-Slug aus Einstellungen (Cache) oder aus dem eigenen Team ableiten.
    var leagueSlug = await _repo.getSetting('league_slug');
    if (leagueSlug == null || leagueSlug.isEmpty) {
      final url = own?.fupaUrl;
      if (url != null) {
        leagueSlug = await _importer.leagueSlugForTeam(url);
        if (leagueSlug != null) {
          await _repo.setSetting('league_slug', leagueSlug);
        }
      }
    }
    if (leagueSlug == null) return empty;
    var table = const <StandingRow>[];
    var form = const <FormMatch>[];
    try {
      table = await _importer.fetchStanding(leagueSlug);
    } catch (_) {}
    try {
      // Mehr Spiele laden, damit die Niederlagen der ganzen Saison vorliegen;
      // die „letzte 5"-Karte nimmt sich davon die ersten fünf.
      form = await _importer.fetchTeamForm(leagueSlug, oppSlug, limit: 50);
    } catch (_) {}
    StandingRow? standing;
    for (final r in table) {
      if (r.teamSlug == oppSlug) {
        standing = r;
        break;
      }
    }
    return (standing, form, table);
  }

  /// Komplette Liga-Tabelle + die Zeile unseres Teams (für die Statistik).
  Future<(StandingRow?, List<StandingRow>)> leagueTable(String ownTeamId) async {
    final own = await _repo.getTeam(ownTeamId);
    final ownSlug = FupaReduxImporter.teamSlugFromUrl(own?.fupaUrl);
    const empty = (null, <StandingRow>[]);
    var leagueSlug = await _repo.getSetting('league_slug');
    if (leagueSlug == null || leagueSlug.isEmpty) {
      final url = own?.fupaUrl;
      if (url != null) {
        leagueSlug = await _importer.leagueSlugForTeam(url);
        if (leagueSlug != null) {
          await _repo.setSetting('league_slug', leagueSlug);
        }
      }
    }
    if (leagueSlug == null) return empty;
    var table = const <StandingRow>[];
    try {
      table = await _importer.fetchStanding(leagueSlug);
    } catch (_) {}
    StandingRow? ours;
    if (ownSlug != null) {
      for (final r in table) {
        if (r.teamSlug == ownSlug) {
          ours = r;
          break;
        }
      }
    }
    return (ours, table);
  }

  // ---------------------------------------------------- Ball-/Materialdienst
  Future<MaterialDutyConfig> materialDutyConfig(String teamId) async {
    final s = await _repo.getSetting('material_duty_$teamId');
    return MaterialDutyConfig.decode(s);
  }

  Future<void> saveMaterialDutyConfig(
      String teamId, MaterialDutyConfig config) async {
    await _repo.setSetting('material_duty_$teamId', config.encode());
    notifyListeners();
  }

  /// Urlaube der Team-Spieler (aus den „Urlaub"-Abwesenheiten) als Zeiträume.
  Future<List<DutyVacation>> materialDutyVacations(String teamId) async {
    final abs =
        await _repo.absencesForTeam(teamId, status: PlayerStatus.urlaub);
    return abs
        .map((a) => DutyVacation(a.playerId, a.from, a.until))
        .toList();
  }

  Future<void> toggleScoutMarker(
      String playerId, ScoutMarker m, bool on) async {
    if (on) {
      await _repo.setMarker(playerId, m.storageKey);
    } else {
      await _repo.removeMarker(playerId, m.storageKey);
    }
    notifyListeners();
  }

  /// Einzelner Scouting-Kommentar (Klartext) zu einem Gegner-Spieler.
  Future<String> scoutCommentOf(String playerId) async {
    final notes = await _repo.getNotes(playerId);
    return notes.isEmpty ? '' : notes.first.text;
  }

  Future<void> setScoutComment(String playerId, String text) async {
    final existing = await _repo.getNotes(playerId);
    final t = text.trim();
    if (t.isEmpty) {
      for (final n in existing) {
        await _repo.deleteNote(n.id);
      }
    } else {
      final id = existing.isNotEmpty ? existing.first.id : _uuid.v4();
      await _repo.upsertNote(PlayerNote(
        id: id,
        playerId: playerId,
        text: t,
        createdAt:
            existing.isNotEmpty ? existing.first.createdAt : DateTime.now(),
      ));
      // Nur ein Kommentar behalten – ältere Einträge entfernen.
      for (final n in existing.skip(1)) {
        await _repo.deleteNote(n.id);
      }
    }
    notifyListeners();
  }

  /// Tore je Spieler (dedupKey „vorname|nachname" -> Tore) aus der Statistik.
  Future<Map<String, int>> scoutGoals(String teamId) async {
    final stats = await _repo.getStats(teamId);
    final map = <String, int>{};
    for (final s in stats) {
      final key =
          '${s.firstName.trim().toLowerCase()}|${s.lastName.trim().toLowerCase()}';
      map[key] = (map[key] ?? 0) + s.goals;
    }
    return map;
  }

  // --------------------------------------------------------------- Nachholen
  Future<List<Todo>> todos() => _repo.getTodos();

  Future<List<Todo>> archivedTodos() => _repo.getArchivedTodos();

  Future<void> addTodo(
    String text, {
    DateTime? dueDate,
    String? topicId,
    List<TodoResponsible> responsible = const [],
  }) async {
    final t = text.trim();
    if (t.isEmpty) return;
    await _repo.upsertTodo(Todo(
      id: _uuid.v4(),
      text: t,
      createdAt: DateTime.now(),
      dueDate: dueDate,
      topicId: topicId,
      responsible: responsible,
    ));
    notifyListeners();
  }

  /// Komplette Aufgabe speichern (z.B. nach dem Bearbeiten im Dialog).
  Future<void> saveTodo(Todo todo) async {
    await _repo.upsertTodo(todo);
    notifyListeners();
  }

  // -------------------------------------------------------- Aufgaben-Themen
  Future<List<TodoTopic>> todoTopics() => _repo.getTodoTopics();

  Future<TodoTopic> addTodoTopic(String title) async {
    final topics = await _repo.getTodoTopics();
    final topic = TodoTopic(
      id: _uuid.v4(),
      title: title.trim(),
      sortOrder: topics.length,
      createdAt: DateTime.now(),
    );
    await _repo.upsertTodoTopic(topic);
    notifyListeners();
    return topic;
  }

  Future<void> renameTodoTopic(TodoTopic topic, String title) async {
    final t = title.trim();
    if (t.isEmpty) return;
    await _repo.upsertTodoTopic(topic.copyWith(title: t));
    notifyListeners();
  }

  Future<void> deleteTodoTopic(String id) async {
    await _repo.deleteTodoTopic(id);
    notifyListeners();
  }

  // ----------------------------------------------------- Spielergespräche
  Future<List<PlayerTalk>> talks() => _repo.getTalks();

  Future<List<PlayerTalk>> talksForPlayer(String playerId) =>
      _repo.getTalksForPlayer(playerId);

  Future<void> addTalk({
    required String playerId,
    required String title,
    required DateTime scheduledAt,
    String? notes,
    bool done = false,
  }) async {
    await _repo.upsertTalk(PlayerTalk(
      id: _uuid.v4(),
      playerId: playerId,
      title: title.trim(),
      scheduledAt: scheduledAt,
      notes: notes,
      done: done,
      createdAt: DateTime.now(),
    ));
    notifyListeners();
  }

  Future<void> saveTalk(PlayerTalk talk) async {
    await _repo.upsertTalk(talk);
    notifyListeners();
  }

  Future<void> deleteTalk(String id) async {
    await _repo.deleteTalk(id);
    notifyListeners();
  }

  /// Abhaken/aufmachen – beim Abhaken wird der Zeitpunkt festgehalten.
  Future<void> toggleTodo(Todo todo, bool done) async {
    await _repo.upsertTodo(done
        ? todo.copyWith(done: true, completedAt: DateTime.now())
        : todo.copyWith(done: false, clearCompletedAt: true));
    notifyListeners();
  }

  /// Fälligkeitsdatum setzen (null entfernt es).
  Future<void> setTodoDueDate(Todo todo, DateTime? dueDate) async {
    await _repo.upsertTodo(dueDate == null
        ? todo.copyWith(clearDueDate: true)
        : todo.copyWith(dueDate: dueDate));
    notifyListeners();
  }

  Future<void> setTodoArchived(Todo todo, bool archived) async {
    await _repo.upsertTodo(todo.copyWith(archived: archived));
    notifyListeners();
  }

  Future<void> updateTodoText(Todo todo, String text) async {
    final t = text.trim();
    if (t.isEmpty) {
      await deleteTodo(todo.id);
      return;
    }
    await _repo.upsertTodo(todo.copyWith(text: t));
    notifyListeners();
  }

  Future<void> deleteTodo(String id) async {
    await _repo.deleteTodo(id);
    notifyListeners();
  }

  /// Offene Punkte (Bewertungen / Nominierung / Aufstellung) zum Nachholen.
  Future<List<NachholenItem>> nachholen() async {
    final team = _ownTeam;
    if (team == null) return [];
    final matches = await _repo.getMatches(team.id);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    // Ende der aktuellen Woche (kommender Sonntag, 23:59). Nominierung/
    // Aufstellung nur bis dahin anzeigen – nicht für weit entfernte Spiele.
    final endOfWeek = today
        .add(Duration(days: 7 - now.weekday))
        .add(const Duration(hours: 23, minutes: 59, seconds: 59));
    final items = <NachholenItem>[];
    for (final m in matches) {
      final finished = m.status == MatchStatus.finished;
      if (finished) {
        // Offene Bewertungen: eingesetzte Spieler ohne Bewertung.
        final roster = await _ratingRoster(m);
        if (roster.isNotEmpty) {
          final rated =
              (await _repo.getRatings(m.id)).map((r) => r.playerId).toSet();
          final open = roster.where((id) => !rated.contains(id)).length;
          if (open > 0) {
            items.add(NachholenItem(
              kind: NachholenKind.rating,
              matchId: m.id,
              title: 'vs ${m.opponentName}',
              detail: '$open von ${roster.length} Spielern noch zu bewerten',
              kickoff: m.kickoff,
            ));
          }
        }
      } else {
        // Nur die aktuelle Woche und Vergangenes – keine weit entfernten Spiele.
        final relevant = m.kickoff == null || !m.kickoff!.isAfter(endOfWeek);
        if (!relevant) continue;
        final noms = await _repo.getNominations(m.id);
        if (noms.isEmpty) {
          items.add(NachholenItem(
            kind: NachholenKind.nomination,
            matchId: m.id,
            title: 'vs ${m.opponentName}',
            detail: 'Noch keine Nominierung',
            kickoff: m.kickoff,
          ));
        } else {
          final zugesagt =
              noms.where((n) => n.status == NominationStatus.zugesagt).length;
          if (zugesagt > 0) {
            final lineup = await _repo.getLineup(m.id, team.id);
            var starters = 0;
            if (lineup != null) {
              starters = (await _repo.getLineupEntries(lineup.id))
                  .where((e) => e.role == LineupRole.starter)
                  .length;
            }
            if (starters == 0) {
              items.add(NachholenItem(
                kind: NachholenKind.lineup,
                matchId: m.id,
                title: 'vs ${m.opponentName}',
                detail: 'Aufstellung fehlt',
                kickoff: m.kickoff,
              ));
            }
          }
        }
      }
    }
    return items;
  }

  Future<Set<String>> _ratingRoster(GameMatch m) =>
      playedPlayerIds(m.id, m.ownTeamId);

  /// Spieler, die im Spiel tatsächlich gespielt haben: Startelf + Eingewechselte
  /// (aus den Wechsel-Ereignissen). Ohne Aufstellung ersatzweise die Zugesagten
  /// – nur diese Spieler lassen sich für das Spiel bewerten.
  Future<Set<String>> playedPlayerIds(String matchId, String ownTeamId) async {
    final lineup = await _repo.getLineup(matchId, ownTeamId);
    if (lineup != null) {
      final played = <String>{
        for (final e in await _repo.getLineupEntries(lineup.id))
          if (e.role == LineupRole.starter) e.playerId,
      };
      for (final e in await _repo.getEvents(matchId)) {
        if (e.type == MatchEventType.substitution && e.playerId != null) {
          played.add(e.playerId!); // eingewechselt
        }
      }
      if (played.isNotEmpty) return played;
    }
    final noms = await _repo.getNominations(matchId);
    return noms
        .where((n) => n.status == NominationStatus.zugesagt)
        .map((n) => n.playerId)
        .toSet();
  }

  /// Spiele, in denen ein Spieler tatsächlich gespielt hat (für die Bewertung).
  Future<Set<String>> playedMatchIdsForPlayer(
      String playerId, String teamId) async {
    final matches = await _repo.getMatches(teamId);
    final out = <String>{};
    for (final m in matches) {
      final played = await playedPlayerIds(m.id, teamId);
      if (played.contains(playerId)) out.add(m.id);
    }
    return out;
  }

  /// Anzahl offener Nachhol-Punkte (Bewertungen/Nominierung/Aufstellung) –
  /// ohne To-Dos, die haben einen eigenen Menüpunkt.
  Future<int> nachholenCount() async => (await nachholen()).length;

  /// Anzahl offener (nicht erledigter) eigener Aufgaben – fürs Menü-Badge.
  Future<int> openTodoCount() => _repo.openTodoCount();
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}
