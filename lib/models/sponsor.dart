/// Ein Sponsor des Vereins für die Startelf-Grafik. [logo] ist eine Base64-
/// Data-URL (wie die Vereinslogos). [isMain] = Haupt-Sponsor („Präsentiert
/// von …"); davon gibt es höchstens einen. [sortOrder] steuert die Reihenfolge
/// in der Logo-Leiste.
class Sponsor {
  final String id;
  final String name;
  final String? logo;
  final bool isMain;
  final int sortOrder;

  const Sponsor({
    required this.id,
    required this.name,
    this.logo,
    this.isMain = false,
    this.sortOrder = 0,
  });

  Sponsor copyWith({
    String? name,
    String? logo,
    bool? isMain,
    int? sortOrder,
  }) =>
      Sponsor(
        id: id,
        name: name ?? this.name,
        logo: logo ?? this.logo,
        isMain: isMain ?? this.isMain,
        sortOrder: sortOrder ?? this.sortOrder,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'logo': logo,
        'is_main': isMain ? 1 : 0,
        'sort_order': sortOrder,
      };

  // is_main kommt lokal als int (0/1), aus der Cloud als bool – beides lesen.
  factory Sponsor.fromMap(Map<String, Object?> m) => Sponsor(
        id: m['id'] as String,
        name: m['name'] as String? ?? '',
        logo: m['logo'] as String?,
        isMain: m['is_main'] == true || m['is_main'] == 1,
        sortOrder: (m['sort_order'] as num?)?.toInt() ?? 0,
      );
}
