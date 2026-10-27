import 'package:flutter/material.dart';

/// Eine Statistik-Vergleichszeile (Wir vs. Gegner): zentrierte Bezeichnung,
/// darunter links die Wir-Zahl, ein zweifarbiger Vergleichsbalken und rechts
/// die Gegner-Zahl. Bei 0:0 ein blasser, gleich geteilter Balken.
class StatCompareRow extends StatelessWidget {
  const StatCompareRow({
    super.key,
    required this.label,
    required this.own,
    required this.opp,
    required this.ownColor,
    required this.oppColor,
  });

  final String label;
  final int own;
  final int opp;
  final Color ownColor;
  final Color oppColor;

  @override
  Widget build(BuildContext context) {
    final total = own + opp;
    const numStyle = TextStyle(fontWeight: FontWeight.bold, fontSize: 16);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        children: [
          Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              SizedBox(
                width: 34,
                child: Text(
                  '$own',
                  textAlign: TextAlign.right,
                  style: numStyle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Row(
                    children: [
                      Expanded(
                        flex: total == 0 ? 1 : own,
                        child: Container(
                          height: 10,
                          color: total == 0
                              ? ownColor.withValues(alpha: 0.2)
                              : ownColor,
                        ),
                      ),
                      Expanded(
                        flex: total == 0 ? 1 : opp,
                        child: Container(
                          height: 10,
                          color: total == 0
                              ? oppColor.withValues(alpha: 0.2)
                              : oppColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 34,
                child: Text('$opp', textAlign: TextAlign.left, style: numStyle),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
