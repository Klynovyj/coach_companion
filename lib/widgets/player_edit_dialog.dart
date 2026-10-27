import 'package:flutter/material.dart';

import '../models/player.dart';

/// Ergebnis des Spieler-Formulars (Status & Kapitäns-Rolle werden erst im
/// Profil gesetzt, nicht beim Anlegen).
class PlayerEditData {
  final String firstName;
  final String lastName;
  final int? number;
  final String? position;
  final String? wishPosition;
  const PlayerEditData(
    this.firstName,
    this.lastName,
    this.number,
    this.position,
    this.wishPosition,
  );
}

/// Vollbild-Formular zum Anlegen eines Spielers.
Future<PlayerEditData?> showPlayerEditDialog(
  BuildContext context, {
  Player? existing,
}) {
  return Navigator.push<PlayerEditData>(
    context,
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _PlayerAddPage(existing: existing),
    ),
  );
}

class _PlayerAddPage extends StatefulWidget {
  const _PlayerAddPage({this.existing});
  final Player? existing;

  @override
  State<_PlayerAddPage> createState() => _PlayerAddPageState();
}

class _PlayerAddPageState extends State<_PlayerAddPage> {
  late final TextEditingController _first;
  late final TextEditingController _last;
  late final TextEditingController _number;
  late final TextEditingController _pos;
  late final TextEditingController _wish;
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _first = TextEditingController(text: e?.firstName ?? '');
    _last = TextEditingController(text: e?.lastName ?? '');
    _number = TextEditingController(text: e?.number?.toString() ?? '');
    _pos = TextEditingController(text: e?.position ?? '');
    _wish = TextEditingController(text: e?.wishPosition ?? '');
  }

  @override
  void dispose() {
    _first.dispose();
    _last.dispose();
    _number.dispose();
    _pos.dispose();
    _wish.dispose();
    super.dispose();
  }

  void _save() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.pop(
      context,
      PlayerEditData(
        _first.text.trim(),
        _last.text.trim(),
        int.tryParse(_number.text.trim()),
        _pos.text.trim().isEmpty ? null : _pos.text.trim(),
        _wish.text.trim().isEmpty ? null : _wish.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Spieler hinzufügen'),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text(
              'Speichern',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _first,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Vorname',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _last,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Nachname',
                border: OutlineInputBorder(),
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) && _first.text.trim().isEmpty
                  ? 'Bitte einen Namen angeben'
                  : null,
            ),
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 90,
                  child: TextFormField(
                    controller: _number,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Nr.',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _pos,
                    decoration: const InputDecoration(
                      labelText: 'Position',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _wish,
              decoration: const InputDecoration(
                labelText: 'Wunschposition',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.check),
              label: const Text('Spieler anlegen'),
            ),
          ],
        ),
      ),
    );
  }
}
