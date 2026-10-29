import 'dart:math';
import 'dart:ui';

/// Spielfeld-Markierungen, portiert aus Coach Studio (fieldGeometry.ts).
/// Koordinaten sind 0..1 im inneren Feld-Rechteck. Radien sind als Bruchteil
/// der Höhe (y-Achse) gespeichert; beim Zeichnen → radius = r * Feldhöhe(px),
/// damit Kreise in jeder Ausrichtung rund bleiben.
class PitchRect {
  final double x, y, w, h;
  const PitchRect(this.x, this.y, this.w, this.h);
}

class PitchLine {
  final double x1, y1, x2, y2;
  const PitchLine(this.x1, this.y1, this.x2, this.y2);
}

class PitchCircle {
  final double cx, cy, r;
  const PitchCircle(this.cx, this.cy, this.r);
}

class PitchArc {
  final double cx, cy, r, start, end; // start/end in Grad
  const PitchArc(this.cx, this.cy, this.r, this.start, this.end);
}

class PitchMarkings {
  final List<PitchRect> rects;
  final List<PitchLine> lines;
  final List<PitchCircle> circles;
  final List<PitchArc> arcs;
  const PitchMarkings({
    this.rects = const [],
    this.lines = const [],
    this.circles = const [],
    this.arcs = const [],
  });
}

class PitchGeometry {
  /// Breite / Höhe des inneren Feld-Rechtecks.
  final double aspect;
  final PitchMarkings markings;
  const PitchGeometry(this.aspect, this.markings);
}

// ─── Basis-Geometrien (Hochformat, Tor oben) ─────────────────────────────────

const PitchGeometry _baseFull = PitchGeometry(
  68 / 105,
  PitchMarkings(
    rects: [
      PitchRect(0, 0, 1, 1), // Außenlinie
      PitchRect(0.2, 0, 0.6, 0.15), // Strafraum oben
      PitchRect(0.35, 0, 0.3, 0.05), // Torraum oben
      PitchRect(0.2, 0.85, 0.6, 0.15), // Strafraum unten
      PitchRect(0.35, 0.95, 0.3, 0.05), // Torraum unten
    ],
    lines: [PitchLine(0, 0.5, 1, 0.5)], // Mittellinie
    circles: [
      PitchCircle(0.5, 0.5, 0.1), // Mittelkreis
      PitchCircle(0.5, 0.5, 0.004), // Mittelpunkt
      PitchCircle(0.5, 0.1, 0.005), // Elfmeterpunkt oben
      PitchCircle(0.5, 0.9, 0.005), // Elfmeterpunkt unten
    ],
    arcs: [
      PitchArc(0.5, 0.1, 0.1, 30, 150), // Strafraumbogen oben
      PitchArc(0.5, 0.9, 0.1, 210, 330), // Strafraumbogen unten
    ],
  ),
);

const PitchGeometry _baseBox = PitchGeometry(
  67.5 / 63,
  PitchMarkings(
    rects: [
      PitchRect(0, 0, 1, 1),
      PitchRect(0.2, 0, 0.6, 3 / 12), // Strafraum
      PitchRect(0.35, 0, 0.3, 1 / 12), // Torraum
    ],
    lines: [PitchLine(0, 10 / 12, 1, 10 / 12)], // Mittellinie
    circles: [
      PitchCircle(0.5, 2 / 12, 0.005), // Elfmeterpunkt
      PitchCircle(0.5, 10 / 12, 9.15 / 63), // Mittelkreis
      PitchCircle(0.5, 10 / 12, 0.005), // Mittelpunkt
    ],
    arcs: [PitchArc(0.5, 2 / 12, 2 / 12, 30, 150)], // Strafraumbogen
  ),
);

/// Halbfeld (Hochformat, oben), nach unten um 7 Streifen erweitert, damit der
/// Mittelkreis komplett sichtbar ist (17 Streifen, aspect 68/89.25).
PitchGeometry _extendedHalfTop() {
  const scale = 10 / 17;
  return const PitchGeometry(
    68 / 89.25,
    PitchMarkings(
      rects: [
        PitchRect(0, 0, 1, 1),
        PitchRect(0.2, 0, 0.6, 0.3 * scale), // Strafraum
        PitchRect(0.35, 0, 0.3, 0.1 * scale), // Torraum
      ],
      lines: [PitchLine(0, 1 * scale, 1, 1 * scale)], // Mittellinie
      circles: [
        PitchCircle(0.5, 0.2 * scale, 0.008), // Elfmeterpunkt
        PitchCircle(0.5, 1 * scale, 0.2 * scale), // Mittelkreis
        PitchCircle(0.5, 1 * scale, 0.005), // Mittelpunkt
      ],
      arcs: [PitchArc(0.5, 0.2 * scale, 0.2 * scale, 30, 150)],
    ),
  );
}

// ─── Drehung Hoch → Quer (90° im Uhrzeigersinn um 0.5/0.5) ────────────────────

Offset _cw(double x, double y) => Offset(1 - y, x);

PitchGeometry _rotateCW(PitchGeometry g) {
  final a = g.aspect;
  // Radius ist als Bruchteil der y-Achse gespeichert; bei Achsentausch durch
  // oldAspect teilen, damit der physische Radius erhalten bleibt.
  double rr(double r) => r / a;
  final rects = g.markings.rects.map((r) {
    final cs = [
      _cw(r.x, r.y),
      _cw(r.x + r.w, r.y),
      _cw(r.x, r.y + r.h),
      _cw(r.x + r.w, r.y + r.h),
    ];
    final xs = cs.map((e) => e.dx);
    final ys = cs.map((e) => e.dy);
    final minx = xs.reduce(min), maxx = xs.reduce(max);
    final miny = ys.reduce(min), maxy = ys.reduce(max);
    return PitchRect(minx, miny, maxx - minx, maxy - miny);
  }).toList();
  final lines = g.markings.lines.map((l) {
    final p1 = _cw(l.x1, l.y1), p2 = _cw(l.x2, l.y2);
    return PitchLine(p1.dx, p1.dy, p2.dx, p2.dy);
  }).toList();
  final circles = g.markings.circles.map((c) {
    final p = _cw(c.cx, c.cy);
    return PitchCircle(p.dx, p.dy, rr(c.r));
  }).toList();
  final arcs = g.markings.arcs.map((ar) {
    final p = _cw(ar.cx, ar.cy);
    return PitchArc(
      p.dx,
      p.dy,
      rr(ar.r),
      (ar.start + 90) % 360,
      (ar.end + 90) % 360,
    );
  }).toList();
  return PitchGeometry(
    1 / a,
    PitchMarkings(rects: rects, lines: lines, circles: circles, arcs: arcs),
  );
}

/// Liefert die zu zeichnende Geometrie für einen Feldtyp.
/// 'full' = ganzes Feld quer (Querformat), 'full_v' = längs (Hochformat),
/// 'half' = Halbfeld, 'box' = Strafraum.
PitchGeometry pitchGeometryFor(String field) {
  switch (field) {
    case 'full_v':
      return _baseFull;
    case 'half':
      return _extendedHalfTop();
    case 'box':
      return _baseBox;
    case 'full':
    default:
      return _rotateCW(_baseFull);
  }
}
