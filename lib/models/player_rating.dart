/// Bewertung eines Spielers für ein konkretes Spiel (Schulnoten-Logik 1–6).
class PlayerRating {
  final String id;
  final String matchId;
  final String playerId;

  /// Note (1.0 = sehr gut … 6.0 = ungenügend). Frei wählbar.
  final double rating;

  final String? note;
  final DateTime createdAt;

  const PlayerRating({
    required this.id,
    required this.matchId,
    required this.playerId,
    required this.rating,
    this.note,
    required this.createdAt,
  });

  PlayerRating copyWith({double? rating, String? note}) => PlayerRating(
        id: id,
        matchId: matchId,
        playerId: playerId,
        rating: rating ?? this.rating,
        note: note ?? this.note,
        createdAt: createdAt,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'match_id': matchId,
        'player_id': playerId,
        'rating': rating,
        'note': note,
        'created_at': createdAt.toIso8601String(),
      };

  factory PlayerRating.fromMap(Map<String, Object?> m) => PlayerRating(
        id: m['id'] as String,
        matchId: m['match_id'] as String,
        playerId: m['player_id'] as String,
        rating: (m['rating'] as num?)?.toDouble() ?? 3.0,
        note: m['note'] as String?,
        createdAt:
            DateTime.tryParse(m['created_at'] as String? ?? '') ??
                DateTime.now(),
      );
}
