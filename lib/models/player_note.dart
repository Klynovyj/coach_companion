/// Eine datierte Notiz zu einem Spieler (Verlauf beliebig vieler Notizen).
class PlayerNote {
  final String id;
  final String playerId;
  final String text;
  final DateTime createdAt;

  /// Zugeordnete Rubrik (optional). Null = „Ohne Rubrik".
  final String? categoryId;

  /// Optional verknüpftes Spiel (z.B. „beim Spiel gegen Post daneben benommen").
  final String? matchId;

  const PlayerNote({
    required this.id,
    required this.playerId,
    required this.text,
    required this.createdAt,
    this.categoryId,
    this.matchId,
  });

  PlayerNote copyWith({
    String? text,
    String? categoryId,
    bool clearCategory = false,
    String? matchId,
    bool clearMatch = false,
  }) =>
      PlayerNote(
        id: id,
        playerId: playerId,
        text: text ?? this.text,
        createdAt: createdAt,
        categoryId: clearCategory ? null : (categoryId ?? this.categoryId),
        matchId: clearMatch ? null : (matchId ?? this.matchId),
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'player_id': playerId,
        'text': text,
        'created_at': createdAt.toIso8601String(),
        'category_id': categoryId,
        'match_id': matchId,
      };

  factory PlayerNote.fromMap(Map<String, Object?> m) => PlayerNote(
        id: m['id'] as String,
        playerId: m['player_id'] as String,
        text: m['text'] as String? ?? '',
        createdAt:
            DateTime.tryParse(m['created_at'] as String? ?? '') ??
                DateTime.now(),
        categoryId: m['category_id'] as String?,
        matchId: m['match_id'] as String?,
      );
}
