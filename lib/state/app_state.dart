import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../data/coach_repository.dart';
import '../models/card_entry.dart';
import '../models/enums.dart';
import '../models/lineup.dart';
import '../models/match.dart';
import '../models/match_event.dart';
import '../models/nomination.dart';
import '../models/player.dart';
import '../models/player_note.dart';
import '../models/team_event.dart';
import '../models/player_rating.dart';
import '../models/player_stat.dart';
import '../models/team.dart';
import '../services/fupa/fupa_dtos.dart';
import '../services/fupa/fupa_persistence.dart';
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

    onProgress?.call('Spielplan wird geladen …');
    final matches = await _importer.importSchedule(url);
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
    final matches = await _importer.importSchedule(url);
    final added = await _persist.syncSchedule(team.id, matches);
    await _reload();
    notifyListeners();
    return added;
  }

  /// Importiert die Spieler-Saison-Statistik aus einem FuPa-Link und ersetzt
  /// den bisherigen Stand des Teams. Gibt die Anzahl Spieler zurück.
  Future<int> importStats(String teamId, String url) async {
    final n = await _importStatsInto(teamId, url);
    notifyListeners();
    return n;
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

  Future<void> addNote(String playerId, String text) async {
    await _repo.upsertNote(PlayerNote(
      id: _uuid.v4(),
      playerId: playerId,
      text: text.trim(),
      createdAt: DateTime.now(),
    ));
    notifyListeners();
  }

  Future<void> deleteNote(String id) async {
    await _repo.deleteNote(id);
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

  Future<void> setRating({
    required String matchId,
    required String playerId,
    required double rating,
    String? note,
  }) async {
    final existing = await _repo.getRatings(matchId);
    final prior =
        existing.where((r) => r.playerId == playerId).firstOrNull;
    await _repo.upsertRating(PlayerRating(
      id: prior?.id ?? _uuid.v4(),
      matchId: matchId,
      playerId: playerId,
      rating: rating,
      note: note,
      createdAt: prior?.createdAt ?? DateTime.now(),
    ));
    notifyListeners();
  }
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}
