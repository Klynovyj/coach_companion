import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../data/coach_repository.dart';
import '../models/enums.dart';
import '../models/lineup.dart';
import '../models/match.dart';
import '../models/match_event.dart';
import '../models/player.dart';
import '../models/player_rating.dart';
import '../models/team.dart';
import '../services/fupa/approved_api_fupa_data_source.dart';
import '../services/fupa/fupa_dtos.dart';
import '../services/fupa/fupa_import_service.dart';
import '../services/fupa/fupa_persistence.dart';
import '../services/fupa/fupa_redux_importer.dart';
import '../services/fupa/fupa_source_registry.dart';
import '../services/fupa/manual_fupa_data_source.dart';
import '../services/opponent_sync_service.dart';

/// Zentraler Anwendungszustand. Verdrahtet Persistenz, FuPa-Import und
/// Gegner-Sync und stellt der UI alle Operationen bereit.
class AppState extends ChangeNotifier {
  AppState({CoachRepository? repository})
      : _repo = repository ?? CoachRepository();

  final CoachRepository _repo;
  final _uuid = const Uuid();

  CoachRepository get repository => _repo;

  // Settings-Keys
  static const kApiBase = 'fupa_api_base';
  static const kApiToken = 'fupa_api_token';

  bool _loading = true;
  bool get loading => _loading;

  String? _apiBase;
  String? _apiToken;
  String? get apiBase => _apiBase;
  String? get apiToken => _apiToken;
  bool get hasApprovedSource =>
      (_apiBase?.trim().isNotEmpty ?? false) &&
      (_apiToken?.trim().isNotEmpty ?? false);

  Team? _ownTeam;
  Team? get ownTeam => _ownTeam;

  List<GameMatch> _matches = [];
  List<GameMatch> get matches => List.unmodifiable(_matches);

  late FupaSourceRegistry _registry;
  late FupaImportService importService;
  late OpponentSyncService opponentSync;

  // ------------------------------------------------------------- Lifecycle
  Future<void> init() async {
    _apiBase = await _repo.getSetting(kApiBase);
    _apiToken = await _repo.getSetting(kApiToken);
    _rebuildServices();
    await _reload();
    _loading = false;
    notifyListeners();
  }

  void _rebuildServices() {
    _registry = FupaSourceRegistry([
      // Genehmigter Zugang zuerst – nur aktiv, wenn konfiguriert.
      ApprovedApiFupaDataSource(baseUrl: _apiBase, token: _apiToken),
      // Manueller Fallback ist immer vorhanden.
      ManualFupaDataSource(),
    ]);
    importService =
        FupaImportService(repository: _repo, registry: _registry);
    opponentSync = OpponentSyncService(repository: _repo);
  }

  FupaSourceRegistry get registry => _registry;

  Future<void> _reload() async {
    _ownTeam = await _repo.getOwnTeam();
    _matches = _ownTeam == null ? [] : await _repo.getMatches(_ownTeam!.id);
  }

  Future<void> refresh() async {
    await _reload();
    notifyListeners();
  }

  // -------------------------------------------------------------- Settings
  Future<void> saveApprovedSource(String? base, String? token) async {
    _apiBase = base?.trim();
    _apiToken = token?.trim();
    await _repo.setSetting(kApiBase, _apiBase);
    await _repo.setSetting(kApiToken, _apiToken);
    _rebuildServices();
    notifyListeners();
  }

  // ----------------------------------------------------------- FuPa-Import
  Future<ImportResult> connectOwnTeam(String url) async {
    final result = await importService.connectOwnTeam(url);
    await _reload();
    notifyListeners();
    return result;
  }

  /// Importiert den Spielplan (inkl. Ergebnisse, Gegner-Link und -Logo) aus
  /// einem FuPa-Team-/Matches-Link. Gibt die Anzahl NEUER Spiele zurück.
  Future<int> importSchedule(String url) async {
    final team = await ensureOwnTeam();
    final importer = FupaReduxImporter();
    final matches = await importer.importSchedule(url);
    final persist = FupaPersistence(_repo);
    final added = await persist.syncSchedule(team.id, matches);
    await _reload();
    notifyListeners();
    return added;
  }

  Future<ImportResult> resyncOwnTeam() async {
    final result = await importService.resyncOwnTeam();
    await _reload();
    notifyListeners();
    return result;
  }

  Future<List<SourceStatus>> sourceStatuses() => _registry.statuses();

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
  }) async {
    await _repo.upsertPlayer(Player(
      id: _uuid.v4(),
      teamId: teamId,
      firstName: firstName.trim(),
      lastName: lastName.trim(),
      number: number,
      position: position,
      source: DataSource.manual,
      createdAt: DateTime.now(),
    ));
    notifyListeners();
  }

  Future<void> updatePlayer(Player player) async {
    await _repo.upsertPlayer(player);
    notifyListeners();
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
  Future<void> addEvent({
    required String matchId,
    required String teamId,
    required int minute,
    required MatchEventType type,
    String? playerId,
    String? assistPlayerId,
    String? note,
  }) async {
    await _repo.upsertEvent(MatchEvent(
      id: _uuid.v4(),
      matchId: matchId,
      teamId: teamId,
      minute: minute,
      type: type,
      playerId: playerId,
      assistPlayerId: assistPlayerId,
      note: note,
      createdAt: DateTime.now(),
    ));
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
    await _recomputeScore(matchId);
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
