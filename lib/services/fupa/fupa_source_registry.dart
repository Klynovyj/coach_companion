import 'fupa_data_source.dart';
import 'fupa_dtos.dart';

/// Hält alle verfügbaren Datenquellen in Prioritätsreihenfolge und ermittelt,
/// welche gerade automatisch importieren darf.
class FupaSourceRegistry {
  /// Quellen in Prioritätsreihenfolge (genehmigte zuerst, manuell zuletzt).
  final List<FupaDataSource> sources;

  FupaSourceRegistry(this.sources);

  /// Erste Quelle, die aktuell automatisch importieren kann – sonst null.
  Future<FupaDataSource?> firstAutomatic() async {
    for (final s in sources) {
      final a = await s.checkAvailability();
      if (a.canAutoImport) return s;
    }
    return null;
  }

  /// Status aller Quellen (für die Anzeige in den Einstellungen).
  Future<List<SourceStatus>> statuses() async {
    final out = <SourceStatus>[];
    for (final s in sources) {
      out.add(SourceStatus(s.id, s.label, await s.checkAvailability()));
    }
    return out;
  }
}

class SourceStatus {
  final String id;
  final String label;
  final SourceAvailability availability;
  const SourceStatus(this.id, this.label, this.availability);
}
