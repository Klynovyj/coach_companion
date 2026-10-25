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

  late final AppState _app = context.read<AppState>();

  @override
  void initState() {
    super.initState();
    // Live-Updates anderer Trainer (Realtime) sofort übernehmen.
    _app.addListener(_onChanged);
    _load();
  }

  void _onChanged() {
    if (mounted) _load();
  }

  @override
  void dispose() {
    _app.removeListener(_onChanged);
    super.dispose();
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    // Reines Trainerteam wird nicht nominiert (spielender Co-Trainer schon).
    final players = (await state.playersOf(widget.teamId))
        .where((p) =>
            !p.isStaffOnly && p.active && p.status != PlayerStatus.inaktiv)
        .toList();
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
      kickoff: match?.kickoff?.toLocal(),
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

  Future<void> _resetNomination() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Nominierung zurücksetzen?'),
        content: const Text('Alle Spieler werden auf „offen" gesetzt.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Zurücksetzen')),
        ],
      ),
    );
    if (ok == true) _bulk(NominationStatus.open);
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
              if (v == 'reset') _resetNomination();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'all_in', child: Text('Alle zusagen')),
              PopupMenuItem(
                  value: 'reset', child: Text('Nominierung zurücksetzen')),
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
    final suspended = p.suspendedGames > 0;
    final pos = p.position;
    return ListTile(
      leading: PlayerAvatar(player: p, radius: 18),
      title: Row(
        children: [
          Flexible(child: Text(p.fullName)),
          if (suspended) ...[
            const SizedBox(width: 8),
            _suspendedBadge(context, p.suspendedGames),
          ],
        ],
      ),
      subtitle: pos == null ? null : Text(pos),
      trailing: AvailabilityChoices(
        current: _statusOf(p),
        onChanged: (s) => _set(p, s),
      ),
    );
  }

  Widget _suspendedBadge(BuildContext context, int games) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.error,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text('⛔ Gesperrt · $games',
          style: const TextStyle(
              color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800)),
    );
  }
}
