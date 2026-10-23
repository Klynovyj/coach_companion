import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/enums.dart';
import '../models/player.dart';
import '../state/app_state.dart';
import '../widgets/player_avatar.dart';

/// Farbe je Nominierungsstatus (SpielerPlus-Anmutung).
Color nominationColor(NominationStatus s) {
  switch (s) {
    case NominationStatus.zugesagt:
      return const Color(0xFF2E7D32);
    case NominationStatus.unsicher:
      return const Color(0xFFF9A825);
    case NominationStatus.abgesagt:
      return const Color(0xFFC62828);
    case NominationStatus.open:
      return const Color(0xFF9E9E9E);
  }
}

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
    Widget chip(NominationStatus s, String label) {
      final c = nominationColor(s);
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(radius: 5, backgroundColor: c),
            const SizedBox(width: 6),
            Text('${_count(s)} $label',
                style: TextStyle(color: c, fontWeight: FontWeight.w600)),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          chip(NominationStatus.zugesagt, 'zu'),
          chip(NominationStatus.unsicher, 'unsicher'),
          chip(NominationStatus.abgesagt, 'ab'),
          chip(NominationStatus.open, 'offen'),
        ],
      ),
    );
  }

  Widget _row(Player p) {
    final current = _statusOf(p);
    return ListTile(
      leading: PlayerAvatar(player: p, radius: 18),
      title: Text(p.fullName),
      subtitle: p.position == null ? null : Text(p.position!),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _choice(p, NominationStatus.zugesagt, Icons.check, current),
          const SizedBox(width: 4),
          _choice(p, NominationStatus.unsicher, Icons.help_outline, current),
          const SizedBox(width: 4),
          _choice(p, NominationStatus.abgesagt, Icons.close, current),
        ],
      ),
    );
  }

  Widget _choice(
      Player p, NominationStatus s, IconData icon, NominationStatus current) {
    final selected = current == s;
    final c = nominationColor(s);
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => _set(p, selected ? NominationStatus.open : s),
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: selected ? c : c.withValues(alpha: 0.12),
          shape: BoxShape.circle,
        ),
        child: Icon(icon,
            size: 20, color: selected ? Colors.white : c),
      ),
    );
  }
}
