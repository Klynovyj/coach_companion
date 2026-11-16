import 'dart:convert';

/// Gespeicherte Baukasten-Statistik (Vorlage): komplette Einstellung als JSON
/// (Thema, Spieler/Gruppen, Spiele-Filter, Kennzahlen, Anzeige …).
/// Team-weit geteilt (Cloud-Tabelle `stat_templates`, lokal ohne team_id).
class StatTemplate {
  const StatTemplate({
    required this.id,
    required this.name,
    required this.config,
    this.createdBy,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final Map<String, dynamic> config;
  final String? createdBy;
  final String updatedAt;

  StatTemplate copyWith({String? name, Map<String, dynamic>? config}) =>
      StatTemplate(
        id: id,
        name: name ?? this.name,
        config: config ?? this.config,
        createdBy: createdBy,
        updatedAt: DateTime.now().toUtc().toIso8601String(),
      );

  Map<String, Object?> toRow() => {
    'id': id,
    'name': name,
    'config': jsonEncode(config),
    'created_by': createdBy,
    'updated_at': updatedAt,
  };

  static StatTemplate? fromRow(Map<String, Object?> r) {
    final id = r['id'] as String?;
    if (id == null) return null;
    var cfg = <String, dynamic>{};
    try {
      final d = jsonDecode((r['config'] as String?) ?? '{}');
      if (d is Map) cfg = Map<String, dynamic>.from(d);
    } catch (_) {}
    return StatTemplate(
      id: id,
      name: (r['name'] as String?) ?? '',
      config: cfg,
      createdBy: r['created_by'] as String?,
      updatedAt: (r['updated_at'] as String?) ?? '',
    );
  }
}
