import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/drill_diagram.dart';
import 'pitch_geometry.dart';
import 'zone_overlays.dart';

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
    final geo = pitchGeometryFor(diagram.field);
    final inset = size.shortestSide * 0.03;
    final field = Rect.fromLTRB(
      inset,
      inset,
      size.width - inset,
      size.height - inset,
    );

    // Rasen: Runout-Rand + Mäh-Streifen im Feld (Coach-Studio-Theme).
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF4D6E47),
    );
    const stripeLight = Color(0xFF80B270);
    const stripeDark = Color(0xFF6CA15B);
    final n = math.max(8, geo.stripes * 2);
    canvas.save();
    canvas.clipRect(field);
    for (var i = 0; i < n; i++) {
      canvas.drawRect(
        Rect.fromLTWH(
          field.left,
          field.top + field.height * i / n,
          field.width,
          field.height / n + 0.5,
        ),
        Paint()..color = i.isEven ? stripeLight : stripeDark,
      );
    }
    canvas.restore();

    // Linien: weiß, relative Strichstärke, mit dezentem Schatten.
    final sw = math.max(1.2, size.shortestSide * 0.008);
    final line = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = sw
      ..strokeJoin = StrokeJoin.miter;
    final lineShadow = Paint()
      ..color = Colors.black.withValues(alpha: 0.4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = sw
      ..strokeJoin = StrokeJoin.miter;
    canvas.save();
    canvas.translate(0, math.max(0.6, size.shortestSide * 0.004));
    _drawMarkings(canvas, field, lineShadow, diagram.field);
    canvas.restore();
    _drawMarkings(canvas, field, line, diagram.field);

    // Zonen-Raster (Overlay) hinter den Objekten.
    if (diagram.overlay != null) {
      _drawOverlay(canvas, field, diagram.overlay!, diagram.field == 'full');
    }

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
      final op = e.opacity;
      final fade = op != null && op < 1.0;
      if (fade) {
        canvas.saveLayer(
          null,
          Paint()..color = Colors.white.withValues(alpha: op.clamp(0.0, 1.0)),
        );
      }
      final rot = (e.rotation ?? 0) * math.pi / 180;
      final rotate =
          rot != 0 &&
          (e.type == 'cone' ||
              e.type == 'goal' ||
              e.type == 'minigoal' ||
              e.type == 'text');
      if (rotate) {
        canvas.save();
        canvas.translate(pos.dx, pos.dy);
        canvas.rotate(rot);
        canvas.translate(-pos.dx, -pos.dy);
      }
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
          _drawArrow(canvas, pos, to, e);
        case 'zone':
          final to = p(e.x2 ?? e.x, e.y2 ?? e.y);
          _zone(canvas, Rect.fromPoints(pos, to), e);
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
      if (rotate) canvas.restore();
      if (fade) canvas.restore();
    }
  }

  // Weicher Schlagschatten für den 3D-Look (wie im Coach-Studio-Editor).
  void _chipShadow(Canvas c, Offset o, double r) {
    c.drawCircle(
      o.translate(r * 0.08, r * 0.22),
      r * 1.02,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.45)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.45),
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
    // Radial-Verlauf (oben-links aufgehellt) wie Coach-Studio-Chips.
    final hi = Color.lerp(color, Colors.white, 0.35)!;
    c.drawCircle(
      o,
      r,
      Paint()
        ..shader = ui.Gradient.radial(o.translate(-r * 0.35, -r * 0.35), r * 1.3, [
          hi,
          color,
        ]),
    );
    // Dunkler „Tinten"-Ring statt weiß.
    c.drawCircle(
      o,
      r,
      Paint()
        ..color = const Color(0xFF0B0F17)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.2, r * 0.12),
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

  // Pfeil/Linie mit Bogen, Linientyp (solid/dashed/wavy/double), Pfeilspitzen
  // und Strichstärke.
  void _drawArrow(Canvas c, Offset a, Offset b, DrillElement e) {
    final scale = e.size ?? 1.0;
    final sw = (e.strokeWidth ?? 2.5) * scale;
    final color = _parseColor(e.color, Colors.yellowAccent);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = sw
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final curve = e.curve ?? 0.0;
    final curved = curve.abs() >= 0.005;
    final ctrl = _ctrlPoint(a, b, curve);
    final lineType = e.lineType ?? (e.dashed == true ? 'dashed' : 'solid');
    final n = curved ? 28 : (lineType == 'wavy' ? 40 : 2);
    final pts = _samplePath(a, b, ctrl, curved, n);

    switch (lineType) {
      case 'dashed':
        for (var i = 0; i < pts.length - 1; i++) {
          _dashedLine(c, pts[i], pts[i + 1], paint);
        }
      case 'wavy':
        c.drawPath(_wavyPath(pts, sw), paint);
      case 'double':
        final off = sw * 1.1;
        c.drawPath(_polyPath(_offsetPolyline(pts, off)), paint);
        c.drawPath(_polyPath(_offsetPolyline(pts, -off)), paint);
      default:
        c.drawPath(_polyPath(pts), paint);
    }

    final endHead = (e.lineEnd ?? 'arrow') == 'arrow';
    final startHead = (e.lineStart ?? 'none') == 'arrow';
    if (endHead && pts.length >= 2) {
      _arrowHead(c, pts[pts.length - 2], pts.last, color, sw);
    }
    if (startHead && pts.length >= 2) {
      _arrowHead(c, pts[1], pts.first, color, sw);
    }
  }

  Offset _ctrlPoint(Offset a, Offset b, double amt) {
    final dx = b.dx - a.dx, dy = b.dy - a.dy;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 0.001) return a;
    final nx = -dy / len, ny = dx / len;
    return Offset(
      a.dx + dx * 0.5 + nx * len * amt,
      a.dy + dy * 0.5 + ny * len * amt,
    );
  }

  List<Offset> _samplePath(Offset a, Offset b, Offset ctrl, bool curved, int n) {
    final pts = <Offset>[];
    for (var i = 0; i <= n; i++) {
      final t = i / n;
      if (!curved) {
        pts.add(Offset.lerp(a, b, t)!);
      } else {
        final omt = 1 - t;
        pts.add(
          Offset(
            omt * omt * a.dx + 2 * omt * t * ctrl.dx + t * t * b.dx,
            omt * omt * a.dy + 2 * omt * t * ctrl.dy + t * t * b.dy,
          ),
        );
      }
    }
    return pts;
  }

  Path _polyPath(List<Offset> pts) {
    final path = Path();
    if (pts.isEmpty) return path;
    path.moveTo(pts.first.dx, pts.first.dy);
    for (var i = 1; i < pts.length; i++) {
      path.lineTo(pts[i].dx, pts[i].dy);
    }
    return path;
  }

  List<Offset> _offsetPolyline(List<Offset> pts, double dist) {
    final out = <Offset>[];
    for (var i = 0; i < pts.length; i++) {
      var nx = 0.0, ny = 0.0;
      if (i > 0) {
        final d = pts[i] - pts[i - 1];
        final l = d.distance;
        if (l > 0) {
          nx += -d.dy / l;
          ny += d.dx / l;
        }
      }
      if (i < pts.length - 1) {
        final d = pts[i + 1] - pts[i];
        final l = d.distance;
        if (l > 0) {
          nx += -d.dy / l;
          ny += d.dx / l;
        }
      }
      final nl = math.sqrt(nx * nx + ny * ny);
      out.add(nl > 0 ? pts[i] + Offset(nx / nl, ny / nl) * dist : pts[i]);
    }
    return out;
  }

  Path _wavyPath(List<Offset> pts, double sw) {
    final amp = math.max(2.0, sw * 1.4);
    final out = <Offset>[];
    var dist = 0.0;
    for (var i = 0; i < pts.length; i++) {
      if (i > 0) dist += (pts[i] - pts[i - 1]).distance;
      final j0 = i > 0 ? i - 1 : i;
      final j1 = i < pts.length - 1 ? i + 1 : i;
      final d = pts[j1] - pts[j0];
      final l = d.distance;
      final nx = l > 0 ? -d.dy / l : 0.0;
      final ny = l > 0 ? d.dx / l : 0.0;
      final s = math.sin(dist / (amp * 1.6)) * amp;
      out.add(pts[i] + Offset(nx, ny) * s);
    }
    return _polyPath(out);
  }

  void _arrowHead(Canvas c, Offset from, Offset tip, Color color, double sw) {
    final d = tip - from;
    final l = d.distance;
    if (l < 0.001) return;
    final u = Offset(d.dx / l, d.dy / l);
    final head = math.max(7.0, sw * 3.0);
    final hw = head * 0.6;
    final base = tip - u * head;
    final perp = Offset(-u.dy, u.dx);
    final path = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo((base + perp * hw).dx, (base + perp * hw).dy)
      ..lineTo((base - perp * hw).dx, (base - perp * hw).dy)
      ..close();
    c.drawPath(path, Paint()..color = color);
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

  // Zonen-Raster-Overlay (farbige Flächen + optionale Labels).
  void _drawOverlay(Canvas c, Rect f, String key, bool landscape) {
    for (final z in overlayZones(key, landscape)) {
      final rect = Rect.fromLTWH(
        f.left + z.x * f.width,
        f.top + z.y * f.height,
        z.width * f.width,
        z.height * f.height,
      );
      c.drawRect(rect, Paint()..color = z.color);
      if (z.label.isNotEmpty) {
        final fs = math
            .min(rect.height * 0.35, rect.width / (z.label.length * 0.62))
            .clamp(8.0, rect.height);
        final tp = TextPainter(
          text: TextSpan(
            text: z.label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.45),
              fontWeight: FontWeight.w900,
              fontSize: fs,
            ),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout(maxWidth: rect.width);
        tp.paint(c, rect.center - Offset(tp.width / 2, tp.height / 2));
      }
    }
  }

  void _zone(Canvas c, Rect rect, DrillElement e) {
    final strokeColor = _parseColor(e.color, const Color(0xFFFACC15));
    final fillColor = _parseColor(e.fill ?? e.color, const Color(0xFFFACC15));
    final fillOp = (e.fillOpacity ?? 0.2).clamp(0.0, 1.0);
    final ellipse = (e.shape ?? 'rect') == 'ellipse';
    final fillPaint = Paint()..color = fillColor.withValues(alpha: fillOp);
    final strokePaint = Paint()
      ..color = strokeColor.withValues(alpha: 0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = e.strokeWidth ?? 1.8;
    if (ellipse) {
      c.drawOval(rect, fillPaint);
      c.drawOval(rect, strokePaint);
    } else {
      c.drawRect(rect, fillPaint);
      c.drawRect(rect, strokePaint);
    }
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
          shadows: [
            Shadow(
              color: Colors.black.withValues(alpha: 0.55),
              blurRadius: r * 0.22,
              offset: Offset(0, r * 0.06),
            ),
          ],
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
