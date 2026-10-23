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

  /// Gruppe (0-basiert), die in der Start-Woche (rotationStart) dran ist –
  /// damit sich eine bereits laufende Rotation deklarieren lässt.
  final int startGroupIndex;

  /// Regeln/Zuständigkeiten als Freitext.
  final String rules;

  /// Manuelle Zuteilungen (Spieler → feste Gruppe).
  final List<DutyOverride> overrides;

  /// Zusätzlich für eine bestimmte Woche eingeteilte Spieler (z.B. als Strafe).
  /// Schlüssel = Montag der Woche als „YYYY-MM-DD", Wert = Spieler-IDs.
  final Map<String, List<String>> extras;

  const MaterialDutyConfig({
    required this.rotationStart,
    required this.printFrom,
    required this.printTo,
    this.startGroupIndex = 0,
    this.rules = '',
    this.overrides = const [],
    this.extras = const {},
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
    int? startGroupIndex,
    String? rules,
    List<DutyOverride>? overrides,
    Map<String, List<String>>? extras,
  }) =>
      MaterialDutyConfig(
        rotationStart: rotationStart ?? this.rotationStart,
        printFrom: printFrom ?? this.printFrom,
        printTo: printTo ?? this.printTo,
        startGroupIndex: startGroupIndex ?? this.startGroupIndex,
        rules: rules ?? this.rules,
        overrides: overrides ?? this.overrides,
        extras: extras ?? this.extras,
      );

  static String _d(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Map<String, Object?> toJson() => {
        'rotationStart': _d(rotationStart),
        'printFrom': _d(printFrom),
        'printTo': _d(printTo),
        'startGroupIndex': startGroupIndex,
        'rules': rules,
        'overrides': overrides
            .map((o) => {'playerId': o.playerId, 'groupIndex': o.groupIndex})
            .toList(),
        'extras': extras,
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
      startGroupIndex: (m['startGroupIndex'] as num?)?.toInt() ?? 0,
      rules: m['rules'] as String? ?? '',
      overrides: [
        for (final o in rawOv)
          if (o is Map && o['playerId'] != null)
            DutyOverride(
                o['playerId'] as String, (o['groupIndex'] as num).toInt()),
      ],
      extras: {
        for (final e in ((m['extras'] as Map?) ?? const {}).entries)
          e.key.toString(): [
            for (final v in (e.value as List? ?? const []))
              v.toString(),
          ],
      },
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
