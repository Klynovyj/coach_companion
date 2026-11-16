import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Farben für Verlaufs-Linien (bis 6 Reihen gut unterscheidbar).
const kStatSeriesColors = <Color>[
  Color(0xFF1B5E20),
  Color(0xFFD32F2F),
  Color(0xFF1565C0),
  Color(0xFFEF6C00),
  Color(0xFF6A1B9A),
  Color(0xFF00838F),
];

/// Ein Balken der Rangliste.
class StatBarItem {
  const StatBarItem({required this.label, required this.value, this.text});
  final String label;
  final num? value;

  /// Angezeigter Wert (formatiert); Standard = [value].
  final String? text;
}

/// Horizontale Balken-Rangliste (ohne Zusatzpaket). Negative Werte rot.
class StatBarList extends StatelessWidget {
  const StatBarList({super.key, required this.items, this.labelWidth = 130});

  final List<StatBarItem> items;
  final double labelWidth;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final maxAbs = items.fold<num>(
      0,
      (a, b) => math.max(a, (b.value ?? 0).abs()),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final it in items)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                SizedBox(
                  width: labelWidth,
                  child: Text(
                    it.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, c) {
                      final v = it.value ?? 0;
                      final f = maxAbs == 0 ? 0.0 : v.abs() / maxAbs;
                      return Row(
                        children: [
                          Container(
                            height: 20,
                            width: math.max(2, (c.maxWidth - 52) * f),
                            decoration: BoxDecoration(
                              color: it.value == null
                                  ? Colors.transparent
                                  : v < 0
                                  ? Colors.red.shade400
                                  : scheme.primary,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            it.text ?? '${it.value ?? '–'}',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Eine Linie im Verlauf.
class StatLineSeries {
  const StatLineSeries({
    required this.label,
    required this.color,
    required this.values,
  });
  final String label;
  final Color color;
  final List<num?> values;
}

/// Liniendiagramm „Verlauf über Spiele" mit Legende.
class StatLineChart extends StatelessWidget {
  const StatLineChart({
    super.key,
    required this.xLabels,
    required this.series,
    this.height = 220,
    this.decimals = 0,
  });

  final List<String> xLabels;
  final List<StatLineSeries> series;
  final double height;
  final int decimals;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: height,
          width: double.infinity,
          child: CustomPaint(
            painter: _LinePainter(
              xLabels: xLabels,
              series: series,
              grid: theme.dividerColor,
              text: theme.hintColor,
              decimals: decimals,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 4,
          children: [
            for (final s in series)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(width: 14, height: 4, color: s.color),
                  const SizedBox(width: 4),
                  Text(s.label, style: const TextStyle(fontSize: 12)),
                ],
              ),
          ],
        ),
      ],
    );
  }
}

class _LinePainter extends CustomPainter {
  _LinePainter({
    required this.xLabels,
    required this.series,
    required this.grid,
    required this.text,
    required this.decimals,
  });

  final List<String> xLabels;
  final List<StatLineSeries> series;
  final Color grid;
  final Color text;
  final int decimals;

  void _text(
    Canvas c,
    String s,
    Offset at, {
    double size = 10,
    bool right = false,
    bool center = false,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(fontSize: size, color: text),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    var dx = at.dx;
    if (right) dx -= tp.width;
    if (center) dx -= tp.width / 2;
    tp.paint(c, Offset(dx, at.dy - tp.height / 2));
  }

  String _fmt(num v) => decimals == 0 && v == v.roundToDouble()
      ? v.round().toString()
      : v.toStringAsFixed(decimals == 0 ? 1 : decimals).replaceAll('.', ',');

  @override
  void paint(Canvas canvas, Size size) {
    const left = 34.0, bottom = 34.0, top = 8.0, right = 8.0;
    final w = size.width - left - right;
    final h = size.height - top - bottom;
    final n = xLabels.length;
    if (n == 0 || w <= 0 || h <= 0) return;

    num lo = 0, hi = 0;
    for (final s in series) {
      for (final v in s.values) {
        if (v == null) continue;
        lo = math.min(lo, v);
        hi = math.max(hi, v);
      }
    }
    if (hi == lo) hi = lo + 1;
    // Schöne Obergrenze.
    final span = (hi - lo).toDouble();
    final step = _niceStep(span / 4);
    final yMin = (lo / step).floor() * step;
    final yMax = (hi / step).ceil() * step;
    double y(num v) => top + h - (v - yMin) / (yMax - yMin) * h;
    double x(int i) => left + (n == 1 ? w / 2 : w * i / (n - 1));

    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (var v = yMin; v <= yMax + step / 2; v += step) {
      final yy = y(v);
      canvas.drawLine(Offset(left, yy), Offset(left + w, yy), gridPaint);
      _text(canvas, _fmt(v), Offset(left - 4, yy), right: true);
    }

    // X-Beschriftung: höchstens ~8 Labels, gedreht wäre unruhig.
    final every = math.max(1, (n / 8).ceil());
    for (var i = 0; i < n; i += every) {
      _text(canvas, xLabels[i], Offset(x(i), top + h + 12), center: true);
    }

    for (final s in series) {
      final line = Paint()
        ..color = s.color
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke;
      final dot = Paint()..color = s.color;
      Offset? prev;
      for (var i = 0; i < s.values.length && i < n; i++) {
        final v = s.values[i];
        if (v == null) {
          prev = null;
          continue;
        }
        final p = Offset(x(i), y(v));
        if (prev != null) canvas.drawLine(prev, p, line);
        canvas.drawCircle(p, 3.5, dot);
        prev = p;
      }
    }
  }

  static double _niceStep(double raw) {
    if (raw <= 0) return 1;
    final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
    final f = raw / mag;
    final nice = f <= 1
        ? 1
        : f <= 2
        ? 2
        : f <= 5
        ? 5
        : 10;
    return math.max(nice * mag, 0.5);
  }

  @override
  bool shouldRepaint(covariant _LinePainter old) => true;
}
