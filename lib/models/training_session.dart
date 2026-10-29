import 'dart:convert';

/// Eine geplante Trainingseinheit: Rahmen (Datum, Anzahl Spieler/Torhüter,
/// gewählte Trainingsarten) + Notiz. Die Übungen hängen als [SessionItem] dran.
class TrainingSession {
  final String id;
  final DateTime date;
  final int fieldPlayers;
  final int goalkeepers;
  final List<String> categories;
  final String note;
  final DateTime createdAt;

  /// Archiviert (standardmäßig in der Übersicht ausgeblendet).
  final bool archived;

  const TrainingSession({
    required this.id,
    required this.date,
    this.fieldPlayers = 0,
    this.goalkeepers = 0,
    this.categories = const [],
    this.note = '',
    required this.createdAt,
    this.archived = false,
  });

  TrainingSession copyWith({
    DateTime? date,
    int? fieldPlayers,
    int? goalkeepers,
    List<String>? categories,
    String? note,
    bool? archived,
  }) => TrainingSession(
    id: id,
    date: date ?? this.date,
    fieldPlayers: fieldPlayers ?? this.fieldPlayers,
    goalkeepers: goalkeepers ?? this.goalkeepers,
    categories: categories ?? this.categories,
    note: note ?? this.note,
    createdAt: createdAt,
    archived: archived ?? this.archived,
  );

  int get totalPlayers => fieldPlayers + goalkeepers;

  Map<String, Object?> toMap() => {
    'id': id,
    'date': date.toIso8601String(),
    'field_players': fieldPlayers,
    'goalkeepers': goalkeepers,
    'categories': categories.isEmpty ? null : jsonEncode(categories),
    'note': note,
    'created_at': createdAt.toIso8601String(),
    'archived': archived ? 1 : 0,
  };

  factory TrainingSession.fromMap(Map<String, Object?> m) => TrainingSession(
    id: m['id'] as String,
    date: DateTime.tryParse(m['date'] as String? ?? '') ?? DateTime.now(),
    fieldPlayers: (m['field_players'] as num?)?.toInt() ?? 0,
    goalkeepers: (m['goalkeepers'] as num?)?.toInt() ?? 0,
    categories: _decodeList(m['categories']),
    note: (m['note'] as String?) ?? '',
    createdAt:
        DateTime.tryParse(m['created_at'] as String? ?? '') ?? DateTime.now(),
    archived: m['archived'] == 1 || m['archived'] == true,
  );

  static List<String> _decodeList(Object? v) {
    final s = v as String?;
    if (s == null || s.isEmpty) return const [];
    try {
      return [for (final e in jsonDecode(s) as List) e.toString()];
    } catch (_) {
      return const [];
    }
  }
}

/// Eine Übung innerhalb einer Einheit (Verweis + Reihenfolge + Dauer + Notiz).
class SessionItem {
  final String id;
  final String sessionId;
  final String exerciseId;
  final int orderIndex;
  final int? durationMin;
  final String note;

  const SessionItem({
    required this.id,
    required this.sessionId,
    required this.exerciseId,
    this.orderIndex = 0,
    this.durationMin,
    this.note = '',
  });

  SessionItem copyWith({int? orderIndex, int? durationMin, String? note}) =>
      SessionItem(
        id: id,
        sessionId: sessionId,
        exerciseId: exerciseId,
        orderIndex: orderIndex ?? this.orderIndex,
        durationMin: durationMin ?? this.durationMin,
        note: note ?? this.note,
      );

  Map<String, Object?> toMap() => {
    'id': id,
    'session_id': sessionId,
    'exercise_id': exerciseId,
    'order_index': orderIndex,
    'duration_min': durationMin,
    'note': note,
  };

  factory SessionItem.fromMap(Map<String, Object?> m) => SessionItem(
    id: m['id'] as String,
    sessionId: m['session_id'] as String,
    exerciseId: m['exercise_id'] as String,
    orderIndex: (m['order_index'] as num?)?.toInt() ?? 0,
    durationMin: (m['duration_min'] as num?)?.toInt(),
    note: (m['note'] as String?) ?? '',
  );
}
