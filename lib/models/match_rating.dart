/// Bewertung eines ganzen Spiels durch EINEN Benutzer: eine Gesamtnote (1–5,
/// optional) und/oder die Angabe „war nicht da / bewerte nicht" ([abstained]).
/// Pro (Spiel, Benutzer) genau eine Zeile.
class MatchRating {
  final String id;
  final String matchId;
  final String? userId;

  /// Spiel-Gesamtnote (1.0 … 5.0) oder null, wenn keine abgegeben.
  final double? rating;

  /// true = der Benutzer war nicht da / bewertet dieses Spiel nicht.
  final bool abstained;

  final String? note;
  final DateTime createdAt;

  const MatchRating({
    required this.id,
    required this.matchId,
    this.userId,
    this.rating,
    this.abstained = false,
    this.note,
    required this.createdAt,
  });

  MatchRating copyWith({
    double? rating,
    bool clearRating = false,
    bool? abstained,
    String? note,
    String? userId,
  }) =>
      MatchRating(
        id: id,
        matchId: matchId,
        userId: userId ?? this.userId,
        rating: clearRating ? null : (rating ?? this.rating),
        abstained: abstained ?? this.abstained,
        note: note ?? this.note,
        createdAt: createdAt,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'match_id': matchId,
        'user_id': userId,
        'rating': rating,
        'abstained': abstained ? 1 : 0,
        'note': note,
        'created_at': createdAt.toIso8601String(),
      };

  factory MatchRating.fromMap(Map<String, Object?> m) => MatchRating(
        id: m['id'] as String,
        matchId: m['match_id'] as String,
        userId: m['user_id'] as String?,
        rating: (m['rating'] as num?)?.toDouble(),
        abstained: m['abstained'] == true || m['abstained'] == 1,
        note: m['note'] as String?,
        createdAt: DateTime.tryParse(m['created_at'] as String? ?? '') ??
            DateTime.now(),
      );
}
