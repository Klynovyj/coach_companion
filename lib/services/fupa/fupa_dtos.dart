import '../../models/enums.dart';

/// Importierte Stammdaten eines Spielers (quellneutral).
class PlayerData {
  final String firstName;
  final String lastName;
  final int? number;
  final String? position;

  /// Externe ID aus der Quelle (für Duplikaterkennung), falls vorhanden.
  final String? externalId;

  /// Spielerfoto als Data-URL (bereits heruntergeladen), falls verfügbar.
  final String? photoDataUrl;

  const PlayerData({
    required this.firstName,
    required this.lastName,
    this.number,
    this.position,
    this.externalId,
    this.photoDataUrl,
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

/// Saison-Statistik eines Spielers aus FuPa (quellneutral).
class PlayerStatData {
  final String? externalId;
  final String firstName;
  final String lastName;
  final int matches;
  final int goals;
  final int assists;
  final int yellowCards;
  final int yellowRedCards;
  final int redCards;
  final int minutes;
  final int topEleven;

  const PlayerStatData({
    this.externalId,
    required this.firstName,
    required this.lastName,
    this.matches = 0,
    this.goals = 0,
    this.assists = 0,
    this.yellowCards = 0,
    this.yellowRedCards = 0,
    this.redCards = 0,
    this.minutes = 0,
    this.topEleven = 0,
  });
}

/// Ergebnis eines Gegner-Sync-Vorgangs (für Statusmeldungen in der UI).
class ImportResult {
  final ImportStatus status;
  final String message;

  /// Anzahl übernommener Spieler.
  final int importedPlayers;

  const ImportResult({
    required this.status,
    required this.message,
    this.importedPlayers = 0,
  });
}
