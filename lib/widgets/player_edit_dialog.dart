import 'package:flutter/material.dart';

import '../models/enums.dart';
import '../models/player.dart';

/// Ergebnis des Spieler-Dialogs.
class PlayerEditData {
  final String firstName;
  final String lastName;
  final int? number;
  final String? position;
  final String? wishPosition;
  final PlayerStatus status;
  final CaptainRole captainRole;
  const PlayerEditData(this.firstName, this.lastName, this.number,
      this.position, this.wishPosition, this.status, this.captainRole);
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
  final wishCtrl = TextEditingController(text: existing?.wishPosition ?? '');
  var status = existing?.status ?? PlayerStatus.fit;
  var captain = existing?.captainRole ?? CaptainRole.none;
  final formKey = GlobalKey<FormState>();

  return showDialog<PlayerEditData>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title:
            Text(existing == null ? 'Spieler hinzufügen' : 'Spieler bearbeiten'),
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
                const SizedBox(height: 10),
                TextFormField(
                  controller: wishCtrl,
                  decoration:
                      const InputDecoration(labelText: 'Wunschposition'),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<PlayerStatus>(
                  initialValue: status,
                  decoration: const InputDecoration(labelText: 'Status'),
                  items: PlayerStatus.values
                      .map((s) => DropdownMenuItem(
                          value: s, child: Text('${s.symbol} ${s.label}')))
                      .toList(),
                  onChanged: (v) => setState(() => status = v ?? status),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<CaptainRole>(
                  initialValue: captain,
                  decoration:
                      const InputDecoration(labelText: 'Kapitäns-Rolle'),
                  items: CaptainRole.values
                      .map((c) => DropdownMenuItem(
                          value: c,
                          child: Text(c == CaptainRole.none
                              ? 'Keine'
                              : '${c.badge} ${c.label}')))
                      .toList(),
                  onChanged: (v) => setState(() => captain = v ?? captain),
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
                  wishCtrl.text.trim().isEmpty ? null : wishCtrl.text.trim(),
                  status,
                  captain,
                ),
              );
            },
            child: const Text('Speichern'),
          ),
        ],
      ),
    ),
  );
}
