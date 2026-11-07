/// Ein Sponsor des Vereins für die Startelf-Grafik. [logo] ist eine Base64-
/// Data-URL (wie die Vereinslogos). [isMain] = Haupt-Sponsor („Präsentiert
/// von …"); davon gibt es höchstens einen. [sortOrder] steuert die Reihenfolge
/// in der Logo-Leiste. [enabled] = aktiv; deaktivierte Sponsoren erscheinen auf
/// keiner Grafik, bleiben aber in der Verwaltung erhalten. [chip] = Feld hinter
/// dem Logo auf Grafiken: 'auto' (hell/dunkel nach Kontrast), 'white', 'dark'
/// oder 'none' (ohne Feld).
class Sponsor {
  final String id;
  final String name;
  final String? logo;
  final bool isMain;
  final int sortOrder;
  final bool enabled;
  final String chip;

  const Sponsor({
    required this.id,
    required this.name,
    this.logo,
    this.isMain = false,
    this.sortOrder = 0,
    this.enabled = true,
    this.chip = 'auto',
  });

  Sponsor copyWith({
    String? name,
    String? logo,
    bool? isMain,
    int? sortOrder,
    bool? enabled,
    String? chip,
  }) => Sponsor(
    id: id,
    name: name ?? this.name,
    logo: logo ?? this.logo,
    isMain: isMain ?? this.isMain,
    sortOrder: sortOrder ?? this.sortOrder,
    enabled: enabled ?? this.enabled,
    chip: chip ?? this.chip,
  );

  Map<String, Object?> toMap() => {
    'id': id,
    'name': name,
    'logo': logo,
    'is_main': isMain ? 1 : 0,
    'sort_order': sortOrder,
    'enabled': enabled ? 1 : 0,
    'chip': chip,
  };

  // is_main/enabled kommen lokal als int (0/1), aus der Cloud als bool – beides
  // lesen. Fehlt enabled (alte Zeile/Cloud ohne Spalte), gilt der Sponsor als aktiv.
  factory Sponsor.fromMap(Map<String, Object?> m) => Sponsor(
    id: m['id'] as String,
    name: m['name'] as String? ?? '',
    logo: m['logo'] as String?,
    isMain: m['is_main'] == true || m['is_main'] == 1,
    sortOrder: (m['sort_order'] as num?)?.toInt() ?? 0,
    enabled: m['enabled'] == null || m['enabled'] == true || m['enabled'] == 1,
    chip: kSponsorChips.contains(m['chip']) ? m['chip'] as String : 'auto',
  );
}

/// Erlaubte Werte für [Sponsor.chip].
const kSponsorChips = ['auto', 'white', 'dark', 'none'];
