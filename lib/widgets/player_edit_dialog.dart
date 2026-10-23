import 'package:flutter/material.dart';

import '../models/player.dart';

/// Ergebnis des Spieler-Dialogs.
class PlayerEditData {
  final String firstName;
  final String lastName;
  final int? number;
  final String? position;
  const PlayerEditData(
      this.firstName, this.lastName, this.number, this.position);
}

/// Dialog zum Anlegen/Bearbeiten eines Spielers – für eigenes Team und Gegner.
Future<PlayerEditData?> showPlayerEditDialog(
  BuildContext context, {
  Player? existing,
}) {
  final firstCtrl = TextEditingController(text: existing?.firstName ?? '');
  final lastCtrl = TextEditingController(text: existing?.lastName ?? '');
  final numberCtrl =
      TextEditingController(text: existing?.number?.toString() ?? '');
  final posCtrl = TextEditingController(text: existing?.position ?? '');
  final formKey = GlobalKey<FormState>();

  return showDialog<PlayerEditData>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(existing == null ? 'Spieler hinzufügen' : 'Spieler bearbeiten'),
      content: Form(
        key: formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: firstCtrl,
                decoration: const InputDecoration(labelText: 'Vorname'),
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: lastCtrl,
                decoration: const InputDecoration(labelText: 'Nachname'),
                validator: (v) => (v == null || v.trim().isEmpty) &&
                        firstCtrl.text.trim().isEmpty
                    ? 'Bitte einen Namen angeben'
                    : null,
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: numberCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Nr.'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: TextFormField(
                      controller: posCtrl,
                      decoration:
                          const InputDecoration(labelText: 'Position'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          onPressed: () {
            if (!(formKey.currentState?.validate() ?? false)) return;
            Navigator.pop(
              context,
              PlayerEditData(
                firstCtrl.text.trim(),
                lastCtrl.text.trim(),
                int.tryParse(numberCtrl.text.trim()),
                posCtrl.text.trim().isEmpty ? null : posCtrl.text.trim(),
              ),
            );
          },
          child: const Text('Speichern'),
        ),
      ],
    ),
  );
}
