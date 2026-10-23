import 'enums.dart';

/// Ein Spiel aus dem Spielplan des eigenen Teams.
class GameMatch {
  final String id;
  final String ownTeamId;

  /// Gegner-Team-ID, sobald der Gegnerkader importiert/angelegt wurde.
  final String? opponentTeamId;

  /// Gegnername aus dem Spielplan – immer gesetzt, auch ohne importierten Kader.
  final String opponentName;

  /// FuPa-Teamlink des Gegners (aus dem Spielplan), für den Kader-Auto-Import.
  final String? opponentFupaUrl;

  /// Gegner-Logo als Data-URL (aus dem Spielplan), für die Anzeige.
  final String? opponentLogoPath;

  final DateTime? kickoff;
  final Venue venue;
  final String? competition;

  /// Spieltag-Nummer (aus FuPa `round.number`), falls bekannt.
  final int? matchday;

  /// Externer Bezeichner des Spiels aus der Importquelle.
  final String? externalId;

  final MatchStatus status;

  /// Endstand/Live-Stand – aus Tor-Ereignissen abgeleitet und hier
  /// gecached, damit Listen ohne Event-Join den Stand zeigen können.
  final int ownScore;
  final int opponentScore;

  /// true = Gegnerkader wurde bereits synchronisiert/angelegt.
  final bool opponentImported;

  final DateTime createdAt;

  const GameMatch({
    required this.id,
    required this.ownTeamId,
    this.opponentTeamId,
    required this.opponentName,
    this.opponentFupaUrl,
    this.opponentLogoPath,
    this.kickoff,
    this.venue = Venue.home,
    this.competition,
    this.matchday,
    this.externalId,
    this.status = MatchStatus.scheduled,
    this.ownScore = 0,
    this.opponentScore = 0,
    this.opponentImported = false,
    required this.createdAt,
  });

  GameMatch copyWith({
    String? opponentTeamId,
    String? opponentName,
    String? opponentFupaUrl,
    String? opponentLogoPath,
    DateTime? kickoff,
    Venue? venue,
    String? competition,
    int? matchday,
    String? externalId,
    MatchStatus? status,
    int? ownScore,
    int? opponentScore,
    bool? opponentImported,
  }) {
    return GameMatch(
      id: id,
      ownTeamId: ownTeamId,
      opponentTeamId: opponentTeamId ?? this.opponentTeamId,
      opponentName: opponentName ?? this.opponentName,
      opponentFupaUrl: opponentFupaUrl ?? this.opponentFupaUrl,
      opponentLogoPath: opponentLogoPath ?? this.opponentLogoPath,
      kickoff: kickoff ?? this.kickoff,
      venue: venue ?? this.venue,
      competition: competition ?? this.competition,
      matchday: matchday ?? this.matchday,
      externalId: externalId ?? this.externalId,
      status: status ?? this.status,
      ownScore: ownScore ?? this.ownScore,
      opponentScore: opponentScore ?? this.opponentScore,
      opponentImported: opponentImported ?? this.opponentImported,
      createdAt: createdAt,
    );
  }

  Map<String, Object?> toMap() => {
        'id': id,
        'own_team_id': ownTeamId,
        'opponent_team_id': opponentTeamId,
        'opponent_name': opponentName,
        'opponent_fupa_url': opponentFupaUrl,
        'opponent_logo_path': opponentLogoPath,
        'kickoff': kickoff?.toIso8601String(),
        'venue': venue.storageKey,
        'competition': competition,
        'matchday': matchday,
        'external_id': externalId,
        'status': status.storageKey,
        'own_score': ownScore,
        'opponent_score': opponentScore,
        'opponent_imported': opponentImported ? 1 : 0,
        'created_at': createdAt.toIso8601String(),
      };

  factory GameMatch.fromMap(Map<String, Object?> m) => GameMatch(
        id: m['id'] as String,
        ownTeamId: m['own_team_id'] as String,
        opponentTeamId: m['opponent_team_id'] as String?,
        opponentName: m['opponent_name'] as String? ?? 'Gegner',
        opponentFupaUrl: m['opponent_fupa_url'] as String?,
        opponentLogoPath: m['opponent_logo_path'] as String?,
        kickoff: DateTime.tryParse(m['kickoff'] as String? ?? ''),
        venue: Venue.fromKey(m['venue'] as String?),
        competition: m['competition'] as String?,
        matchday: m['matchday'] as int?,
        externalId: m['external_id'] as String?,
        status: MatchStatus.fromKey(m['status'] as String?),
        ownScore: m['own_score'] as int? ?? 0,
        opponentScore: m['opponent_score'] as int? ?? 0,
        opponentImported: (m['opponent_imported'] as int? ?? 0) == 1,
        createdAt:
            DateTime.tryParse(m['created_at'] as String? ?? '') ??
                DateTime.now(),
      );
}
