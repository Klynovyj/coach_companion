import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Verlaufsformen (Schlüssel → Anzeigename, Symbol).
const List<(String, String, IconData)> kGradShapes = [
  ('linear', 'Oben → unten', Icons.gradient),
  ('radial', 'Strahl', Icons.flare),
  ('diagonal', 'Diagonal', Icons.call_made),
];

/// Verlauf (oben → unten, Strahl oder diagonal) in [top]/[bottom].
Gradient bgGradient(String shape, Color top, Color bottom) => switch (shape) {
  'radial' => RadialGradient(
    center: const Alignment(0, -0.35),
    radius: 1.2,
    colors: [top, bottom],
  ),
  'diagonal' => LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [top, bottom],
  ),
  _ => LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [top, bottom],
  ),
};

/// Polygon-Muster („Splitter") mit Vignette über einem Verlauf – wie beim
/// Vergleich-Hintergrund. [strength] 0 = aus, 1 = normal, bis 1.5.
class BgPatternPainter extends CustomPainter {
  const BgPatternPainter(this.strength);

  final double strength;

  @override
  void paint(Canvas canvas, Size size) {
    if (strength <= 0) return;
    final rect = Offset.zero & size;
    canvas.save();
    canvas.clipRect(rect);
    final rnd = math.Random(11);
    final w = size.width;
    final h = size.height;
    for (var k = 0; k < 38; k++) {
      final c = Offset(
        (rnd.nextDouble() * 1.3 - 0.15) * w,
        (rnd.nextDouble() * 1.3 - 0.15) * h,
      );
      final r = (0.18 + rnd.nextDouble() * 0.35) * w;
      final a0 = rnd.nextDouble() * math.pi * 2;
      final path = Path();
      for (var j = 0; j < 3; j++) {
        final a = a0 + j * (math.pi * 2 / 3) + (rnd.nextDouble() - 0.5) * 1.1;
        final rr = r * (0.55 + rnd.nextDouble() * 0.45);
        final p = c + Offset(math.cos(a) * rr, math.sin(a) * rr);
        j == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
      path.close();
      final light = rnd.nextBool();
      final alpha = light
          ? 0.015 + rnd.nextDouble() * 0.045
          : 0.08 + rnd.nextDouble() * 0.14;
      canvas.drawPath(
        path,
        Paint()
          ..color = (light ? Colors.white : Colors.black).withValues(
            alpha: (alpha * strength).clamp(0.0, 1.0),
          ),
      );
    }
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          radius: 0.9,
          colors: [
            Colors.transparent,
            Colors.black.withValues(alpha: (0.45 * strength).clamp(0.0, 0.8)),
          ],
          stops: const [0.55, 1.0],
        ).createShader(rect),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(BgPatternPainter old) => old.strength != strength;
}

/// Bedien-Block für Grafik-Menüs: Verlaufsform (null = Standard des Layouts)
/// und Muster an/aus mit Stärke.
class BgStyleControls extends StatelessWidget {
  const BgStyleControls({
    super.key,
    required this.shape,
    required this.pattern,
    required this.onShape,
    required this.onPattern,
    this.allowDefault = true,
  });

  /// Gewählte Form; null = Standard (je Grafik unterschiedlich).
  final String? shape;

  /// Muster-Stärke, 0 = aus.
  final double pattern;
  final ValueChanged<String?> onShape;
  final ValueChanged<double> onPattern;
  final bool allowDefault;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Verlaufsform'),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            if (allowDefault)
              ChoiceChip(
                label: const Text('Standard'),
                selected: shape == null,
                onSelected: (_) => onShape(null),
              ),
            for (final (k, label, icon) in kGradShapes)
              ChoiceChip(
                avatar: Icon(icon, size: 18),
                label: Text(label),
                selected: shape == k,
                onSelected: (_) => onShape(k),
              ),
          ],
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Muster (Splitter)'),
          subtitle: const Text('Polygon-Muster über dem Verlauf'),
          value: pattern > 0,
          onChanged: (v) => onPattern(v ? 1.0 : 0),
        ),
        if (pattern > 0)
          Row(
            children: [
              const SizedBox(width: 60, child: Text('Stärke')),
              Expanded(
                child: Slider(
                  value: pattern.clamp(0.1, 1.5),
                  min: 0.1,
                  max: 1.5,
                  onChanged: onPattern,
                ),
              ),
              SizedBox(
                width: 44,
                child: Text(
                  '${(pattern * 100).round()}%',
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
      ],
    );
  }
}
