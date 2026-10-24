import 'dart:convert';

/// Ein Verantwortlicher einer Aufgabe – entweder ein ausgewählter Spieler/
/// Trainer (mit [playerId]) oder ein manueller Freitext-Name ([playerId] null).
class TodoResponsible {
  final String? playerId;
  final String name;

  const TodoResponsible({this.playerId, required this.name});

  Map<String, Object?> toJson() => {'id': playerId, 'name': name};

  factory TodoResponsible.fromJson(Map<String, Object?> m) => TodoResponsible(
        playerId: m['id'] as String?,
        name: m['name'] as String? ?? '',
      );
}

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

  /// Zugehöriges Thema (null = Schnellaufgabe ohne Thema).
  final String? topicId;

  /// Ein oder mehrere Verantwortliche.
  final List<TodoResponsible> responsible;

  const Todo({
    required this.id,
    required this.text,
    this.done = false,
    required this.createdAt,
    this.dueDate,
    this.completedAt,
    this.archived = false,
    this.topicId,
    this.responsible = const [],
  });

  /// Überfällig = Fälligkeitstag liegt vor heute und noch nicht erledigt.
  bool get isOverdue {
    if (done || dueDate == null) return false;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final due = DateTime(dueDate!.year, dueDate!.month, dueDate!.day);
    return due.isBefore(today);
  }

  /// Kurzer Verantwortlichen-Text, z.B. „Max, Ben".
  String get responsibleLabel => responsible.map((r) => r.name).join(', ');

  Todo copyWith({
    String? text,
    bool? done,
    DateTime? dueDate,
    bool clearDueDate = false,
    DateTime? completedAt,
    bool clearCompletedAt = false,
    bool? archived,
    String? topicId,
    bool clearTopicId = false,
    List<TodoResponsible>? responsible,
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
        topicId: clearTopicId ? null : (topicId ?? this.topicId),
        responsible: responsible ?? this.responsible,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'text': text,
        'done': done ? 1 : 0,
        'created_at': createdAt.toIso8601String(),
        'due_date': dueDate?.toIso8601String(),
        'completed_at': completedAt?.toIso8601String(),
        'archived': archived ? 1 : 0,
        'topic_id': topicId,
        'responsible': responsible.isEmpty
            ? null
            : jsonEncode(responsible.map((r) => r.toJson()).toList()),
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
        topicId: m['topic_id'] as String?,
        responsible: _parseResponsible(m['responsible']),
      );

  static List<TodoResponsible> _parseResponsible(Object? v) {
    final s = v as String?;
    if (s == null || s.isEmpty) return const [];
    try {
      final list = jsonDecode(s) as List;
      return list
          .map((e) => TodoResponsible.fromJson(e as Map<String, Object?>))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static DateTime? _parseDate(Object? v) {
    final s = v as String?;
    if (s == null || s.isEmpty) return null;
    return DateTime.tryParse(s);
  }
}
