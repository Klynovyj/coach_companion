import '../../models/enums.dart';

/// Referenz auf eine FuPa-Mannschaft, aus einem Link ermittelt.
class FupaTeamRef {
  /// Ursprünglicher Link, wie eingegeben.
  final String url;

  /// Stabiler Bezeichner (Slug) aus dem Link – Basis für Identifikation/Dedup.
  final String ref;

  /// Aus dem Link abgeleiteter, lesbarer Anzeigename (best effort).
  final String displayName;

  const FupaTeamRef({
    required this.url,
    required this.ref,
    required this.displayName,
  });
}

/// Importierte Stammdaten eines Spielers (quellneutral).
class PlayerData {
  final String firstName;
  final String lastName;
  final int? number;
  final String? position;

  /// Externe ID aus der Quelle (für Duplikaterkennung), falls vorhanden.
  final String? externalId;

  const PlayerData({
    required this.firstName,
    required this.lastName,
    this.number,
    this.position,
    this.externalId,
  });
}

/// Importierte Stammdaten einer Mannschaft inkl. Kader.
class TeamData {
  final String name;
  final String? shortName;
  final String? fupaRef;
  final List<PlayerData> players;

  const TeamData({
    required this.name,
    this.shortName,
    this.fupaRef,
    this.players = const [],
  });
}

/// Ein Spiel aus einem importierten Spielplan (quellneutral).
class ScheduledMatchData {
  final String opponentName;
  final String? opponentRef;

  /// Vollständiger FuPa-Teamlink des Gegners (für späteren Kader-Import).
  final String? opponentFupaUrl;

  /// Basis-URL des Gegner-Logos (ohne Größen-Suffix), vor dem Download.
  final String? opponentLogoUrl;

  /// Gegner-Logo als Data-URL (bereits heruntergeladen), falls verfügbar.
  final String? opponentLogoDataUrl;

  final DateTime? kickoff;
  final Venue venue;
  final String? competition;
  final String? externalId;

  /// true = Spiel ist gespielt (Ergebnis vorhanden).
  final bool finished;
  final int? ownGoals;
  final int? opponentGoals;

  const ScheduledMatchData({
    required this.opponentName,
    this.opponentRef,
    this.opponentFupaUrl,
    this.opponentLogoUrl,
    this.opponentLogoDataUrl,
    this.kickoff,
    this.venue = Venue.home,
    this.competition,
    this.externalId,
    this.finished = false,
    this.ownGoals,
    this.opponentGoals,
  });

  ScheduledMatchData withLogo(String? dataUrl) => ScheduledMatchData(
        opponentName: opponentName,
        opponentRef: opponentRef,
        opponentFupaUrl: opponentFupaUrl,
        opponentLogoUrl: opponentLogoUrl,
        opponentLogoDataUrl: dataUrl,
        kickoff: kickoff,
        venue: venue,
        competition: competition,
        externalId: externalId,
        finished: finished,
        ownGoals: ownGoals,
        opponentGoals: opponentGoals,
      );
}

/// Verfügbarkeit einer Datenquelle zum aktuellen Zeitpunkt.
class SourceAvailability {
  /// true = kann jetzt automatisch (online) importieren.
  final bool canAutoImport;

  /// Kurzer, klar verständlicher Status für die UI.
  final String message;

  const SourceAvailability(this.canAutoImport, this.message);

  const SourceAvailability.unavailable(String message)
      : this(false, message);
  const SourceAvailability.ready(String message) : this(true, message);
}

/// Ergebnis eines Import-/Sync-Vorgangs.
class ImportResult {
  final ImportStatus status;
  final String message;

  /// Ermittelte Team-Referenz (auch bei manualRequired gesetzt, damit die
  /// UI direkt mit der manuellen Pflege fortfahren kann).
  final FupaTeamRef? teamRef;

  final TeamData? team;
  final List<ScheduledMatchData> schedule;

  /// Anzahl neu übernommener Spieler (0 bei reinem Dedup).
  final int importedPlayers;

  const ImportResult({
    required this.status,
    required this.message,
    this.teamRef,
    this.team,
    this.schedule = const [],
    this.importedPlayers = 0,
  });

  bool get isSuccess => status == ImportStatus.success;
  bool get needsManual => status == ImportStatus.manualRequired;
}
