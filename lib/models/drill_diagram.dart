import 'dart:convert';

/// Ein Element auf der Übungs-Skizze. Koordinaten sind relativ (0..1), damit die
/// Skizze auf jeder Größe passt. [x2]/[y2] nur für Pfeil (Ende) bzw. Zone (zweite
/// Ecke).
class DrillElement {
  /// player | cone | goal | ball | arrow | zone | text
  final String type;
  final double x;
  final double y;
  final double? x2;
  final double? y2;

  /// Optionale Farbe (Hex, z.B. "#1565C0") und Beschriftung.
  final String? color;
  final String? label;

  /// Größenfaktor (1.0 = Standard); null → Standard.
  final double? size;

  const DrillElement({
    required this.type,
    required this.x,
    required this.y,
    this.x2,
    this.y2,
    this.color,
    this.label,
    this.size,
  });

  DrillElement copyWith({
    double? x,
    double? y,
    double? x2,
    double? y2,
    String? color,
    String? label,
    double? size,
  }) => DrillElement(
    type: type,
    x: x ?? this.x,
    y: y ?? this.y,
    x2: x2 ?? this.x2,
    y2: y2 ?? this.y2,
    color: color ?? this.color,
    label: label ?? this.label,
    size: size ?? this.size,
  );

  Map<String, dynamic> toJson() => {
    'type': type,
    'x': x,
    'y': y,
    if (x2 != null) 'x2': x2,
    if (y2 != null) 'y2': y2,
    if (color != null) 'color': color,
    if (label != null) 'label': label,
    if (size != null) 'size': size,
  };

  factory DrillElement.fromJson(Map<String, dynamic> m) => DrillElement(
    type: (m['type'] as String?) ?? 'player',
    x: (m['x'] as num?)?.toDouble() ?? 0.5,
    y: (m['y'] as num?)?.toDouble() ?? 0.5,
    x2: (m['x2'] as num?)?.toDouble(),
    y2: (m['y2'] as num?)?.toDouble(),
    color: m['color'] as String?,
    label: m['label'] as String?,
    size: (m['size'] as num?)?.toDouble(),
  );
}

/// Eine Übungs-Skizze: Feldtyp + Elemente. Wird als JSON in der Übung
/// gespeichert und von einem CustomPainter gezeichnet.
class DrillDiagram {
  /// full | half | box
  final String field;
  final List<DrillElement> elements;

  const DrillDiagram({this.field = 'full', this.elements = const []});

  bool get isEmpty => elements.isEmpty;

  DrillDiagram copyWith({String? field, List<DrillElement>? elements}) =>
      DrillDiagram(
        field: field ?? this.field,
        elements: elements ?? this.elements,
      );

  /// Setzt Punkt-Objekte auf ein sauberes Raster und löst Kollisionen auf,
  /// damit KI-Skizzen nicht „durcheinander" wirken. Pfeile/Zonen bleiben.
  DrillDiagram tidy() {
    const pointTypes = {
      'player',
      'cone',
      'goal',
      'minigoal',
      'ball',
      'text',
    };
    final els = List.of(elements);
    final idx = [
      for (var i = 0; i < els.length; i++)
        if (pointTypes.contains(els[i].type)) i,
    ];
    if (idx.isEmpty) return this;

    const step = 0.11; // Rasterabstand (größer als ein Spieler → kein Überlapp)
    const lo = 0.08;
    final cells = ((1 - 2 * lo) / step).floor();
    int clampCell(int c) => c < 0 ? 0 : (c > cells ? cells : c);
    int keyOf(int c, int r) => r * 1000 + c;

    final occupied = <int>{};
    final px = <int, double>{};
    final py = <int, double>{};
    for (final i in idx) {
      final e = els[i];
      final c0 = clampCell(((e.x - lo) / step).round());
      final r0 = clampCell(((e.y - lo) / step).round());
      var bc = c0, br = r0;
      if (occupied.contains(keyOf(c0, r0))) {
        // Nächste freie Zelle in wachsenden Ringen suchen.
        var found = false;
        for (var rad = 1; rad <= cells && !found; rad++) {
          for (var dc = -rad; dc <= rad && !found; dc++) {
            for (var dr = -rad; dr <= rad && !found; dr++) {
              if (dc.abs() != rad && dr.abs() != rad) continue;
              final c = clampCell(c0 + dc), r = clampCell(r0 + dr);
              if (!occupied.contains(keyOf(c, r))) {
                bc = c;
                br = r;
                found = true;
              }
            }
          }
        }
      }
      occupied.add(keyOf(bc, br));
      px[i] = lo + bc * step;
      py[i] = lo + br * step;
    }
    return DrillDiagram(
      field: field,
      elements: [
        for (var i = 0; i < els.length; i++)
          px.containsKey(i) ? els[i].copyWith(x: px[i], y: py[i]) : els[i],
      ],
    );
  }

  Map<String, dynamic> toJson() => {
    'field': field,
    'elements': [for (final e in elements) e.toJson()],
  };

  factory DrillDiagram.fromJson(Map<String, dynamic> m) => DrillDiagram(
    field: (m['field'] as String?) ?? 'full',
    elements: [
      for (final e in (m['elements'] as List? ?? const []))
        DrillElement.fromJson(Map<String, dynamic>.from(e as Map)),
    ],
  );

  /// Für die DB: als JSON-String (null/leer → null).
  String? encode() => isEmpty ? null : jsonEncode(toJson());

  static DrillDiagram? decode(String? s) {
    if (s == null || s.trim().isEmpty) return null;
    try {
      return DrillDiagram.fromJson(
        Map<String, dynamic>.from(jsonDecode(s) as Map),
      );
    } catch (_) {
      return null;
    }
  }
}
