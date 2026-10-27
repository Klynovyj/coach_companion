/// Bewertung eines Spielers für ein konkretes Spiel (1–5 Sterne, höher =
/// besser). Der Gesamtschnitt eines Spielers ergibt sich als Durchschnitt.
class PlayerRating {
  final String id;
  final String matchId;
  final String playerId;

  /// Benutzer, der bewertet hat (jeder bewertet eigenständig). Null = Altbestand.
  final String? userId;

  /// Sterne (1.0 … 5.0, höher = besser).
  final double rating;

  final String? note;
  final DateTime createdAt;

  const PlayerRating({
    required this.id,
    required this.matchId,
    required this.playerId,
    this.userId,
    required this.rating,
    this.note,
    required this.createdAt,
  });

  PlayerRating copyWith({double? rating, String? note, String? userId}) =>
      PlayerRating(
        id: id,
        matchId: matchId,
        playerId: playerId,
        userId: userId ?? this.userId,
        rating: rating ?? this.rating,
        note: note ?? this.note,
        createdAt: createdAt,
      );

  Map<String, Object?> toMap() => {
    'id': id,
    'match_id': matchId,
    'player_id': playerId,
    'user_id': userId,
    'rating': rating,
    'note': note,
    'created_at': createdAt.toIso8601String(),
  };

  factory PlayerRating.fromMap(Map<String, Object?> m) => PlayerRating(
    id: m['id'] as String,
    matchId: m['match_id'] as String,
    playerId: m['player_id'] as String,
    userId: m['user_id'] as String?,
    rating: (m['rating'] as num?)?.toDouble() ?? 3.0,
    note: m['note'] as String?,
    createdAt:
        DateTime.tryParse(m['created_at'] as String? ?? '') ?? DateTime.now(),
  );
}
