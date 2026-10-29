import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/drill_diagram.dart';

/// Zeichnet eine Übungs-Skizze (Spielfeld + Elemente). Rein darstellend; der
/// Editor legt eine Interaktionsschicht darüber.
class DrillDiagramView extends StatelessWidget {
  const DrillDiagramView({
    super.key,
    required this.diagram,
    this.aspectRatio = 1.5,
  });

  final DrillDiagram diagram;
  final double aspectRatio;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: aspectRatio,
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
    if (diagram.field == 'full') {
      canvas.drawLine(
        Offset(field.center.dx, field.top),
        Offset(field.center.dx, field.bottom),
        line,
      );
      canvas.drawCircle(field.center, size.shortestSide * 0.12, line);
    } else if (diagram.field == 'half') {
      // Strafraum unten.
      final boxW = field.width * 0.55;
      final boxH = field.height * 0.28;
      canvas.drawRect(
        Rect.fromLTWH(
          field.center.dx - boxW / 2,
          field.bottom - boxH,
          boxW,
          boxH,
        ),
        line,
      );
    }

    Offset p(double x, double y) =>
        Offset(field.left + x * field.width, field.top + y * field.height);
    final r = size.shortestSide * 0.045;

    for (final e in diagram.elements) {
      final pos = p(e.x, e.y);
      switch (e.type) {
        case 'cone':
          _cone(canvas, pos, r, _parseColor(e.color, const Color(0xFFEF6C00)));
        case 'goal':
          _goal(canvas, pos, r);
        case 'ball':
          _ball(canvas, pos, r * 0.7);
        case 'arrow':
          final to = p(e.x2 ?? e.x, e.y2 ?? e.y);
          _arrow(canvas, pos, to);
        case 'zone':
          final to = p(e.x2 ?? e.x, e.y2 ?? e.y);
          _zone(canvas, Rect.fromPoints(pos, to));
        case 'text':
          _text(canvas, pos, e.label ?? '', size);
        default: // player
          _player(
            canvas,
            pos,
            r,
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

  void _goal(Canvas c, Offset o, double r) {
    c.drawRect(
      Rect.fromCenter(center: o, width: r * 2.2, height: r * 0.9),
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
  }

  void _ball(Canvas c, Offset o, double r) {
    c.drawCircle(o, r, Paint()..color = Colors.white);
    c.drawCircle(
      o,
      r,
      Paint()
        ..color = Colors.black
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  void _arrow(Canvas c, Offset a, Offset b) {
    final paint = Paint()
      ..color = Colors.yellowAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    c.drawLine(a, b, paint);
    final angle = math.atan2(b.dy - a.dy, b.dx - a.dx);
    const head = 10.0;
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

  void _text(Canvas c, Offset o, String label, Size size) {
    _label(c, o, label, size, Colors.white, size.shortestSide * 0.05);
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
