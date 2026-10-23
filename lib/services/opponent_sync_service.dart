import '../data/coach_repository.dart';
import '../models/enums.dart';
import '../models/match.dart';
import 'fupa/fupa_data_source.dart';
import 'fupa/fupa_dtos.dart';
import 'fupa/fupa_persistence.dart';
import 'fupa/fupa_source_registry.dart';

/// Kümmert sich um den Gegnerkader eines Spiels.
///
/// Beim Öffnen eines Spiels prüft der Service, ob der Gegner bereits importiert
/// wurde. Falls nicht, löst er – sofern ein genehmigter Zugang verfügbar ist –
/// den erlaubten Datenimport aus. Andernfalls wird ein Gegner-Platzhalter
/// angelegt und ein klarer Status zurückgegeben; die manuelle Übernahme bleibt
/// jederzeit möglich. Mehrfaches Synchronisieren erzeugt keine Dubletten.
class OpponentSyncService {
  OpponentSyncService({
    required CoachRepository repository,
    required FupaSourceRegistry registry,
  })  : _repo = repository,
        _registry = registry,
        _persist = FupaPersistence(repository);

  final CoachRepository _repo;
  final FupaSourceRegistry _registry;
  final FupaPersistence _persist;

  /// Wird beim Öffnen eines Spiels aufgerufen.
  Future<ImportResult> ensureOpponentForMatch(GameMatch match,
      {bool force = false}) async {
    // Bereits importiert und verknüpft -> nichts tun (kein Duplikat).
    if (!force &&
        match.opponentImported &&
        match.opponentTeamId != null) {
      final team = await _repo.getTeam(match.opponentTeamId!);
      return ImportResult(
        status: ImportStatus.alreadyPresent,
        message: 'Gegnerkader „${team?.name ?? match.opponentName}“ ist bereits vorhanden.',
      );
    }

    final source = await _registry.firstAutomatic();
    if (source == null) {
      // Kein genehmigter Import: Platzhalter-Gegner sicherstellen + verknüpfen.
      final team = await _persist.ensureOpponentTeam(
        name: match.opponentName,
        fupaRef: _refFromMatch(match),
      );
      await _repo.upsertMatch(match.copyWith(opponentTeamId: team.id));
      return ImportResult(
        status: ImportStatus.manualRequired,
        message:
            'Kein genehmigter FuPa-Import aktiv. Gegner „${team.name}“ wurde angelegt – '
            'Kader bitte manuell ergänzen.',
      );
    }

    try {
      final data = await source.fetchOpponent(ScheduledMatchData(
        opponentName: match.opponentName,
        opponentRef: _refFromMatch(match),
      ));
      final team = await _persist.ensureOpponentTeam(
        name: data.name,
        fupaRef: data.fupaRef ?? _refFromMatch(match),
        source: DataSource.fupaApproved,
      );
      final added =
          await _persist.syncPlayers(team.id, data.players, DataSource.fupaApproved);
      await _repo.upsertMatch(match.copyWith(
        opponentTeamId: team.id,
        opponentImported: true,
      ));
      await _repo.upsertTeam(
          (await _repo.getTeam(team.id))!.copyWith(lastSyncedAt: DateTime.now()));
      return ImportResult(
        status: ImportStatus.success,
        message:
            'Gegnerkader „${team.name}“ importiert: ${data.players.length} Spieler ($added neu).',
        importedPlayers: data.players.length,
      );
    } on SourceNotAuthorized catch (e) {
      final team = await _persist.ensureOpponentTeam(
        name: match.opponentName,
        fupaRef: _refFromMatch(match),
      );
      await _repo.upsertMatch(match.copyWith(opponentTeamId: team.id));
      return ImportResult(
        status: ImportStatus.notAuthorized,
        message: 'Gegner „${team.name}“ angelegt – Zugang nicht autorisiert: $e.',
      );
    } catch (e) {
      final team = await _persist.ensureOpponentTeam(
        name: match.opponentName,
        fupaRef: _refFromMatch(match),
      );
      await _repo.upsertMatch(match.copyWith(opponentTeamId: team.id));
      return ImportResult(
        status: ImportStatus.error,
        message: 'Gegner „${team.name}“ angelegt – automatischer Import fehlgeschlagen: $e.',
      );
    }
  }

  String? _refFromMatch(GameMatch match) {
    // externalId des Spiels kann als Gegner-Hinweis dienen; sonst null.
    return match.externalId;
  }
}
