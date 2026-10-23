/// Saison-Statistik eines Spielers (aus FuPa `/playerstats`).
///
/// Wird pro Team gespeichert und beim Import ersetzt. Die Verknüpfung zum
/// Kader-Spieler erfolgt locker über den Namen; die Statistik steht aber auch
/// ohne passenden Kadereintrag für sich.
class PlayerStat {
  final String id;
  final String teamId;

  /// Externe FuPa-ID/Slug des Spielers (für stabile Zuordnung beim Re-Import).
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

  const PlayerStat({
    required this.id,
    required this.teamId,
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

  String get fullName => [firstName, lastName]
      .where((s) => s.trim().isNotEmpty)
      .join(' ')
      .trim();

  /// Tor-Beteiligungen (Tore + Vorlagen).
  int get scorerPoints => goals + assists;

  Map<String, Object?> toMap() => {
        'id': id,
        'team_id': teamId,
        'external_id': externalId,
        'first_name': firstName,
        'last_name': lastName,
        'matches': matches,
        'goals': goals,
        'assists': assists,
        'yellow_cards': yellowCards,
        'yellow_red_cards': yellowRedCards,
        'red_cards': redCards,
        'minutes': minutes,
        'top_eleven': topEleven,
      };

  factory PlayerStat.fromMap(Map<String, Object?> m) => PlayerStat(
        id: m['id'] as String,
        teamId: m['team_id'] as String,
        externalId: m['external_id'] as String?,
        firstName: m['first_name'] as String? ?? '',
        lastName: m['last_name'] as String? ?? '',
        matches: m['matches'] as int? ?? 0,
        goals: m['goals'] as int? ?? 0,
        assists: m['assists'] as int? ?? 0,
        yellowCards: m['yellow_cards'] as int? ?? 0,
        yellowRedCards: m['yellow_red_cards'] as int? ?? 0,
        redCards: m['red_cards'] as int? ?? 0,
        minutes: m['minutes'] as int? ?? 0,
        topEleven: m['top_eleven'] as int? ?? 0,
      );
}
