import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/card_entry.dart';
import '../models/enums.dart';
import '../models/player.dart';
import '../state/app_state.dart';
import '../widgets/player_avatar.dart';

class PlayerDetailScreen extends StatelessWidget {
  const PlayerDetailScreen({super.key, required this.player});
  final Player player;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final df = DateFormat('dd.MM.yyyy', 'de_DE');

    return Scaffold(
      appBar: AppBar(title: Text(player.fullName)),
      body: ListView(
        children: [
          _header(context),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Row(
              children: [
                Text('Karten',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => _addCard(context),
                  icon: const Icon(Icons.add),
                  label: const Text('Karte'),
                ),
              ],
            ),
          ),
          FutureBuilder<List<CardEntry>>(
            future: state.cardsOf(player.id),
            builder: (context, snap) {
              if (!snap.hasData) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: LinearProgressIndicator(),
                );
              }
              final cards = snap.data!;
              return Column(
                children: [
                  _cardSummary(context, cards),
                  if (cards.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('Noch keine Karten erfasst.',
                          style: TextStyle(color: Colors.grey)),
                    )
                  else
                    ...cards.map((c) => Dismissible(
                          key: ValueKey(c.id),
                          direction: DismissDirection.endToStart,
                          background: Container(
                            color: Colors.red,
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.only(right: 20),
                            child: const Icon(Icons.delete, color: Colors.white),
                          ),
                          onDismissed: (_) =>
                              context.read<AppState>().deleteCard(c.id),
                          child: ListTile(
                            leading: Text(c.type.symbol,
                                style: const TextStyle(fontSize: 22)),
                            title: Text(c.type.label),
                            subtitle: Text([
                              df.format(c.date),
                              if (c.minute != null) "${c.minute}'",
                              if (c.note != null && c.note!.isNotEmpty) c.note!,
                            ].join('  ·  ')),
                            onTap: () => _editCard(context, c),
                          ),
                        )),
                  const SizedBox(height: 24),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          PlayerAvatar(player: player, radius: 34),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(player.fullName,
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 4),
                Text([
                  if (player.number != null) 'Nr. ${player.number}',
                  if (player.position != null) player.position!,
                ].join('  ·  ')),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _cardSummary(BuildContext context, List<CardEntry> cards) {
    int count(CardType t) => cards.where((c) => c.type == t).length;
    Widget pill(CardType t) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Chip(
            avatar: Text(t.symbol, style: const TextStyle(fontSize: 14)),
            label: Text('${count(t)}'),
            visualDensity: VisualDensity.compact,
          ),
        );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          pill(CardType.yellow),
          pill(CardType.yellowRed),
          pill(CardType.red),
        ],
      ),
    );
  }

  Future<void> _addCard(BuildContext context) async {
    final data = await showCardDialog(context);
    if (data == null || !context.mounted) return;
    await context.read<AppState>().addCard(
          playerId: player.id,
          type: data.type,
          date: data.date,
          note: data.note,
        );
  }

  Future<void> _editCard(BuildContext context, CardEntry card) async {
    final data = await showCardDialog(context, existing: card);
    if (data == null || !context.mounted) return;
    await context.read<AppState>().updateCard(
          card.copyWith(type: data.type, date: data.date, note: data.note),
        );
  }
}

class CardDialogData {
  final CardType type;
  final DateTime date;
  final String? note;
  const CardDialogData(this.type, this.date, this.note);
}

Future<CardDialogData?> showCardDialog(BuildContext context,
    {CardEntry? existing}) {
  var type = existing?.type ?? CardType.yellow;
  var date = existing?.date ?? DateTime.now();
  final noteCtrl = TextEditingController(text: existing?.note ?? '');
  final df = DateFormat('dd.MM.yyyy', 'de_DE');

  return showDialog<CardDialogData>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(existing == null ? 'Karte hinzufügen' : 'Karte bearbeiten'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SegmentedButton<CardType>(
              segments: const [
                ButtonSegment(value: CardType.yellow, label: Text('🟨')),
                ButtonSegment(value: CardType.yellowRed, label: Text('🟨🟥')),
                ButtonSegment(value: CardType.red, label: Text('🟥')),
              ],
              selected: {type},
              onSelectionChanged: (s) => setState(() => type = s.first),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: date,
                  firstDate: DateTime(date.year - 2),
                  lastDate: DateTime(date.year + 1),
                );
                if (picked != null) setState(() => date = picked);
              },
              icon: const Icon(Icons.event),
              label: Text(df.format(date)),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: noteCtrl,
              decoration: const InputDecoration(labelText: 'Grund / Notiz'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Abbrechen')),
          FilledButton(
            onPressed: () => Navigator.pop(
              context,
              CardDialogData(type, date,
                  noteCtrl.text.trim().isEmpty ? null : noteCtrl.text.trim()),
            ),
            child: const Text('Speichern'),
          ),
        ],
      ),
    ),
  );
}
