import 'package:flutter/material.dart';

/// Antippbare 1–5-Sterne-Reihe. Tippen auf den aktuell höchsten Stern lässt
/// die Bewertung bestehen; zum Entfernen gibt es außen einen eigenen Button.
class StarRating extends StatelessWidget {
  const StarRating({
    super.key,
    required this.value,
    required this.onTap,
    this.size = 26,
  });

  final int value;
  final ValueChanged<int> onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 1; i <= 5; i++)
          IconButton(
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: BoxConstraints(
              minWidth: size + 6,
              minHeight: size + 6,
            ),
            icon: Icon(
              i <= value ? Icons.star : Icons.star_border,
              color: Colors.amber.shade700,
              size: size,
            ),
            onPressed: () => onTap(i),
          ),
      ],
    );
  }
}
