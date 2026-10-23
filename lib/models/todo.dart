/// Eine eigene Aufgabe/Merker für die „Nachholen"-Liste.
class Todo {
  final String id;
  final String text;
  final bool done;
  final DateTime createdAt;

  /// Optionales Fälligkeitsdatum.
  final DateTime? dueDate;

  /// Zeitpunkt, an dem die Aufgabe abgehakt wurde (null, solange offen).
  final DateTime? completedAt;

  /// Archiviert = aus der aktiven Liste genommen (bleibt im Archiv erhalten).
  final bool archived;

  const Todo({
    required this.id,
    required this.text,
    this.done = false,
    required this.createdAt,
    this.dueDate,
    this.completedAt,
    this.archived = false,
  });

  /// Überfällig = Fälligkeitstag liegt vor heute und noch nicht erledigt.
  bool get isOverdue {
    if (done || dueDate == null) return false;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final due = DateTime(dueDate!.year, dueDate!.month, dueDate!.day);
    return due.isBefore(today);
  }

  Todo copyWith({
    String? text,
    bool? done,
    DateTime? dueDate,
    bool clearDueDate = false,
    DateTime? completedAt,
    bool clearCompletedAt = false,
    bool? archived,
  }) =>
      Todo(
        id: id,
        text: text ?? this.text,
        done: done ?? this.done,
        createdAt: createdAt,
        dueDate: clearDueDate ? null : (dueDate ?? this.dueDate),
        completedAt:
            clearCompletedAt ? null : (completedAt ?? this.completedAt),
        archived: archived ?? this.archived,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'text': text,
        'done': done ? 1 : 0,
        'created_at': createdAt.toIso8601String(),
        'due_date': dueDate?.toIso8601String(),
        'completed_at': completedAt?.toIso8601String(),
        'archived': archived ? 1 : 0,
      };

  factory Todo.fromMap(Map<String, Object?> m) => Todo(
        id: m['id'] as String,
        text: m['text'] as String? ?? '',
        done: (m['done'] as int? ?? 0) == 1,
        createdAt:
            DateTime.tryParse(m['created_at'] as String? ?? '') ??
                DateTime.now(),
        dueDate: _parseDate(m['due_date']),
        completedAt: _parseDate(m['completed_at']),
        archived: (m['archived'] as int? ?? 0) == 1,
      );

  static DateTime? _parseDate(Object? v) {
    final s = v as String?;
    if (s == null || s.isEmpty) return null;
    return DateTime.tryParse(s);
  }
}
