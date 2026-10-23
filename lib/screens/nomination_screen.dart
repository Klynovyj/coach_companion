import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/enums.dart';
import '../models/player.dart';
import '../services/share_service.dart';
import '../state/app_state.dart';
import '../widgets/availability_controls.dart';
import '../widgets/player_avatar.dart';

class NominationScreen extends StatefulWidget {
  const NominationScreen({
    super.key,
    required this.matchId,
    required this.teamId,
    required this.title,
  });

  final String matchId;
  final String teamId;
  final String title;

  @override
  State<NominationScreen> createState() => _NominationScreenState();
}

class _NominationScreenState extends State<NominationScreen> {
  List<Player> _players = [];
  Map<String, NominationStatus> _status = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    final players = await state.playersOf(widget.teamId);
    final noms = await state.nominationsOf(widget.matchId);
    if (!mounted) return;
    setState(() {
      _players = players;
      _status = {for (final p in players) p.id: noms[p.id] ?? NominationStatus.open};
      _loading = false;
    });
  }

  NominationStatus _statusOf(Player p) =>
      _status[p.id] ?? NominationStatus.open;

  Future<void> _set(Player p, NominationStatus s) async {
    setState(() => _status[p.id] = s);
    await context.read<AppState>().setNomination(widget.matchId, p.id, s);
  }

  int _count(NominationStatus s) =>
      _players.where((p) => _statusOf(p) == s).length;

  Future<void> _share() async {
    final match = await context.read<AppState>().getMatch(widget.matchId);
    final text = buildNominationText(
      title: 'vs ${widget.title}',
      kickoff: match?.kickoff,
      players: _players,
      status: _status,
    );
    final ok = await shareViaWhatsApp(text);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('WhatsApp konnte nicht geöffnet werden.')),
      );
    }
  }

  Future<void> _bulk(NominationStatus s) async {
    setState(() {
      for (final p in _players) {
        _status[p.id] = s;
      }
    });
    await context.read<AppState>().setNominationBulk(
        widget.matchId, _players.map((p) => p.id).toList(), s);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(
        title: Text('Nominierung · ${widget.title}'),
        actions: [
          IconButton(
            tooltip: 'Nominierung teilen (WhatsApp)',
            icon: const Icon(Icons.share),
            onPressed: _share,
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'all_in') _bulk(NominationStatus.zugesagt);
              if (v == 'all_open') _bulk(NominationStatus.open);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'all_in', child: Text('Alle zusagen')),
              PopupMenuItem(value: 'all_open', child: Text('Alle auf offen')),
            ],
          ),
        ],
      ),
      body: _players.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('Noch keine Spieler im Kader.',
                    textAlign: TextAlign.center),
              ),
            )
          : Column(
              children: [
                _summary(),
                const Divider(height: 1),
                Expanded(
                  child: ListView.separated(
                    itemCount: _players.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) => _row(_players[i]),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _summary() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: AvailabilitySummary(counts: {
        for (final s in NominationStatus.values) s: _count(s),
      }),
    );
  }

  Widget _row(Player p) {
    return ListTile(
      leading: PlayerAvatar(player: p, radius: 18),
      title: Text(p.fullName),
      subtitle: p.position == null ? null : Text(p.position!),
      trailing: AvailabilityChoices(
        current: _statusOf(p),
        onChanged: (s) => _set(p, s),
      ),
    );
  }
}
