import 'package:flutter/material.dart';

/// Auswahl, was beim Zurücksetzen eines Spiels gelöscht wird.
class ResetChoice {
  final bool verlauf; // Ereignisse/Protokoll, Spielstand, Status
  final bool aufstellung;
  final bool nominierung;
  const ResetChoice(this.verlauf, this.aufstellung, this.nominierung);

  bool get any => verlauf || aufstellung || nominierung;
}

/// Zeigt den Reset-Dialog mit Häkchen und Sicherheitsabfrage.
Future<ResetChoice?> showResetMatchDialog(BuildContext context) {
  var verlauf = true;
  var aufstellung = false;
  var nominierung = false;

  return showDialog<ResetChoice>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Spiel zurücksetzen'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Was soll gelöscht werden? Das kann nicht rückgängig '
              'gemacht werden.',
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              value: verlauf,
              onChanged: (v) => setState(() => verlauf = v ?? false),
              title: const Text('Spielverlauf'),
              subtitle: const Text(
                'Protokoll, Tore, Karten, Wechsel, Stand 0:0',
              ),
              contentPadding: EdgeInsets.zero,
            ),
            CheckboxListTile(
              value: aufstellung,
              onChanged: (v) => setState(() => aufstellung = v ?? false),
              title: const Text('Aufstellung'),
              contentPadding: EdgeInsets.zero,
            ),
            CheckboxListTile(
              value: nominierung,
              onChanged: (v) => setState(() => nominierung = v ?? false),
              title: const Text('Nominierung'),
              contentPadding: EdgeInsets.zero,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: (verlauf || aufstellung || nominierung)
                ? () => Navigator.pop(
                    context,
                    ResetChoice(verlauf, aufstellung, nominierung),
                  )
                : null,
            child: const Text('Zurücksetzen'),
          ),
        ],
      ),
    ),
  );
}
