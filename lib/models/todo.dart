/// Eine eigene Aufgabe/Merker für die „Nachholen"-Liste.
class Todo {
  final String id;
  final String text;
  final bool done;
  final DateTime createdAt;

  const Todo({
    required this.id,
    required this.text,
    this.done = false,
    required this.createdAt,
  });

  Todo copyWith({String? text, bool? done}) => Todo(
        id: id,
        text: text ?? this.text,
        done: done ?? this.done,
        createdAt: createdAt,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'text': text,
        'done': done ? 1 : 0,
        'created_at': createdAt.toIso8601String(),
      };

  factory Todo.fromMap(Map<String, Object?> m) => Todo(
        id: m['id'] as String,
        text: m['text'] as String? ?? '',
        done: (m['done'] as int? ?? 0) == 1,
        createdAt:
            DateTime.tryParse(m['created_at'] as String? ?? '') ??
                DateTime.now(),
      );
}
