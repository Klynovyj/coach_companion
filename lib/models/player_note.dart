/// Eine datierte Notiz zu einem Spieler (Verlauf beliebig vieler Notizen).
class PlayerNote {
  final String id;
  final String playerId;
  final String text;
  final DateTime createdAt;

  const PlayerNote({
    required this.id,
    required this.playerId,
    required this.text,
    required this.createdAt,
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'player_id': playerId,
        'text': text,
        'created_at': createdAt.toIso8601String(),
      };

  factory PlayerNote.fromMap(Map<String, Object?> m) => PlayerNote(
        id: m['id'] as String,
        playerId: m['player_id'] as String,
        text: m['text'] as String? ?? '',
        createdAt:
            DateTime.tryParse(m['created_at'] as String? ?? '') ??
                DateTime.now(),
      );
}
