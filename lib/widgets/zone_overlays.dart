import 'package:flutter/material.dart';

/// Zonen-Overlay-Presets, portiert aus Coach Studio `zones.ts`.
/// Koordinaten normiert (0..1) in Portrait-Konvention (Angriff oben);
/// Querformat wird am Render-Punkt gedreht (`overlayZones(..., landscape)`).

class ZoneCell {
  final String label;
  final double x, y, width, height;
  final Color color;
  const ZoneCell(
    this.label,
    this.x,
    this.y,
    this.width,
    this.height,
    this.color,
  );
}

Color _hsla(double h, double s, double l, double a) =>
    HSLColor.fromAHSL(a, h, s, l).toColor();

// ─── Drittel ────────────────────────────────────────────────────────────────
final _thirds = <ZoneCell>[
  ZoneCell('Angriff', 0, 0, 1, 1 / 3, _hsla(0, .70, .50, .16)),
  ZoneCell('Mittelfeld', 0, 1 / 3, 1, 1 / 3, _hsla(45, .85, .55, .14)),
  ZoneCell('Verteidigung', 0, 2 / 3, 1, 1 / 3, _hsla(210, .80, .55, .16)),
];

// ─── Streifen (5 senkrecht) ───────────────────────────────────────────────────
final _strips = <ZoneCell>[
  ZoneCell('Breite', 0.00, 0, 0.16, 1, _hsla(280, .70, .55, .14)),
  ZoneCell('Halbfeld', 0.16, 0, 0.22, 1, _hsla(200, .70, .55, .12)),
  ZoneCell('Zentrum', 0.38, 0, 0.24, 1, _hsla(120, .55, .55, .12)),
  ZoneCell('Halbfeld', 0.62, 0, 0.22, 1, _hsla(200, .70, .55, .12)),
  ZoneCell('Breite', 0.84, 0, 0.16, 1, _hsla(280, .70, .55, .14)),
];

// ─── 5×3 Raster (15 Zellen, keine Labels) ─────────────────────────────────────
const _g15x = [0.00, 0.16, 0.38, 0.62, 0.84];
const _g15w = [0.16, 0.22, 0.24, 0.22, 0.16];
final _grid15 = <ZoneCell>[
  for (final (ri, ry) in [(0, 0.0), (1, 1 / 3), (2, 2 / 3)])
    for (var ci = 0; ci < 5; ci++)
      ZoneCell(
        '',
        _g15x[ci],
        ry,
        _g15w[ci],
        1 / 3,
        _grid15Color(ri, ci),
      ),
];

Color _grid15Color(int row, int col) {
  // Reihe 1 warm (Rot→Gelb), Reihe 2 Übergang (Olive→Türkis), Reihe 3 kühl.
  const rows = [
    [0.0, 15.0, 28.0, 40.0, 52.0],
    [75.0, 100.0, 130.0, 155.0, 180.0],
    [200.0, 220.0, 240.0, 265.0, 290.0],
  ];
  const sat = [
    [.65, .70, .75, .80, .80],
    [.55, .50, .50, .55, .55],
    [.65, .65, .60, .55, .55],
  ];
  const lig = [
    [.45, .48, .50, .50, .50],
    [.45, .45, .45, .45, .45],
    [.50, .55, .55, .55, .55],
  ];
  return _hsla(rows[row][col], sat[row][col], lig[row][col], .32);
}

// ─── 9-Zonen-Modell (nummeriert) ─────────────────────────────────────────────
final _g9attack = _hsla(120, .55, .40, .30);
final _g9middle = _hsla(75, .60, .45, .30);
final _g9defense = _hsla(175, .50, .40, .30);
final _grid9 = <ZoneCell>[
  for (final (ri, ry, col) in [
    (0, 0.0, 0),
    (1, 1 / 3, 1),
    (2, 2 / 3, 2),
  ])
    for (var ci = 0; ci < 3; ci++)
      ZoneCell(
        '${ri * 3 + ci + 1}',
        ci / 3,
        ry,
        1 / 3,
        1 / 3,
        col == 0
            ? _g9attack
            : col == 1
            ? _g9middle
            : _g9defense,
      ),
];

// ─── Pressingzonen ────────────────────────────────────────────────────────────
final _pressing = <ZoneCell>[
  ZoneCell('HOHES PRESSING', 0, 0, 1, 1 / 3, _hsla(18, .65, .45, .40)),
  ZoneCell('MITTELFELDPRESSING', 0, 1 / 3, 1, 1 / 3, _hsla(60, .65, .38, .40)),
  ZoneCell('TIEFER BLOCK', 0, 2 / 3, 1, 1 / 3, _hsla(190, .60, .40, .40)),
];

// ─── Angriffsdrittel (3 Zonen oben) ──────────────────────────────────────────
final _attackThirds = <ZoneCell>[
  ZoneCell('1', 0, 0, 1 / 3, 1 / 3, _hsla(0, .70, .45, .35)),
  ZoneCell('2', 1 / 3, 0, 1 / 3, 1 / 3, _hsla(22, .75, .50, .35)),
  ZoneCell('3', 2 / 3, 0, 1 / 3, 1 / 3, _hsla(45, .80, .50, .35)),
];

final Map<String, (String, List<ZoneCell>)> _overlays = {
  'thirds': ('Drittel', _thirds),
  'strips': ('Streifen', _strips),
  'grid_15': ('5×3 Raster', _grid15),
  'grid_9': ('9-Zonen', _grid9),
  'pressing': ('Pressingzonen', _pressing),
  'attack_thirds': ('Angriffsdrittel', _attackThirds),
};

/// Auswahl-Liste für den Picker: (key, Label). `null`-Key = „Keins".
List<(String?, String)> get overlayOptions => [
  (null, 'Kein Raster'),
  for (final e in _overlays.entries) (e.key, e.value.$1),
];

/// Die (ggf. ins Querformat gedrehten) Zonen eines Presets.
List<ZoneCell> overlayZones(String? key, bool landscape) {
  if (key == null) return const [];
  final spec = _overlays[key];
  if (spec == null) return const [];
  if (!landscape) return spec.$2;
  return [
    for (final z in spec.$2)
      ZoneCell(
        z.label,
        1 - z.y - z.height,
        z.x,
        z.height,
        z.width,
        z.color,
      ),
  ];
}
