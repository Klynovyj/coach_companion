/// Gekürter „Spieler des Monats" (teamweit, genau einer je Monat).
/// [yearMonth] im Format „YYYY-MM".
class PlayerOfMonth {
  final String id;
  final String yearMonth;
  final String playerId;
  final DateTime createdAt;

  const PlayerOfMonth({
    required this.id,
    required this.yearMonth,
    required this.playerId,
    required this.createdAt,
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'year_month': yearMonth,
        'player_id': playerId,
        'created_at': createdAt.toIso8601String(),
      };

  factory PlayerOfMonth.fromMap(Map<String, Object?> m) => PlayerOfMonth(
        id: m['id'] as String,
        yearMonth: m['year_month'] as String? ?? '',
        playerId: m['player_id'] as String? ?? '',
        createdAt: DateTime.tryParse(m['created_at'] as String? ?? '') ??
            DateTime.now(),
      );
}
