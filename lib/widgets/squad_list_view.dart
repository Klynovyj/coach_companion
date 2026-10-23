import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/player.dart';
import '../state/app_state.dart';
import 'player_edit_dialog.dart';

/// Zeigt den Kader eines Teams und erlaubt Hinzufügen/Bearbeiten/Löschen.
/// Wird für das eigene Team und (zur manuellen Ergänzung) für den Gegner genutzt.
class SquadListView extends StatelessWidget {
  const SquadListView({
    super.key,
    required this.teamId,
    this.emptyHint = 'Noch keine Spieler. Jetzt welche hinzufügen.',
  });

  final String teamId;
  final String emptyHint;

  @override
  Widget build(BuildContext context) {
    // Lauscht auf Änderungen, damit nach Add/Edit/Delete neu geladen wird.
    final state = context.watch<AppState>();
    return FutureBuilder<List<Player>>(
      future: state.playersOf(teamId),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final players = snap.data!;
        if (players.isEmpty) {
          return _EmptyState(hint: emptyHint, onAdd: () => _add(context));
        }
        return Column(
          children: [
            Expanded(
              child: ListView.separated(
                itemCount: players.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final p = players[i];
                  return ListTile(
                    leading: CircleAvatar(
                      child: Text(p.number?.toString() ??
                          (p.lastName.isNotEmpty ? p.lastName[0] : '?')),
                    ),
                    title: Text(p.fullName),
                    subtitle: p.position == null ? null : Text(p.position!),
                    trailing: PopupMenuButton<String>(
                      onSelected: (v) {
                        if (v == 'edit') _edit(context, p);
                        if (v == 'delete') _delete(context, p);
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'edit', child: Text('Bearbeiten')),
                        PopupMenuItem(value: 'delete', child: Text('Löschen')),
                      ],
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => _add(context),
                  icon: const Icon(Icons.person_add),
                  label: const Text('Spieler hinzufügen'),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _add(BuildContext context) async {
    final data = await showPlayerEditDialog(context);
    if (data == null || !context.mounted) return;
    await context.read<AppState>().addPlayer(
          teamId,
          firstName: data.firstName,
          lastName: data.lastName,
          number: data.number,
          position: data.position,
        );
  }

  Future<void> _edit(BuildContext context, Player p) async {
    final data = await showPlayerEditDialog(context, existing: p);
    if (data == null || !context.mounted) return;
    await context.read<AppState>().updatePlayer(p.copyWith(
          firstName: data.firstName,
          lastName: data.lastName,
          number: data.number,
          clearNumber: data.number == null,
          position: data.position,
        ));
  }

  Future<void> _delete(BuildContext context, Player p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Spieler löschen?'),
        content: Text('„${p.fullName}" wirklich entfernen?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Löschen')),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await context.read<AppState>().deletePlayer(p.id);
    }
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.hint, required this.onAdd});
  final String hint;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.group_off, size: 48, color: Colors.grey),
            const SizedBox(height: 12),
            Text(hint, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.person_add),
              label: const Text('Spieler hinzufügen'),
            ),
          ],
        ),
      ),
    );
  }
}
