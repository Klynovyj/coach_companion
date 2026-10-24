/// Ein Thema (Überschrift) für Aufgaben. Aufgaben werden darunter einsortiert.
class TodoTopic {
  final String id;
  final String title;
  final int sortOrder;
  final DateTime createdAt;

  const TodoTopic({
    required this.id,
    required this.title,
    this.sortOrder = 0,
    required this.createdAt,
  });

  TodoTopic copyWith({String? title, int? sortOrder}) => TodoTopic(
        id: id,
        title: title ?? this.title,
        sortOrder: sortOrder ?? this.sortOrder,
        createdAt: createdAt,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'title': title,
        'sort_order': sortOrder,
        'created_at': createdAt.toIso8601String(),
      };

  factory TodoTopic.fromMap(Map<String, Object?> m) => TodoTopic(
        id: m['id'] as String,
        title: m['title'] as String? ?? '',
        sortOrder: (m['sort_order'] as int?) ?? 0,
        createdAt:
            DateTime.tryParse(m['created_at'] as String? ?? '') ??
                DateTime.now(),
      );
}
