import '../../data/coach_repository.dart';
import '../../models/enums.dart';
import 'fupa_data_source.dart';
import 'fupa_dtos.dart';
import 'fupa_link_parser.dart';
import 'fupa_persistence.dart';
import 'fupa_source_registry.dart';

/// Verbindet das eigene Team über einen FuPa-Link und importiert – sofern ein
/// genehmigter Zugang verfügbar ist – Kader und Spielplan. Andernfalls wird das
/// Team als manuell gepflegter Platzhalter angelegt und ein klarer Importstatus
/// zurückgegeben, ohne die übrige App-Funktionalität einzuschränken.
class FupaImportService {
  FupaImportService({
    required CoachRepository repository,
    required FupaSourceRegistry registry,
  })  : _repo = repository,
        _registry = registry,
        _persist = FupaPersistence(repository);

  final CoachRepository _repo;
  final FupaSourceRegistry _registry;
  final FupaPersistence _persist;

  CoachRepository get repository => _repo;

  /// Verarbeitet den eingegebenen Teamlink.
  Future<ImportResult> connectOwnTeam(String url) async {
    final ref = FupaLinkParser.parse(url);
    if (ref == null) {
      return const ImportResult(
        status: ImportStatus.error,
        message:
            'Das ist kein gültiger FuPa-Teamlink. Bitte den Link der Mannschaftsseite einfügen.',
      );
    }

    final source = await _registry.firstAutomatic();
    if (source == null) {
      // Kein genehmigter Import – Team als Platzhalter anlegen, manuell weiter.
      final team = await _persist.persistOwnTeam(
        ref,
        TeamData(name: ref.displayName, fupaRef: ref.ref),
        DataSource.manual,
      );
      return ImportResult(
        status: ImportStatus.manualRequired,
        message:
            'Mannschaft „${team.name}“ verbunden. Es ist kein genehmigter FuPa-Online-Import aktiv – '
            'Kader und Spielplan können jetzt manuell gepflegt werden.',
        teamRef: ref,
      );
    }

    try {
      final teamData = await source.fetchTeam(ref);
      final team = await _persist.persistOwnTeam(
          ref, teamData, DataSource.fupaApproved);

      var newMatches = 0;
      try {
        final schedule = await source.fetchSchedule(ref);
        newMatches = await _persist.syncSchedule(team.id, schedule);
      } catch (_) {
        // Spielplan optional – Kaderimport bleibt gültig.
      }

      return ImportResult(
        status: ImportStatus.success,
        message:
            'Import erfolgreich: ${teamData.players.length} Spieler, $newMatches neue Spiele.',
        teamRef: ref,
        team: teamData,
        importedPlayers: teamData.players.length,
      );
    } on SourceNotAuthorized catch (e) {
      // Trotzdem verbinden, damit manuelle Pflege möglich ist.
      final team = await _persist.persistOwnTeam(
        ref,
        TeamData(name: ref.displayName, fupaRef: ref.ref),
        DataSource.manual,
      );
      return ImportResult(
        status: ImportStatus.notAuthorized,
        message:
            'Mannschaft „${team.name}“ verbunden, aber der Zugang ist nicht autorisiert: $e. '
            'Bitte manuell pflegen.',
        teamRef: ref,
      );
    } catch (e) {
      final team = await _persist.persistOwnTeam(
        ref,
        TeamData(name: ref.displayName, fupaRef: ref.ref),
        DataSource.manual,
      );
      return ImportResult(
        status: ImportStatus.error,
        message:
            'Mannschaft „${team.name}“ verbunden, der automatische Import schlug fehl: $e. '
            'Bitte manuell pflegen.',
        teamRef: ref,
      );
    }
  }

  /// Manuelle Re-Synchronisierung des eigenen Teams.
  Future<ImportResult> resyncOwnTeam() async {
    final team = await _repo.getOwnTeam();
    if (team == null || team.fupaUrl == null) {
      return const ImportResult(
        status: ImportStatus.error,
        message: 'Kein verbundenes Team vorhanden.',
      );
    }
    return connectOwnTeam(team.fupaUrl!);
  }
}
