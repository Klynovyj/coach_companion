import 'package:flutter/material.dart';

/// Rundet auf halbe Sterne (0 … 5).
double halfStars(double v) => ((v * 2).round() / 2).clamp(0, 5).toDouble();

IconData _starIcon(int i, double value) => value >= i
    ? Icons.star
    : (value >= i - 0.5 ? Icons.star_half : Icons.star_border);

/// Antippbare 0,5–5-Sterne-Reihe: linke Sternhälfte = halber Stern, rechte =
/// ganzer Stern. Tippen auf den aktuellen Wert lässt die Bewertung bestehen;
/// zum Entfernen gibt es außen einen eigenen Button.
class StarRating extends StatelessWidget {
  const StarRating({
    super.key,
    required this.value,
    required this.onTap,
    this.size = 26,
    this.enabled = true,
  });

  final double value;
  final ValueChanged<double> onTap;
  final double size;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final color = enabled ? Colors.amber.shade700 : Colors.grey;
    final box = size + 8;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 1; i <= 5; i++)
          Semantics(
            button: enabled,
            label: '$i Sterne',
            child: MouseRegion(
              cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
              child: GestureDetector(
                key: ValueKey('star_$i'),
                behavior: HitTestBehavior.opaque,
                onTapUp: enabled
                    ? (d) => onTap(
                        d.localPosition.dx < box / 2 ? i - 0.5 : i.toDouble(),
                      )
                    : null,
                child: SizedBox(
                  width: box,
                  height: box,
                  child: Center(
                    child: Icon(_starIcon(i, value), color: color, size: size),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Reine Anzeige mit halben Sternen (Schnitte werden auf 0,5 gerundet).
class StarDisplay extends StatelessWidget {
  const StarDisplay({super.key, required this.value, this.size = 18});

  final double value;
  final double size;

  @override
  Widget build(BuildContext context) {
    final v = halfStars(value);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 1; i <= 5; i++)
          Icon(_starIcon(i, v), size: size, color: Colors.amber.shade700),
      ],
    );
  }
}

/// Zahl mit halben Sternen für Texte, z. B. „3,5“ oder „4“.
String starNumber(double v) {
  final h = halfStars(v);
  return h % 1 == 0
      ? h.toStringAsFixed(0)
      : h.toStringAsFixed(1).replaceAll('.', ',');
}
