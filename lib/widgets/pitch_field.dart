import 'package:flutter/material.dart';

/// Zeichnet ein einfaches, vertikales Fußballfeld (eigenes Tor unten).
class PitchFieldPainter extends CustomPainter {
  PitchFieldPainter(this.lineColor, this.grass1, this.grass2);
  final Color lineColor;
  final Color grass1;
  final Color grass2;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // Rasen mit Streifen.
    final stripes = 6;
    for (var i = 0; i < stripes; i++) {
      final paint = Paint()..color = i.isEven ? grass1 : grass2;
      canvas.drawRect(
        Rect.fromLTWH(0, h / stripes * i, w, h / stripes + 1),
        paint,
      );
    }

    final line = Paint()
      ..color = lineColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    final m = 8.0; // Rand
    final field = Rect.fromLTWH(m, m, w - 2 * m, h - 2 * m);
    canvas.drawRect(field, line);

    // Mittellinie + Mittelkreis.
    canvas.drawLine(Offset(m, h / 2), Offset(w - m, h / 2), line);
    canvas.drawCircle(Offset(w / 2, h / 2), w * 0.12, line);
    canvas.drawCircle(Offset(w / 2, h / 2), 3, Paint()..color = lineColor);

    // Strafräume (oben = Gegner-Tor, unten = eigenes Tor).
    final boxW = w * 0.5;
    final boxH = h * 0.14;
    canvas.drawRect(Rect.fromLTWH((w - boxW) / 2, m, boxW, boxH), line); // oben
    canvas.drawRect(
      Rect.fromLTWH((w - boxW) / 2, h - m - boxH, boxW, boxH),
      line,
    ); // unten

    // Torräume (klein).
    final smallW = w * 0.25;
    final smallH = h * 0.06;
    canvas.drawRect(Rect.fromLTWH((w - smallW) / 2, m, smallW, smallH), line);
    canvas.drawRect(
      Rect.fromLTWH((w - smallW) / 2, h - m - smallH, smallW, smallH),
      line,
    );
  }

  @override
  bool shouldRepaint(covariant PitchFieldPainter oldDelegate) =>
      oldDelegate.lineColor != lineColor;
}

/// Eine Position (Slot) auf dem Feld in relativen Koordinaten (0..1).
class PitchSlot {
  final int index;
  final double x;
  final double y;
  final String label;
  const PitchSlot(this.index, this.x, this.y, this.label);
}

/// Erzeugt die Positions-Slots aus einer Formation wie "4-4-2".
/// Slot 0 ist immer der Torwart (unten). Danach die Feldlinien von der Abwehr
/// (unten) bis zum Angriff (oben).
List<PitchSlot> slotsForFormation(String formation) {
  List<int> lines;
  try {
    lines = formation
        .split('-')
        .map((s) => int.parse(s.trim()))
        .where((n) => n > 0)
        .toList();
  } catch (_) {
    lines = [4, 4, 2];
  }
  if (lines.isEmpty) lines = [4, 4, 2];

  final slots = <PitchSlot>[];
  var idx = 0;
  slots.add(PitchSlot(idx++, 0.5, 0.90, 'TW'));

  final rows = lines.length;
  for (var r = 0; r < rows; r++) {
    final n = lines[r];
    final y = rows == 1 ? 0.45 : 0.74 - 0.60 * (r / (rows - 1));
    final label = r == 0 ? 'ABW' : (r == rows - 1 ? 'ANG' : 'MIT');
    for (var i = 0; i < n; i++) {
      final x = (i + 1) / (n + 1);
      slots.add(PitchSlot(idx++, x, y, label));
    }
  }
  return slots;
}
