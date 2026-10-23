import 'package:flutter/material.dart';

/// Scouting-Marker für Gegner-Spieler (besondere Ereignisse/Eigenschaften).
/// „Viele Tore" wird nicht hier abgebildet, sondern automatisch aus der
/// importierten Torschützen-Statistik.
enum ScoutMarker {
  verletzt('verletzt', 'Verletzt', Icons.healing),
  gesperrt('gesperrt', 'Gesperrt', Icons.block),
  schnell('schnell', 'Schnell', Icons.bolt),
  kopfball('kopfball', 'Kopfballstark', Icons.sports_handball),
  standards('standards', 'Standards', Icons.sports_soccer),
  aufpassen('aufpassen', 'Aufpassen', Icons.warning_amber);

  const ScoutMarker(this.storageKey, this.label, this.icon);

  final String storageKey;
  final String label;
  final IconData icon;

  static ScoutMarker? fromKey(String? key) {
    for (final m in ScoutMarker.values) {
      if (m.storageKey == key) return m;
    }
    return null;
  }
}
