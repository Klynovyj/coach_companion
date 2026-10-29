import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/drill_diagram.dart';
import 'pitch_geometry.dart';

/// Seitenverhältnis (Breite/Höhe) passend zum Feldtyp (aus der Pitch-Geometrie).
double aspectForField(String field) => pitchGeometryFor(field).aspect;

/// Zeichnet eine Übungs-Skizze (Spielfeld + Elemente). Rein darstellend; der
/// Editor legt eine Interaktionsschicht darüber.
class DrillDiagramView extends StatelessWidget {
  const DrillDiagramView({super.key, required this.diagram, this.aspectRatio});

  final DrillDiagram diagram;

  /// Überschreibt das vom Feldtyp abgeleitete Seitenverhältnis (optional).
  final double? aspectRatio;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: aspectRatio ?? aspectForField(diagram.field),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: CustomPaint(
          painter: DrillDiagramPainter(diagram),
          size: Size.infinite,
        ),
      ),
    );
  }
}

Color _parseColor(String? hex, Color fallback) {
  if (hex == null) return fallback;
  var h = hex.replaceAll('#', '').trim();
  if (h.length == 6) h = 'FF$h';
  final v = int.tryParse(h, radix: 16);
  return v == null ? fallback : Color(v);
}

class DrillDiagramPainter extends CustomPainter {
  DrillDiagramPainter(this.diagram);
  final DrillDiagram diagram;

  @override
  void paint(Canvas canvas, Size size) {
    // Rasen mit Mäh-Streifen (wie Coach Studio).
    final geo = pitchGeometryFor(diagram.field);
    const stripeLight = Color(0xFF2D6B3E);
    const stripeDark = Color(0xFF1F4F2C);
    final n = math.max(8, geo.stripes * 2);
    for (var i = 0; i < n; i++) {
      canvas.drawRect(
        Rect.fromLTWH(
          0,
          size.height * i / n,
          size.width,
          size.height / n + 0.5,
        ),
        Paint()..color = i.isEven ? stripeLight : stripeDark,
      );
    }

    // Linien wie bei Coach Studio: solide weiß, relative Strichstärke.
    final line = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.2, size.shortestSide * 0.008)
      ..strokeJoin = StrokeJoin.miter;

    // Feldmarkierungen aus der (aus Coach Studio portierten) Pitch-Geometrie.
    final inset = size.shortestSide * 0.03;
    final field = Rect.fromLTRB(
      inset,
      inset,
      size.width - inset,
      size.height - inset,
    );
    _drawMarkings(canvas, field, line, diagram.field);

    Offset p(double x, double y) =>
        Offset(field.left + x * field.width, field.top + y * field.height);
    final r = size.shortestSide * 0.045;

    // In Ebenen zeichnen (Zonen/Pfeile hinten, Spieler/Ball/Text vorne), bei
    // Gleichstand stabil nach ursprünglichem Index – so wirkt die Z-Order.
    final order = List.generate(diagram.elements.length, (i) => i)
      ..sort((a, b) {
        final c = _layer(
          diagram.elements[a].type,
        ).compareTo(_layer(diagram.elements[b].type));
        return c != 0 ? c : a.compareTo(b);
      });
    for (final idx in order) {
      final e = diagram.elements[idx];
      final pos = p(e.x, e.y);
      final er = r * (e.size ?? 1.0);
      switch (e.type) {
        case 'cone':
          _cone(canvas, pos, er, _parseColor(e.color, const Color(0xFFEF6C00)));
        case 'goal':
          _goal(canvas, pos, er, big: true);
        case 'minigoal':
          _goal(canvas, pos, er, big: false);
        case 'ball':
          _ball(canvas, pos, er * 0.75);
        case 'arrow':
          final to = p(e.x2 ?? e.x, e.y2 ?? e.y);
          _arrow(canvas, pos, to, e.size ?? 1.0, e.dashed ?? false);
        case 'zone':
          final to = p(e.x2 ?? e.x, e.y2 ?? e.y);
          _zone(canvas, Rect.fromPoints(pos, to));
        case 'text':
          _text(canvas, pos, e.label ?? '', size, e.size ?? 1.0);
        default: // player
          _player(
            canvas,
            pos,
            er,
            _parseColor(e.color, const Color(0xFF1565C0)),
            e.label,
            size,
          );
      }
    }
  }

  // Dezenter Schlagschatten für den 3D-Look (wie im Coach-Studio-Editor).
  void _chipShadow(Canvas c, Offset o, double r) {
    c.drawCircle(
      o.translate(r * 0.06, r * 0.14),
      r,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.35)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.3),
    );
  }

  void _player(
    Canvas c,
    Offset o,
    double r,
    Color color,
    String? label,
    Size size,
  ) {
    _chipShadow(c, o, r);
    c.drawCircle(o, r, Paint()..color = color);
    c.drawCircle(
      o,
      r,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.2, r * 0.13),
    );
    if (label != null && label.isNotEmpty) {
      _label(c, o, label, size, Colors.white, r);
    }
  }

  void _cone(Canvas c, Offset o, double r, Color color) {
    final path = Path()
      ..moveTo(o.dx, o.dy - r)
      ..lineTo(o.dx - r * 0.8, o.dy + r * 0.7)
      ..lineTo(o.dx + r * 0.8, o.dy + r * 0.7)
      ..close();
    c.drawPath(path, Paint()..color = color);
  }

  // Großtor (big) deutlich größer als ein Minitor; mit angedeutetem Netz.
  void _goal(Canvas c, Offset o, double r, {required bool big}) {
    final w = big ? r * 2.8 : r * 1.6;
    final h = big ? r * 1.1 : r * 0.75;
    final rect = Rect.fromCenter(center: o, width: w, height: h);
    c.drawRect(rect, Paint()..color = Colors.white.withValues(alpha: 0.12));
    final net = Paint()
      ..color = Colors.white.withValues(alpha: 0.3)
      ..strokeWidth = 0.6;
    for (var i = 1; i < 4; i++) {
      final x = rect.left + rect.width * i / 4;
      c.drawLine(Offset(x, rect.top), Offset(x, rect.bottom), net);
    }
    c.drawLine(
      Offset(rect.left, rect.center.dy),
      Offset(rect.right, rect.center.dy),
      net,
    );
    c.drawRect(
      rect,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = big ? 3.0 : 2.2,
    );
  }

  // Weißer Ball mit schwarzem Fünfeck und Nähten – erkennbare Fußball-Optik.
  void _ball(Canvas c, Offset o, double r) {
    _chipShadow(c, o, r);
    c.drawCircle(o, r, Paint()..color = Colors.white);
    final seam = math.max(1.0, r * 0.14);
    final stroke = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeWidth = seam;
    c.drawCircle(o, r, stroke);
    c.drawPath(_pentagon(o, r * 0.42, -math.pi / 2), Paint()..color = Colors.black);
    for (var i = 0; i < 5; i++) {
      final a = -math.pi / 2 + i * 2 * math.pi / 5;
      final dir = Offset(math.cos(a), math.sin(a));
      c.drawLine(o + dir * (r * 0.42), o + dir * r, stroke);
    }
  }

  Path _pentagon(Offset center, double r, double start) {
    final path = Path();
    for (var i = 0; i < 5; i++) {
      final a = start + i * 2 * math.pi / 5;
      final pt = center + Offset(math.cos(a), math.sin(a)) * r;
      i == 0 ? path.moveTo(pt.dx, pt.dy) : path.lineTo(pt.dx, pt.dy);
    }
    return path..close();
  }

  void _arrow(
    Canvas c,
    Offset a,
    Offset b, [
    double scale = 1.0,
    bool dashed = false,
  ]) {
    final paint = Paint()
      ..color = Colors.yellowAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5 * scale;
    if (dashed) {
      _dashedLine(c, a, b, paint);
    } else {
      c.drawLine(a, b, paint);
    }
    final angle = math.atan2(b.dy - a.dy, b.dx - a.dx);
    final head = 10.0 * scale;
    final p1 = Offset(
      b.dx - head * math.cos(angle - 0.5),
      b.dy - head * math.sin(angle - 0.5),
    );
    final p2 = Offset(
      b.dx - head * math.cos(angle + 0.5),
      b.dy - head * math.sin(angle + 0.5),
    );
    c.drawLine(b, p1, paint);
    c.drawLine(b, p2, paint);
  }

  void _dashedLine(Canvas c, Offset a, Offset b, Paint p) {
    final total = (b - a).distance;
    if (total <= 0) return;
    final dir = (b - a) / total;
    const dash = 7.0, gap = 5.0;
    var d = 0.0;
    while (d < total) {
      final s = a + dir * d;
      final e = a + dir * math.min(d + dash, total);
      c.drawLine(s, e, p);
      d += dash + gap;
    }
  }

  // Zeichnet die Feldmarkierungen aus der Pitch-Geometrie. Kreis-/Bogenradien
  // werden über die Feldhöhe skaliert, damit sie in jeder Ausrichtung rund sind.
  void _drawMarkings(Canvas c, Rect f, Paint line, String field) {
    final g = pitchGeometryFor(field);
    Offset at(double x, double y) =>
        Offset(f.left + x * f.width, f.top + y * f.height);
    for (final r in g.markings.rects) {
      c.drawRect(
        Rect.fromLTWH(
          f.left + r.x * f.width,
          f.top + r.y * f.height,
          r.w * f.width,
          r.h * f.height,
        ),
        line,
      );
    }
    for (final l in g.markings.lines) {
      c.drawLine(at(l.x1, l.y1), at(l.x2, l.y2), line);
    }
    for (final ci in g.markings.circles) {
      final rad = ci.r * f.height;
      if (rad < 1.5) {
        // Elfmeter-/Mittelpunkt gefüllt.
        c.drawCircle(
          at(ci.cx, ci.cy),
          math.max(1.5, rad * 1.6),
          Paint()..color = line.color,
        );
      } else {
        c.drawCircle(at(ci.cx, ci.cy), rad, line);
      }
    }
    for (final a in g.markings.arcs) {
      final sweep = (((a.end - a.start) % 360) + 360) % 360;
      c.drawArc(
        Rect.fromCircle(center: at(a.cx, a.cy), radius: a.r * f.height),
        a.start * math.pi / 180,
        sweep * math.pi / 180,
        false,
        line,
      );
    }
  }

  void _zone(Canvas c, Rect rect) {
    const amber = Color(0xFFFACC15);
    c.drawRect(rect, Paint()..color = amber.withValues(alpha: 0.2));
    c.drawRect(
      rect,
      Paint()
        ..color = amber.withValues(alpha: 0.9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8,
    );
  }

  int _layer(String type) {
    switch (type) {
      case 'zone':
        return 0;
      case 'arrow':
        return 1;
      case 'cone':
      case 'goal':
      case 'minigoal':
        return 2;
      case 'ball':
        return 4;
      case 'text':
        return 5;
      default: // player
        return 3;
    }
  }

  // Kurzes Text-Label als lesbarer Kasten, innerhalb des Feldes gehalten.
  void _text(Canvas c, Offset o, String label, Size size, [double scale = 1.0]) {
    if (label.trim().isEmpty) return;
    final fontSize = size.shortestSide * 0.042 * scale;
    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: Colors.white,
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
      maxLines: 2,
      ellipsis: '…',
    )..layout(maxWidth: size.width * 0.5);
    const pad = 4.0;
    final boxW = tp.width + pad * 2;
    final boxH = tp.height + pad * 2;
    final left = (o.dx - boxW / 2).clamp(2.0, size.width - boxW - 2);
    final top = (o.dy - boxH / 2).clamp(2.0, size.height - boxH - 2);
    final box = Rect.fromLTWH(left, top, boxW, boxH);
    c.drawRRect(
      RRect.fromRectAndRadius(box, const Radius.circular(4)),
      Paint()..color = Colors.black.withValues(alpha: 0.5),
    );
    tp.paint(c, Offset(left + pad, top + pad));
  }

  void _label(Canvas c, Offset o, String s, Size size, Color color, double r) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(
          color: color,
          fontSize: r * 0.95,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, o - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant DrillDiagramPainter old) =>
      old.diagram != diagram;
}
