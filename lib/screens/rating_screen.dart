import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/match.dart';
import '../models/player.dart';
import '../models/player_rating.dart';
import '../state/app_state.dart';
import '../widgets/player_avatar.dart';

/// Bewertungs-Screen nach dem Spiel: 1–5 Sterne je Spieler. Jederzeit
/// aufrufbar (aus dem Spielcenter und direkt nach Abpfiff) und editierbar.
/// Der Gesamtschnitt eines Spielers (Spieler-Detail) ergibt sich automatisch
/// als Durchschnitt aller seiner Bewertungen.
class RatingScreen extends StatefulWidget {
  const RatingScreen({super.key, required this.matchId});
  final String matchId;

  @override
  State<RatingScreen> createState() => _RatingScreenState();
}

class _RatingScreenState extends State<RatingScreen> {
  GameMatch? _match;
  List<Player> _roster = [];
  Map<String, PlayerRating> _ratings = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    final match = await state.getMatch(widget.matchId);
    if (match == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final players = await state.playersOf(match.ownTeamId);
    final byId = {for (final p in players) p.id: p};

    // Zu bewerten sind nur Spieler, die gespielt haben (Startelf + Einge-
    // wechselte); ohne Aufstellung ersatzweise die zugesagten Nominierten.
    final playedIds = await state.playedPlayerIds(widget.matchId, match.ownTeamId);
    final roster = <Player>[
      for (final id in playedIds)
        if (byId[id] != null) byId[id]!,
    ]..sort((a, b) {
        final an = a.number ?? 9999, bn = b.number ?? 9999;
        return an != bn ? an.compareTo(bn) : a.lastName.compareTo(b.lastName);
      });

    final ratings = await state.ratingsMapOf(widget.matchId);
    if (!mounted) return;
    setState(() {
      _match = match;
      _roster = roster;
      _ratings = ratings;
      _loading = false;
    });
  }

  Future<void> _setStars(Player p, int stars) async {
    final state = context.read<AppState>();
    await state.setRating(
        matchId: widget.matchId, playerId: p.id, rating: stars.toDouble());
    final updated = await state.ratingsMapOf(widget.matchId);
    if (mounted) setState(() => _ratings = updated);
  }

  Future<void> _clear(Player p) async {
    final state = context.read<AppState>();
    await state.removeRating(widget.matchId, p.id);
    final updated = await state.ratingsMapOf(widget.matchId);
    if (mounted) setState(() => _ratings = updated);
  }

  Future<void> _editNote(Player p) async {
    final current = _ratings[p.id];
    final ctrl = TextEditingController(text: current?.note ?? '');
    final note = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Notiz zu ${p.fullName}'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(hintText: 'Kurze Bewertung …'),
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
    if (note == null || !mounted) return;
    final state = context.read<AppState>();
    final stars = current?.rating ?? 3.0;
    await state.setRating(
      matchId: widget.matchId,
      playerId: p.id,
      rating: stars,
      note: note.isEmpty ? null : note,
      keepNote: false,
    );
    final updated = await state.ratingsMapOf(widget.matchId);
    if (mounted) setState(() => _ratings = updated);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final match = _match;
    if (match == null) {
      return const Scaffold(body: Center(child: Text('Spiel nicht gefunden.')));
    }
    final rated = _ratings.length;
    return Scaffold(
      appBar: AppBar(title: Text('Bewertung • vs ${match.opponentName}')),
      body: _roster.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Keine Spieler zum Bewerten.\n'
                  'Erst nominieren bzw. aufstellen.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Row(
                    children: [
                      Icon(Icons.star,
                          size: 16,
                          color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 6),
                      Text('$rated von ${_roster.length} bewertet',
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.separated(
                    itemCount: _roster.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final p = _roster[i];
                      final r = _ratings[p.id];
                      final stars = r?.rating.round() ?? 0;
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        child: Row(
                          children: [
                            PlayerAvatar(player: p),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(p.fullName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis),
                                  _StarRow(
                                    value: stars,
                                    onTap: (s) => _setStars(p, s),
                                  ),
                                  if (r?.note != null && r!.note!.isNotEmpty)
                                    Text(r.note!,
                                        style:
                                            Theme.of(context).textTheme.bodySmall,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: 'Notiz',
                              icon: Icon(
                                Icons.sticky_note_2_outlined,
                                size: 20,
                                color: (r?.note != null && r!.note!.isNotEmpty)
                                    ? Theme.of(context).colorScheme.primary
                                    : null,
                              ),
                              onPressed: () => _editNote(p),
                            ),
                            if (stars > 0)
                              IconButton(
                                tooltip: 'Bewertung entfernen',
                                icon: const Icon(Icons.close, size: 18),
                                onPressed: () => _clear(p),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}

/// Reihe aus 5 antippbaren Sternen.
class _StarRow extends StatelessWidget {
  const _StarRow({required this.value, required this.onTap});
  final int value;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 1; i <= 5; i++)
          IconButton(
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
            icon: Icon(
              i <= value ? Icons.star : Icons.star_border,
              color: Colors.amber.shade700,
              size: 26,
            ),
            onPressed: () => onTap(i),
          ),
      ],
    );
  }
}
