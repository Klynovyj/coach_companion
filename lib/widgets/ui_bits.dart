import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Kleiner Datums-Block (Wochentag · Tag · Monat) im SpielerPlus-Stil.
class DateBlock extends StatelessWidget {
  const DateBlock({super.key, required this.date, this.highlight = false});

  final DateTime? date;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = highlight ? scheme.primary : scheme.primaryContainer;
    final fg = highlight ? scheme.onPrimary : scheme.onPrimaryContainer;
    final d = date;
    return Container(
      width: 48,
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: d == null
            ? [
                Text('—',
                    style: TextStyle(
                        color: fg, fontWeight: FontWeight.bold, fontSize: 18)),
              ]
            : [
                Text(DateFormat('EEE', 'de_DE').format(d).toUpperCase(),
                    style: TextStyle(
                        color: fg, fontSize: 10, fontWeight: FontWeight.w600)),
                Text(DateFormat('dd').format(d),
                    style: TextStyle(
                        color: fg, fontSize: 18, fontWeight: FontWeight.w800)),
                Text(DateFormat('MMM', 'de_DE').format(d),
                    style: TextStyle(color: fg, fontSize: 10)),
              ],
      ),
    );
  }
}

/// Farbige Pille mit Text (z.B. Ergebnis, Status, Wettbewerb).
class Pill extends StatelessWidget {
  const Pill({
    super.key,
    required this.text,
    this.color,
    this.filled = false,
  });

  final String text;
  final Color? color;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: filled ? c : c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(text,
          style: TextStyle(
            color: filled ? Colors.white : c,
            fontWeight: FontWeight.w700,
            fontSize: 12,
          )),
    );
  }
}

/// Einheitliche Abschnitts-Überschrift mit optionaler Aktion.
class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.title, this.action});

  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 4),
      child: Row(
        children: [
          Text(title,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w800)),
          const Spacer(),
          ?action,
        ],
      ),
    );
  }
}
