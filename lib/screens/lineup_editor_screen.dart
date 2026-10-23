import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/enums.dart';
import '../models/lineup.dart';
import '../models/player.dart';
import '../state/app_state.dart';

/// Editor für die eigene Aufstellung: Formation, Startelf und Ersatzbank.
/// Diese Entscheidungen trifft ausschließlich der Trainer.
class LineupEditorScreen extends StatefulWidget {
  const LineupEditorScreen({
    super.key,
    required this.matchId,
    required this.teamId,
    required this.teamName,
  });

  final String matchId;
  final String teamId;
  final String teamName;

  @override
  State<LineupEditorScreen> createState() => _LineupEditorScreenState();
}

class _LineupEditorScreenState extends State<LineupEditorScreen> {
  static const _formations = ['4-4-2', '4-3-3', '3-5-2', '4-2-3-1', '3-4-3', '5-3-2'];

  Lineup? _lineup;
  List<Player> _players = [];
  final Map<String, LineupRole> _roles = {};
  String _formation = '4-4-2';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    final lineup = await state.ensureLineup(widget.matchId, widget.teamId);
    final players = await state.playersOf(widget.teamId);
    final entries = await state.lineupEntries(lineup.id);
    final roleMap = {for (final e in entries) e.playerId: e.role};
    if (!mounted) return;
    setState(() {
      _lineup = lineup;
      _formation = lineup.formation;
      _players = players;
      _roles
        ..clear()
        ..addAll({
          for (final p in players)
            p.id: roleMap[p.id] ?? LineupRole.substitute,
        });
      _loading = false;
    });
  }

  int get _starterCount =>
      _roles.values.where((r) => r == LineupRole.starter).length;

  Future<void> _save() async {
    final lineup = _lineup!;
    final entries = <LineupEntry>[];
    var idx = 0;
    for (final p in _players) {
      final role = _roles[p.id] ?? LineupRole.substitute;
      entries.add(LineupEntry(
        id: context.read<AppState>().newEntryId(),
        lineupId: lineup.id,
        playerId: p.id,
        role: role,
        orderIndex: idx++,
      ));
    }
    await context
        .read<AppState>()
        .saveLineup(lineup.copyWith(formation: _formation), entries);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Aufstellung gespeichert.')),
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final starters = _players
        .where((p) => _roles[p.id] == LineupRole.starter)
        .toList();
    final bench = _players
        .where((p) => _roles[p.id] == LineupRole.substitute)
        .toList();
    final out = _players
        .where((p) => _roles[p.id] == LineupRole.unavailable)
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: Text('Aufstellung · ${widget.teamName}'),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('Speichern',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: _players.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Noch keine Spieler im Kader. Lege im Kader-Tab Spieler an.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: DropdownButtonFormField<String>(
                    initialValue: _formation,
                    decoration: const InputDecoration(labelText: 'Formation'),
                    items: _formations
                        .map((f) =>
                            DropdownMenuItem(value: f, child: Text(f)))
                        .toList(),
                    onChanged: (v) => setState(() => _formation = v ?? _formation),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Startelf: $_starterCount / 11',
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: _starterCount == 11
                                  ? Colors.green.shade700
                                  : Colors.orange.shade800)),
                      Text('Bank: ${bench.length}'),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                ..._group('Startelf', starters, LineupRole.starter),
                ..._group('Ersatzbank', bench, LineupRole.substitute),
                ..._group('Nicht dabei', out, LineupRole.unavailable),
                const SizedBox(height: 24),
              ],
            ),
    );
  }

  List<Widget> _group(String title, List<Player> players, LineupRole role) {
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(title,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(color: Theme.of(context).colorScheme.primary)),
      ),
      if (players.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Text('—', style: TextStyle(color: Colors.grey)),
        ),
      ...players.map((p) => ListTile(
            dense: true,
            leading: CircleAvatar(
              radius: 16,
              child: Text(p.number?.toString() ?? '?',
                  style: const TextStyle(fontSize: 12)),
            ),
            title: Text(p.fullName),
            subtitle: p.position == null ? null : Text(p.position!),
            trailing: _RoleSelector(
              value: role,
              onChanged: (r) => setState(() => _roles[p.id] = r),
            ),
          )),
    ];
  }
}

class _RoleSelector extends StatelessWidget {
  const _RoleSelector({required this.value, required this.onChanged});
  final LineupRole value;
  final ValueChanged<LineupRole> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<LineupRole>(
      style: const ButtonStyle(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      segments: const [
        ButtonSegment(value: LineupRole.starter, label: Text('Start')),
        ButtonSegment(value: LineupRole.substitute, label: Text('Bank')),
        ButtonSegment(value: LineupRole.unavailable, label: Text('Raus')),
      ],
      selected: {value},
      showSelectedIcon: false,
      onSelectionChanged: (s) => onChanged(s.first),
    );
  }
}
