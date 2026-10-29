import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/drill_diagram.dart';

/// Seitenverhältnis (Breite/Höhe) passend zum Feldtyp: Längsfeld hochkant.
double aspectForField(String field) => field == 'full_v' ? 0.66 : 1.5;

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
    final pitch = Paint()..color = const Color(0xFF2E7D32);
    final line = Paint()
      ..color = Colors.white.withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final rect = Offset.zero & size;
    canvas.drawRect(rect, pitch);

    // Feldmarkierungen je nach Typ.
    final inset = size.shortestSide * 0.04;
    final field = Rect.fromLTRB(
      inset,
      inset,
      size.width - inset,
      size.height - inset,
    );
    canvas.drawRect(field, line);
    void centerCircle() =>
        canvas.drawCircle(field.center, size.shortestSide * 0.12, line);

    if (diagram.field == 'full') {
      // Ganzes Feld quer: Mittellinie senkrecht, Tore links/rechts.
      canvas.drawLine(
        Offset(field.center.dx, field.top),
        Offset(field.center.dx, field.bottom),
        line,
      );
      centerCircle();
      _goalEnd(canvas, line, Offset(field.left, field.center.dy),
          const Offset(1, 0), const Offset(0, 1), field.height, field.width);
      _goalEnd(canvas, line, Offset(field.right, field.center.dy),
          const Offset(-1, 0), const Offset(0, 1), field.height, field.width);
    } else if (diagram.field == 'full_v') {
      // Ganzes Feld längs: Mittellinie waagerecht, Tore oben/unten.
      canvas.drawLine(
        Offset(field.left, field.center.dy),
        Offset(field.right, field.center.dy),
        line,
      );
      centerCircle();
      _goalEnd(canvas, line, Offset(field.center.dx, field.top),
          const Offset(0, 1), const Offset(1, 0), field.width, field.height);
      _goalEnd(canvas, line, Offset(field.center.dx, field.bottom),
          const Offset(0, -1), const Offset(1, 0), field.width, field.height);
    } else if (diagram.field == 'half') {
      // Halbfeld: Mittellinie oben (Anstoßkreis-Bogen), Tor unten.
      canvas.drawArc(
        Rect.fromCircle(
          center: Offset(field.center.dx, field.top),
          radius: size.shortestSide * 0.12,
        ),
        0,
        math.pi,
        false,
        line,
      );
      _goalEnd(canvas, line, Offset(field.center.dx, field.bottom),
          const Offset(0, -1), const Offset(1, 0), field.width, field.height,
          scale: 1.9);
    }

    Offset p(double x, double y) =>
        Offset(field.left + x * field.width, field.top + y * field.height);
    final r = size.shortestSide * 0.045;

    // In Ebenen zeichnen: Zonen/Pfeile nach hinten, Spieler/Ball/Text nach
    // vorne, damit nichts Wichtiges verdeckt wird.
    final sorted = [...diagram.elements]
      ..sort((a, b) => _layer(a.type).compareTo(_layer(b.type)));
    for (final e in sorted) {
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
          _ball(canvas, pos, er * 0.85);
        case 'arrow':
          final to = p(e.x2 ?? e.x, e.y2 ?? e.y);
          _arrow(canvas, pos, to, e.size ?? 1.0);
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

  void _player(
    Canvas c,
    Offset o,
    double r,
    Color color,
    String? label,
    Size size,
  ) {
    c.drawCircle(o, r, Paint()..color = color);
    c.drawCircle(
      o,
      r,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
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

  // Großtor (big) deutlich größer als ein Minitor.
  void _goal(Canvas c, Offset o, double r, {required bool big}) {
    final w = big ? r * 2.8 : r * 1.5;
    final h = big ? r * 1.05 : r * 0.7;
    c.drawRect(
      Rect.fromCenter(center: o, width: w, height: h),
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = big ? 3.0 : 2.0,
    );
  }

  // Weißer Ball mit schwarzem Fünfeck und Nähten – erkennbare Fußball-Optik.
  void _ball(Canvas c, Offset o, double r) {
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

  void _arrow(Canvas c, Offset a, Offset b, [double scale = 1.0]) {
    final paint = Paint()
      ..color = Colors.yellowAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5 * scale;
    c.drawLine(a, b, paint);
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

  // Ein Tor-Ende: 16er-Raum, 5er-Raum, Elfmeterpunkt und Strafraumbogen.
  // [glc] = Mitte der Torlinie, [inward] zeigt ins Feld, [along] entlang der
  // Torlinie. [crossLen]/[longLen] sind die Feldmaße quer/längs zur Spielrichtung.
  void _goalEnd(
    Canvas c,
    Paint line,
    Offset glc,
    Offset inward,
    Offset along,
    double crossLen,
    double longLen, {
    double scale = 1.0,
  }) {
    _boxAt(c, line, glc, inward, along, longLen * 0.16 * scale, crossLen * 0.30);
    _boxAt(c, line, glc, inward, along, longLen * 0.055 * scale, crossLen * 0.15);
    final spot = glc + inward * (longLen * 0.11 * scale);
    c.drawCircle(
      spot,
      math.max(1.5, line.strokeWidth * 1.3),
      Paint()..color = line.color,
    );
    final rr = longLen * 0.11 * scale;
    final ang = math.atan2(inward.dy, inward.dx);
    const half = 1.15;
    c.drawArc(
      Rect.fromCircle(center: spot, radius: rr),
      ang - half,
      half * 2,
      false,
      line,
    );
  }

  void _boxAt(
    Canvas c,
    Paint line,
    Offset glc,
    Offset inward,
    Offset along,
    double depth,
    double halfW,
  ) {
    final p1 = glc + along * halfW;
    final p2 = glc - along * halfW;
    final i1 = p1 + inward * depth;
    final i2 = p2 + inward * depth;
    c.drawPath(
      Path()
        ..moveTo(p1.dx, p1.dy)
        ..lineTo(i1.dx, i1.dy)
        ..lineTo(i2.dx, i2.dy)
        ..lineTo(p2.dx, p2.dy),
      line,
    );
  }

  void _zone(Canvas c, Rect rect) {
    c.drawRect(
      rect,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    c.drawRect(rect, Paint()..color = Colors.white.withValues(alpha: 0.08));
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
