import '../data/coach_repository.dart';
import '../models/enums.dart';
import '../models/match.dart';
import '../models/team.dart';
import 'fupa/fupa_dtos.dart';
import 'fupa/fupa_persistence.dart';
import 'fupa/fupa_redux_importer.dart';

/// Kümmert sich um den Gegnerkader eines Spiels.
///
/// Beim Öffnen eines Spiels prüft der Service, ob der Gegner bereits importiert
/// wurde. Falls nicht und im Spielplan ein FuPa-Teamlink des Gegners vorliegt,
/// wird dessen Kader (inkl. Name/Logo) über denselben REDUX-Import geladen wie
/// beim eigenen Team. Ohne Link wird ein Gegner-Platzhalter angelegt und ein
/// klarer Status zurückgegeben; die manuelle Übernahme bleibt möglich.
/// Mehrfaches Synchronisieren erzeugt keine Dubletten.
class OpponentSyncService {
  OpponentSyncService({
    required CoachRepository repository,
    FupaReduxImporter? importer,
  })  : _repo = repository,
        _persist = FupaPersistence(repository),
        _importer = importer ?? FupaReduxImporter();

  final CoachRepository _repo;
  final FupaPersistence _persist;
  final FupaReduxImporter _importer;

  Future<ImportResult> ensureOpponentForMatch(GameMatch match,
      {bool force = false}) async {
    if (!force && match.opponentImported && match.opponentTeamId != null) {
      final team = await _repo.getTeam(match.opponentTeamId!);
      return ImportResult(
        status: ImportStatus.alreadyPresent,
        message:
            'Gegnerkader „${team?.name ?? match.opponentName}“ ist bereits vorhanden.',
      );
    }

    final url = match.opponentFupaUrl;
    if (url != null && url.isNotEmpty) {
      try {
        final data = await _importer.importTeam(url);
        final team = await _persist.ensureOpponentTeam(
          name: data.name ?? match.opponentName,
          fupaRef: _slug(url),
          source: DataSource.fupaApproved,
        );
        // Vereinsdaten (Kurzname/Logo/Link) nachtragen.
        await _repo.upsertTeam(team.copyWith(
          shortName: data.shortName,
          logoPath: data.logoDataUrl ?? match.opponentLogoPath,
          fupaUrl: url,
          lastSyncedAt: DateTime.now(),
        ));
        final players = data.players
            .map((p) => PlayerData(
                  firstName: p.firstName,
                  lastName: p.lastName,
                  number: p.number,
                  position: p.position,
                ))
            .toList();
        final added = await _persist.syncPlayers(
            team.id, players, DataSource.fupaApproved);
        await _repo.upsertMatch(match.copyWith(
          opponentTeamId: team.id,
          opponentImported: true,
        ));
        return ImportResult(
          status: ImportStatus.success,
          message:
              'Gegnerkader „${data.name ?? team.name}“ importiert: ${players.length} Spieler ($added neu).',
          importedPlayers: players.length,
        );
      } catch (e) {
        final team = await _ensurePlaceholder(match);
        return ImportResult(
          status: ImportStatus.error,
          message:
              'Gegner „${team.name}“ angelegt – automatischer Import fehlgeschlagen: $e.',
        );
      }
    }

    // Kein Gegner-Link: Platzhalter anlegen, manuell weiter.
    final team = await _ensurePlaceholder(match);
    return ImportResult(
      status: ImportStatus.manualRequired,
      message:
          'Kein FuPa-Link für den Gegner hinterlegt. „${team.name}“ wurde angelegt – '
          'Kader bitte manuell ergänzen (oder Spielplan aus FuPa importieren).',
    );
  }

  Future<Team> _ensurePlaceholder(GameMatch match) async {
    final team = await _persist.ensureOpponentTeam(
      name: match.opponentName,
      fupaRef: match.externalId,
    );
    final withLogo = match.opponentLogoPath != null
        ? team.copyWith(logoPath: match.opponentLogoPath)
        : team;
    if (match.opponentLogoPath != null) await _repo.upsertTeam(withLogo);
    await _repo.upsertMatch(match.copyWith(opponentTeamId: withLogo.id));
    return withLogo;
  }

  String _slug(String url) {
    final m = RegExp(r'/team/([^/?#]+)', caseSensitive: false).firstMatch(url);
    return (m?.group(1) ?? '').toLowerCase();
  }
}
