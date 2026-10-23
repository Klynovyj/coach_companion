import 'fupa_data_source.dart';
import 'fupa_dtos.dart';

/// Standard-Datenquelle ohne Online-Zugriff.
///
/// Sie ist immer vorhanden, kann aber bewusst NICHT automatisch importieren:
/// So bleibt die App auch ohne genehmigte FuPa-Schnittstelle voll nutzbar –
/// der Trainer pflegt Kader, Spielplan und Gegner manuell. Diese Quelle ruft
/// keinerlei FuPa-Inhalte ab.
class ManualFupaDataSource implements FupaDataSource {
  @override
  String get id => 'manual';

  @override
  String get label => 'Manuelle Eingabe';

  @override
  Future<SourceAvailability> checkAvailability() async {
    return const SourceAvailability.unavailable(
      'Kein genehmigter FuPa-Online-Import aktiv – Daten werden manuell gepflegt.',
    );
  }

  @override
  Future<TeamData> fetchTeam(FupaTeamRef ref) {
    throw UnsupportedError('Manuelle Quelle importiert nicht automatisch.');
  }

  @override
  Future<List<ScheduledMatchData>> fetchSchedule(FupaTeamRef ref) {
    throw UnsupportedError('Manuelle Quelle importiert nicht automatisch.');
  }

  @override
  Future<TeamData> fetchOpponent(ScheduledMatchData match) {
    throw UnsupportedError('Manuelle Quelle importiert nicht automatisch.');
  }
}
