import 'fupa_dtos.dart';

/// Austauschbare Datenquelle für FuPa-Stammdaten.
///
/// Implementierungen dürfen Daten ausschließlich über offiziell erlaubte
/// Zugänge beschaffen. Die FuPa-Widgets dürfen NICHT ohne Berechtigung als
/// versteckte Daten-API missbraucht werden – steht kein genehmigter Zugang
/// bereit, meldet die Quelle das über [checkAvailability] und überlässt die
/// Datenpflege der manuellen Übernahme.
abstract class FupaDataSource {
  /// Stabiler technischer Bezeichner.
  String get id;

  /// Für die UI lesbarer Name der Quelle.
  String get label;

  /// Prüft, ob die Quelle gerade automatisch importieren darf/kann.
  Future<SourceAvailability> checkAvailability();

  /// Lädt Mannschafts-Stammdaten inkl. Kader.
  Future<TeamData> fetchTeam(FupaTeamRef ref);

  /// Lädt den Spielplan der Mannschaft.
  Future<List<ScheduledMatchData>> fetchSchedule(FupaTeamRef ref);

  /// Lädt den Kader eines Gegners anhand des Spielplan-Eintrags.
  Future<TeamData> fetchOpponent(ScheduledMatchData match);
}

/// Wird geworfen, wenn eine automatische Quelle (noch) nicht autorisiert ist.
class SourceNotAuthorized implements Exception {
  final String message;
  SourceNotAuthorized(this.message);
  @override
  String toString() => message;
}
