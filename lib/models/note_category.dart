/// Eine Rubrik (Kategorie) für Spieler-Notizen. Zentral in den Einstellungen
/// gepflegt und keiner Mannschaft zugeordnet – gilt app-weit.
class NoteCategory {
  final String id;
  final String name;

  /// Sortierreihenfolge in Listen (kleiner = weiter oben).
  final int sortOrder;

  const NoteCategory({
    required this.id,
    required this.name,
    this.sortOrder = 0,
  });

  NoteCategory copyWith({String? name, int? sortOrder}) => NoteCategory(
    id: id,
    name: name ?? this.name,
    sortOrder: sortOrder ?? this.sortOrder,
  );

  Map<String, Object?> toMap() => {
    'id': id,
    'name': name,
    'sort_order': sortOrder,
  };

  factory NoteCategory.fromMap(Map<String, Object?> m) => NoteCategory(
    id: m['id'] as String,
    name: m['name'] as String? ?? '',
    sortOrder: m['sort_order'] as int? ?? 0,
  );
}
