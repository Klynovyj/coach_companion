import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/card_entry.dart';
import '../models/enums.dart';
import '../models/match.dart';
import '../models/match_event.dart';
import '../models/player.dart';
import '../models/player_note.dart';
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
          FutureBuilder<(List<CardEntry>, Map<String, GameMatch>)>(
            future: _loadCards(state),
            builder: (context, snap) {
              if (!snap.hasData) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: LinearProgressIndicator(),
                );
              }
              final cards = snap.data!.$1;
              final matches = snap.data!.$2;
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
                            subtitle: Text(_context(
                              df: df,
                              date: c.date,
                              match: c.matchId == null ? null : matches[c.matchId],
                              minuteLabel: c.minuteLabel,
                              note: c.note,
                            )),
                            onTap: () => _editCard(context, c),
                          ),
                        )),
                  const SizedBox(height: 8),
                ],
              );
            },
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('Tore & Vorlagen',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
          ),
          FutureBuilder<(List<MatchEvent>, Map<String, GameMatch>)>(
            future: _loadEvents(state),
            builder: (context, snap) {
              if (!snap.hasData) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: LinearProgressIndicator(),
                );
              }
              final events = snap.data!.$1
                  .where((e) => e.type == MatchEventType.goal)
                  .toList();
              if (events.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Noch keine Tore/Vorlagen erfasst.',
                      style: TextStyle(color: Colors.grey)),
                );
              }
              final matches = snap.data!.$2;
              return Column(
                children: events.map((e) {
                  final isScorer = e.playerId == player.id;
                  final m = matches[e.matchId];
                  return ListTile(
                    leading: Text(isScorer ? '⚽' : '🅰️',
                        style: const TextStyle(fontSize: 20)),
                    title: Text(isScorer ? 'Tor' : 'Vorlage'),
                    subtitle: Text(_context(
                      df: df,
                      date: m?.kickoff,
                      match: m,
                      minuteLabel: e.minuteLabel,
                      note: null,
                    )),
                  );
                }).toList(),
              );
            },
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Row(
              children: [
                Text('Notizen',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => _addNote(context),
                  icon: const Icon(Icons.add),
                  label: const Text('Notiz'),
                ),
              ],
            ),
          ),
          FutureBuilder<List<PlayerNote>>(
            future: state.notesOf(player.id),
            builder: (context, snap) {
              if (!snap.hasData) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: LinearProgressIndicator(),
                );
              }
              final notes = snap.data!;
              if (notes.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Noch keine Notizen.',
                      style: TextStyle(color: Colors.grey)),
                );
              }
              return Column(
                children: [
                  for (final n in notes)
                    Dismissible(
                      key: ValueKey(n.id),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        color: Colors.red,
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 20),
                        child: const Icon(Icons.delete, color: Colors.white),
                      ),
                      onDismissed: (_) =>
                          context.read<AppState>().deleteNote(n.id),
                      child: ListTile(
                        leading: const Icon(Icons.sticky_note_2_outlined),
                        title: Text(n.text),
                        subtitle: Text(df.format(n.createdAt)),
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Future<void> _addNote(BuildContext context) async {
    final ctrl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Notiz hinzufügen'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          minLines: 2,
          maxLines: 5,
          decoration: const InputDecoration(hintText: 'Beobachtung, Hinweis …'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () => Navigator.pop(context, ctrl.text.trim()),
              child: const Text('Speichern')),
        ],
      ),
    );
    if (text != null && text.isNotEmpty && context.mounted) {
      await context.read<AppState>().addNote(player.id, text);
    }
  }

  Future<(List<CardEntry>, Map<String, GameMatch>)> _loadCards(
      AppState s) async {
    final cards = await s.cardsOf(player.id);
    final mm = await s.matchMap(player.teamId);
    return (cards, mm);
  }

  Future<(List<MatchEvent>, Map<String, GameMatch>)> _loadEvents(
      AppState s) async {
    final events = await s.playerMatchEvents(player.id);
    final mm = await s.matchMap(player.teamId);
    return (events, mm);
  }

  /// Baut die Kontextzeile: Datum · vs Gegner · Minute · Notiz.
  String _context({
    required DateFormat df,
    DateTime? date,
    GameMatch? match,
    required String minuteLabel,
    String? note,
  }) {
    final parts = <String>[
      if (date != null) df.format(date.toLocal()),
      if (match != null) 'vs ${match.opponentName}',
      if (minuteLabel.isNotEmpty) minuteLabel,
      if (note != null && note.isNotEmpty) note,
    ];
    return parts.join('  ·  ');
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
                Row(
                  children: [
                    Flexible(
                      child: Text(player.fullName,
                          style: Theme.of(context).textTheme.titleLarge),
                    ),
                    if (player.captainRole != CaptainRole.none) ...[
                      const SizedBox(width: 8),
                      Text(player.captainRole.badge,
                          style: TextStyle(
                              fontSize: 18,
                              color: Theme.of(context).colorScheme.primary)),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text([
                  if (player.number != null) 'Nr. ${player.number}',
                  if (player.position != null) player.position!,
                  if (player.wishPosition != null)
                    'Wunsch: ${player.wishPosition}',
                ].join('  ·  ')),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _statusChip(context, player.status),
                    if (player.captainRole != CaptainRole.none)
                      Chip(
                        label: Text(
                            '${player.captainRole.badge} ${player.captainRole.label}'),
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusChip(BuildContext context, PlayerStatus s) {
    final color = switch (s) {
      PlayerStatus.fit => Colors.green,
      PlayerStatus.verletzt => Colors.orange,
      PlayerStatus.krank => Colors.amber.shade800,
      PlayerStatus.gesperrt => Colors.red,
    };
    return Chip(
      avatar: Text(s.symbol, style: const TextStyle(fontSize: 12)),
      label: Text(s.label),
      visualDensity: VisualDensity.compact,
      side: BorderSide(color: color),
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
