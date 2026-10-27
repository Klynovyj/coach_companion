/// Ein geplantes/erfasstes Spielergespräch (1:1 mit einem Spieler).
class PlayerTalk {
  final String id;
  final String playerId;

  /// Thema des Gesprächs.
  final String title;

  /// Geplanter Zeitpunkt.
  final DateTime scheduledAt;

  /// Notizen zum Gespräch (jederzeit nachtragbar).
  final String? notes;

  /// Gespräch wurde geführt (durchgeführt-Haken).
  final bool done;

  final DateTime createdAt;

  const PlayerTalk({
    required this.id,
    required this.playerId,
    required this.title,
    required this.scheduledAt,
    this.notes,
    this.done = false,
    required this.createdAt,
  });

  PlayerTalk copyWith({
    String? playerId,
    String? title,
    DateTime? scheduledAt,
    String? notes,
    bool clearNotes = false,
    bool? done,
  }) => PlayerTalk(
    id: id,
    playerId: playerId ?? this.playerId,
    title: title ?? this.title,
    scheduledAt: scheduledAt ?? this.scheduledAt,
    notes: clearNotes ? null : (notes ?? this.notes),
    done: done ?? this.done,
    createdAt: createdAt,
  );

  Map<String, Object?> toMap() => {
    'id': id,
    'player_id': playerId,
    'title': title,
    'scheduled_at': scheduledAt.toIso8601String(),
    'notes': notes,
    'done': done ? 1 : 0,
    'created_at': createdAt.toIso8601String(),
  };

  factory PlayerTalk.fromMap(Map<String, Object?> m) => PlayerTalk(
    id: m['id'] as String,
    playerId: m['player_id'] as String,
    title: m['title'] as String? ?? '',
    scheduledAt:
        DateTime.tryParse(m['scheduled_at'] as String? ?? '') ?? DateTime.now(),
    notes: m['notes'] as String?,
    done: (m['done'] as int? ?? 0) == 1,
    createdAt:
        DateTime.tryParse(m['created_at'] as String? ?? '') ?? DateTime.now(),
  );
}
