import 'dart:convert';

import '../services/material_duty.dart';

/// Einstellungen des Ball-/Materialdienstes je Team. Wird als JSON in der
/// Settings-Tabelle abgelegt (Schlüssel `material_duty_<teamId>`).
class MaterialDutyConfig {
  /// Beginn der Rotation (Woche, in der Gruppe 1 dran ist).
  final DateTime rotationStart;

  /// Zeitraum des Wochenplans.
  final DateTime printFrom;
  final DateTime printTo;

  /// Regeln/Zuständigkeiten als Freitext.
  final String rules;

  /// Manuelle Zuteilungen (Spieler → feste Gruppe).
  final List<DutyOverride> overrides;

  const MaterialDutyConfig({
    required this.rotationStart,
    required this.printFrom,
    required this.printTo,
    this.rules = '',
    this.overrides = const [],
  });

  factory MaterialDutyConfig.initial() {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    return MaterialDutyConfig(
      rotationStart: start,
      printFrom: start,
      printTo: DateTime(start.year, start.month + 6, start.day),
    );
  }

  MaterialDutyConfig copyWith({
    DateTime? rotationStart,
    DateTime? printFrom,
    DateTime? printTo,
    String? rules,
    List<DutyOverride>? overrides,
  }) =>
      MaterialDutyConfig(
        rotationStart: rotationStart ?? this.rotationStart,
        printFrom: printFrom ?? this.printFrom,
        printTo: printTo ?? this.printTo,
        rules: rules ?? this.rules,
        overrides: overrides ?? this.overrides,
      );

  static String _d(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Map<String, Object?> toJson() => {
        'rotationStart': _d(rotationStart),
        'printFrom': _d(printFrom),
        'printTo': _d(printTo),
        'rules': rules,
        'overrides': overrides
            .map((o) => {'playerId': o.playerId, 'groupIndex': o.groupIndex})
            .toList(),
      };

  String encode() => jsonEncode(toJson());

  factory MaterialDutyConfig.fromJson(Map<String, Object?> m) {
    final init = MaterialDutyConfig.initial();
    DateTime parse(Object? v, DateTime fallback) =>
        DateTime.tryParse(v as String? ?? '') ?? fallback;
    final rawOv = (m['overrides'] as List?) ?? const [];
    return MaterialDutyConfig(
      rotationStart: parse(m['rotationStart'], init.rotationStart),
      printFrom: parse(m['printFrom'], init.printFrom),
      printTo: parse(m['printTo'], init.printTo),
      rules: m['rules'] as String? ?? '',
      overrides: [
        for (final o in rawOv)
          if (o is Map && o['playerId'] != null)
            DutyOverride(
                o['playerId'] as String, (o['groupIndex'] as num).toInt()),
      ],
    );
  }

  static MaterialDutyConfig decode(String? s) {
    if (s == null || s.isEmpty) return MaterialDutyConfig.initial();
    try {
      return MaterialDutyConfig.fromJson(jsonDecode(s) as Map<String, Object?>);
    } catch (_) {
      return MaterialDutyConfig.initial();
    }
  }
}
