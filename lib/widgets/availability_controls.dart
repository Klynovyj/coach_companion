import 'package:flutter/material.dart';

import '../models/enums.dart';

/// Farbe je Verfügbarkeits-/Nominierungsstatus (SpielerPlus-Anmutung).
Color availabilityColor(NominationStatus s) {
  switch (s) {
    case NominationStatus.zugesagt:
      return const Color(0xFF2E7D32);
    case NominationStatus.unsicher:
      return const Color(0xFFF9A825);
    case NominationStatus.unterVorbehalt:
      return const Color(0xFFEF6C00);
    case NominationStatus.abgesagt:
      return const Color(0xFFC62828);
    case NominationStatus.open:
      return const Color(0xFF9E9E9E);
  }
}

/// Farbe je Spieler-Verfügbarkeitsstatus (Stammdaten).
Color playerStatusColor(PlayerStatus s) => switch (s) {
  PlayerStatus.fit => const Color(0xFF2E7D32), // Grün
  PlayerStatus.verletzt => const Color(0xFFD32F2F), // Rot (wie das Kreuz)
  PlayerStatus.krank => const Color(0xFFEF6C00), // Orange
  PlayerStatus.gesperrt => const Color(0xFF6A1B9A), // Violett
  PlayerStatus.urlaub => const Color(0xFF1565C0), // Blau
  PlayerStatus.abwesend => const Color(0xFF00796B), // Teal (z.B. Dienstreise)
  PlayerStatus.inaktiv => const Color(0xFF757575), // Grau
};

/// Drei runde Status-Buttons (Zu / Unsicher / Ab). Erneutes Tippen auf den
/// aktiven Status setzt zurück auf „offen".
class AvailabilityChoices extends StatelessWidget {
  const AvailabilityChoices({
    super.key,
    required this.current,
    required this.onChanged,
  });

  final NominationStatus current;
  final ValueChanged<NominationStatus> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _choice(NominationStatus.zugesagt, Icons.check),
        const SizedBox(width: 4),
        _choice(NominationStatus.unsicher, Icons.help_outline),
        const SizedBox(width: 4),
        _choice(NominationStatus.unterVorbehalt, Icons.flaky),
        const SizedBox(width: 4),
        _choice(NominationStatus.abgesagt, Icons.close),
      ],
    );
  }

  Widget _choice(NominationStatus s, IconData icon) {
    final selected = current == s;
    final c = availabilityColor(s);
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => onChanged(selected ? NominationStatus.open : s),
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: selected ? c : c.withValues(alpha: 0.12),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 20, color: selected ? Colors.white : c),
      ),
    );
  }
}

/// Zusammenfassungs-Pillen (Anzahl je Status).
class AvailabilitySummary extends StatelessWidget {
  const AvailabilitySummary({super.key, required this.counts});

  /// Anzahl je Status.
  final Map<NominationStatus, int> counts;

  @override
  Widget build(BuildContext context) {
    Widget chip(NominationStatus s, String label) {
      final c = availabilityColor(s);
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(radius: 5, backgroundColor: c),
            const SizedBox(width: 6),
            Text(
              '${counts[s] ?? 0} $label',
              style: TextStyle(color: c, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        chip(NominationStatus.zugesagt, 'zu'),
        chip(NominationStatus.unsicher, 'unsicher'),
        chip(NominationStatus.unterVorbehalt, 'Vorbehalt'),
        chip(NominationStatus.abgesagt, 'ab'),
        chip(NominationStatus.open, 'offen'),
      ],
    );
  }
}
