import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/enums.dart';
import '../models/player.dart';
import '../screens/paste_import_screen.dart';
import '../screens/player_detail_screen.dart';
import '../state/app_state.dart';
import 'player_avatar.dart';
import 'player_edit_dialog.dart';

/// Zeigt den Kader eines Teams und erlaubt Hinzufügen/Bearbeiten/Löschen
/// sowie den Einfügen-Import. Wird für das eigene Team und (zur manuellen
/// Ergänzung) für den Gegner genutzt.
class SquadListView extends StatelessWidget {
  const SquadListView({
    super.key,
    required this.teamId,
    this.teamName = 'Team',
    this.fupaUrl,
    this.emptyHint = 'Noch keine Spieler. Jetzt welche hinzufügen oder einfügen.',
    this.showActions = true,
    this.onlyPlayerIds,
  });

  final String teamId;
  final String teamName;
  final String? fupaUrl;
  final String emptyHint;

  /// Zeigt die Buttons „Hinzufügen"/„Einfügen" (im Spielcenter ausgeblendet).
  final bool showActions;

  /// Wenn gesetzt, werden nur diese Spieler angezeigt (z.B. nur Nominierte).
  final Set<String>? onlyPlayerIds;

  @override
  Widget build(BuildContext context) {
    // Lauscht auf Änderungen, damit nach Add/Edit/Delete neu geladen wird.
    final state = context.watch<AppState>();
    return FutureBuilder<_SquadData>(
      future: _load(state),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        var players = snap.data!.players;
        final cards = snap.data!.cardCounts;
        final ratings = snap.data!.ratings;
        if (onlyPlayerIds != null) {
          players =
              players.where((p) => onlyPlayerIds!.contains(p.id)).toList();
        }
        if (players.isEmpty) {
          if (!showActions) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  onlyPlayerIds != null
                      ? 'Noch keine Spieler nominiert.\nÜber „Nominierung" zusagen.'
                      : emptyHint,
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return _EmptyState(
            hint: emptyHint,
            onAdd: () => _add(context),
            onPaste: () => _pasteImport(context),
          );
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
                    leading: PlayerAvatar(player: p),
                    title: Row(
                      children: [
                        Flexible(
                            child: Text(p.fullName,
                                maxLines: 1, overflow: TextOverflow.ellipsis)),
                        if (p.captainRole != CaptainRole.none) ...[
                          const SizedBox(width: 6),
                          Text(p.captainRole.badge,
                              style: TextStyle(
                                  color:
                                      Theme.of(context).colorScheme.primary)),
                        ],
                        if (p.status != PlayerStatus.fit) ...[
                          const SizedBox(width: 6),
                          Text(p.status.symbol,
                              style: const TextStyle(fontSize: 13)),
                        ],
                      ],
                    ),
                    subtitle: _subtitle(p, cards[p.id], ratings[p.id]),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => PlayerDetailScreen(player: p),
                      ),
                    ),
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
            if (showActions)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _add(context),
                        icon: const Icon(Icons.person_add),
                        label: const Text('Hinzufügen'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.tonalIcon(
                        onPressed: () => _pasteImport(context),
                        icon: const Icon(Icons.content_paste),
                        label: const Text('Einfügen'),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  Future<_SquadData> _load(AppState state) async {
    final players = await state.playersOf(teamId);
    final cards = await state.cardCountsForTeam(teamId);
    final ratings = await state.ratingAveragesForTeam(teamId);
    return _SquadData(players, cards, ratings);
  }

  /// Untertitel mit Position, Bewertungsschnitt und – falls vorhanden –
  /// Karten-Badges.
  Widget? _subtitle(Player p, Map<CardType, int>? cards, (double, int)? rating) {
    final parts = <Widget>[];
    if (p.position != null) parts.add(Text(p.position!));
    if (rating != null) {
      parts.add(Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.star, size: 13, color: Colors.amber.shade700),
          const SizedBox(width: 2),
          Text(rating.$1.toStringAsFixed(1)),
        ],
      ));
    }
    if (cards != null && cards.isNotEmpty) {
      final badges = <String>[
        for (final t in CardType.values)
          if ((cards[t] ?? 0) > 0) '${t.symbol} ${cards[t]}',
      ];
      if (badges.isNotEmpty) parts.add(Text(badges.join('  ')));
    }
    if (parts.isEmpty) return null;
    return Row(
      children: [
        for (var i = 0; i < parts.length; i++) ...[
          if (i > 0) const Text('  ·  '),
          parts[i],
        ],
      ],
    );
  }

  Future<void> _pasteImport(BuildContext context) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PasteImportScreen(
          teamId: teamId,
          teamName: teamName,
          fupaUrl: fupaUrl,
        ),
      ),
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
          wishPosition: data.wishPosition,
          status: data.status,
          captainRole: data.captainRole,
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
          wishPosition: data.wishPosition,
          status: data.status,
          captainRole: data.captainRole,
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

class _SquadData {
  final List<Player> players;
  final Map<String, Map<CardType, int>> cardCounts;
  final Map<String, (double, int)> ratings;
  const _SquadData(this.players, this.cardCounts, this.ratings);
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.hint,
    required this.onAdd,
    required this.onPaste,
  });
  final String hint;
  final VoidCallback onAdd;
  final VoidCallback onPaste;

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
              onPressed: onPaste,
              icon: const Icon(Icons.content_paste),
              label: const Text('Liste einfügen'),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.person_add),
              label: const Text('Einzeln hinzufügen'),
            ),
          ],
        ),
      ),
    );
  }
}
