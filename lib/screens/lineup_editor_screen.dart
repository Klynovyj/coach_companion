import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/enums.dart';
import '../models/lineup.dart';
import '../models/player.dart';
import '../state/app_state.dart';
import '../widgets/pitch_field.dart';
import '../widgets/player_avatar.dart';
import 'nomination_screen.dart';

/// Aufstellungs-Editor mit Spielfeld (Drag & Drop) im SpielerPlus-Stil.
/// Die Spielerauswahl kommt aus den zugesagten Spielern (Nominierung).
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
  static const _formations = [
    '4-4-2', '4-3-3', '3-5-2', '4-2-3-1', '3-4-3', '5-3-2', '4-1-4-1'
  ];

  Lineup? _lineup;
  String _formation = '4-4-2';
  final Map<String, Player> _byId = {};
  List<Player> _nominated = [];
  final Map<int, String> _slot = {}; // slotIndex -> playerId
  final Set<String> _bench = {};
  bool _loading = true;
  bool _restricted = false;
  bool _listMode = false; // false = Feld, true = Liste

  List<PitchSlot> get _slots => slotsForFormation(_formation);

  /// Setzt einen Spieler als Starter auf den ersten freien Positions-Slot.
  void _assignFirstFreeSlot(String pid) {
    final slots = _slots;
    for (var i = 0; i < slots.length; i++) {
      if (!_slot.containsKey(i)) {
        _assignToSlot(pid, i);
        return;
      }
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Startelf ist voll (11).')),
    );
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    final lineup = await state.ensureLineup(widget.matchId, widget.teamId);
    final players = await state.playersOf(widget.teamId);
    final noms = await state.nominationsOf(widget.matchId);
    final entries = await state.lineupEntries(lineup.id);

    final nominated = players
        .where((p) => noms[p.id] == NominationStatus.zugesagt)
        .toList();
    final pool = nominated.isEmpty ? players : nominated;

    if (!mounted) return;
    setState(() {
      _lineup = lineup;
      _formation = lineup.formation;
      _byId
        ..clear()
        ..addEntries(players.map((p) => MapEntry(p.id, p)));
      _nominated = pool;
      _restricted = nominated.isNotEmpty;
      _slot.clear();
      _bench.clear();
      final slotCount = _slots.length;
      for (final e in entries) {
        if (!_byId.containsKey(e.playerId)) continue;
        if (e.role == LineupRole.starter &&
            e.orderIndex >= 0 &&
            e.orderIndex < slotCount) {
          _slot[e.orderIndex] = e.playerId;
        } else if (e.role == LineupRole.substitute) {
          _bench.add(e.playerId);
        }
      }
      _loading = false;
    });
  }

  Set<String> get _placed => {..._slot.values, ..._bench};
  List<Player> get _pool =>
      _nominated.where((p) => !_placed.contains(p.id)).toList();

  void _removeEverywhere(String pid) {
    _slot.removeWhere((k, v) => v == pid);
    _bench.remove(pid);
  }

  void _assignToSlot(String pid, int slotIndex) {
    setState(() {
      _removeEverywhere(pid);
      _slot[slotIndex] = pid; // ggf. vorhandener Spieler wandert zurück in den Pool
    });
  }

  void _toBench(String pid) {
    setState(() {
      _removeEverywhere(pid);
      _bench.add(pid);
    });
  }

  void _toPool(String pid) {
    setState(() => _removeEverywhere(pid));
  }

  void _changeFormation(String f) {
    setState(() {
      _formation = f;
      final count = slotsForFormation(f).length;
      _slot.removeWhere((k, v) => k >= count); // ungültige Slots -> Pool
    });
  }

  Future<void> _save() async {
    final lineup = _lineup!;
    final slots = _slots;
    final entries = <LineupEntry>[];
    _slot.forEach((slotIndex, pid) {
      entries.add(LineupEntry(
        id: context.read<AppState>().newEntryId(),
        lineupId: lineup.id,
        playerId: pid,
        role: LineupRole.starter,
        positionLabel: slotIndex < slots.length ? slots[slotIndex].label : null,
        orderIndex: slotIndex,
      ));
    });
    var i = 0;
    for (final pid in _bench) {
      entries.add(LineupEntry(
        id: context.read<AppState>().newEntryId(),
        lineupId: lineup.id,
        playerId: pid,
        role: LineupRole.substitute,
        orderIndex: 100 + i++,
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

  Future<void> _openNomination() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => NominationScreen(
          matchId: widget.matchId,
          teamId: widget.teamId,
          title: widget.teamName,
        ),
      ),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final starters = _slot.length;
    return Scaffold(
      appBar: AppBar(
        title: Text('Aufstellung · ${widget.teamName}'),
        actions: [
          IconButton(
            tooltip: _listMode ? 'Feld-Ansicht' : 'Listen-Ansicht',
            icon: Icon(_listMode ? Icons.grid_view : Icons.view_list),
            onPressed: () => setState(() => _listMode = !_listMode),
          ),
          TextButton(
            onPressed: _save,
            child: const Text('Speichern',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: ListView(
        children: [
          _banner(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue:
                        _formations.contains(_formation) ? _formation : null,
                    decoration: const InputDecoration(labelText: 'Formation'),
                    items: _formations
                        .map((f) =>
                            DropdownMenuItem(value: f, child: Text(f)))
                        .toList(),
                    onChanged: (v) => _changeFormation(v ?? _formation),
                  ),
                ),
                const SizedBox(width: 12),
                Text('Startelf $starters/11',
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: starters == 11
                            ? Colors.green.shade700
                            : Colors.orange.shade800)),
              ],
            ),
          ),
          if (_listMode)
            _listEditor()
          else ...[
            Padding(
              padding: const EdgeInsets.all(12),
              child: _pitch(),
            ),
            _benchSection(),
            _poolSection(),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  // ------------------------------------------------------------- Listen-Modus
  Widget _listEditor() {
    return Column(
      children: _nominated.map((p) {
        final inSlot = _slot.values.contains(p.id);
        final onBench = _bench.contains(p.id);
        final role = inSlot ? 'start' : (onBench ? 'bank' : 'raus');
        return ListTile(
          leading: PlayerAvatar(player: p, radius: 18),
          title: Text(p.fullName),
          subtitle: p.position == null ? null : Text(p.position!),
          trailing: SegmentedButton<String>(
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            segments: const [
              ButtonSegment(value: 'start', label: Text('Start')),
              ButtonSegment(value: 'bank', label: Text('Bank')),
              ButtonSegment(value: 'raus', label: Text('Raus')),
            ],
            selected: {role},
            showSelectedIcon: false,
            onSelectionChanged: (s) {
              final v = s.first;
              if (v == 'start') {
                if (!inSlot) _assignFirstFreeSlot(p.id);
              } else if (v == 'bank') {
                _toBench(p.id);
              } else {
                _toPool(p.id);
              }
            },
          ),
        );
      }).toList(),
    );
  }

  Widget _banner() {
    return Container(
      width: double.infinity,
      color:
          Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.4),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.how_to_reg,
              size: 18, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(_restricted
                ? 'Ziehe zugesagte Spieler auf das Feld'
                : 'Noch keine Zusagen – es wird der ganze Kader gezeigt'),
          ),
          TextButton(
              onPressed: _openNomination, child: const Text('Nominierung')),
        ],
      ),
    );
  }

  Widget _pitch() {
    final scheme = Theme.of(context).colorScheme;
    return AspectRatio(
      aspectRatio: 0.66,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: LayoutBuilder(
          builder: (context, c) {
            final w = c.maxWidth;
            final h = c.maxHeight;
            const chip = 52.0;
            return Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: PitchFieldPainter(
                      Colors.white.withValues(alpha: 0.85),
                      const Color(0xFF2E7D4F),
                      const Color(0xFF2A744A),
                    ),
                  ),
                ),
                for (final s in _slots)
                  Positioned(
                    left: s.x * w - chip / 2,
                    top: s.y * h - chip / 2,
                    width: chip,
                    height: chip + 14,
                    child: _slotTarget(s, scheme),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _slotTarget(PitchSlot s, ColorScheme scheme) {
    return DragTarget<String>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (d) => _assignToSlot(d.data, s.index),
      builder: (context, cand, rej) {
        final pid = _slot[s.index];
        final highlight = cand.isNotEmpty;
        if (pid == null || !_byId.containsKey(pid)) {
          return _emptySlot(s.label, highlight);
        }
        return Draggable<String>(
          data: pid,
          feedback: _chip(_byId[pid]!, dragging: true),
          childWhenDragging: _emptySlot(s.label, false),
          child: _chip(_byId[pid]!),
        );
      },
    );
  }

  Widget _emptySlot(String label, bool highlight) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: highlight ? 0.35 : 0.18),
            shape: BoxShape.circle,
            border: Border.all(
                color: Colors.white.withValues(alpha: 0.7),
                width: highlight ? 2 : 1),
          ),
          child: const Icon(Icons.add, color: Colors.white70, size: 20),
        ),
        Text(label,
            style: const TextStyle(
                color: Colors.white, fontSize: 9, fontWeight: FontWeight.w600)),
      ],
    );
  }

  Widget _chip(Player p, {bool dragging = false}) {
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        PlayerAvatar(player: p, radius: 20),
        Container(
          margin: const EdgeInsets.only(top: 2),
          padding: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            p.lastName.isNotEmpty ? p.lastName : p.firstName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                color: Colors.white, fontSize: 9, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
    if (dragging) {
      return Material(color: Colors.transparent, child: content);
    }
    return content;
  }

  Widget _benchSection() {
    return DragTarget<String>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (d) => _toBench(d.data),
      builder: (context, cand, rej) {
        final bench = _bench
            .where(_byId.containsKey)
            .map((id) => _byId[id]!)
            .toList();
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: cand.isNotEmpty
                ? Theme.of(context).colorScheme.secondaryContainer
                : Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Ersatzbank (${bench.length})',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              if (bench.isEmpty)
                const Text('Spieler hierher ziehen',
                    style: TextStyle(color: Colors.grey))
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: bench.map(_listChip).toList(),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _poolSection() {
    final pool = _pool;
    return DragTarget<String>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (d) => _toPool(d.data),
      builder: (context, cand, rej) {
        return Container(
          margin: const EdgeInsets.all(12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: cand.isNotEmpty
                ? Theme.of(context).colorScheme.surfaceContainerHighest
                : Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Verfügbar (${pool.length})',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              if (pool.isEmpty)
                const Text('Alle zugesagten Spieler sind eingeteilt.',
                    style: TextStyle(color: Colors.grey))
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: pool.map(_listChip).toList(),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _listChip(Player p) {
    final chip = _compactChip(p);
    return Draggable<String>(
      data: p.id,
      feedback: Material(color: Colors.transparent, child: chip),
      childWhenDragging: Opacity(opacity: 0.4, child: chip),
      child: chip,
    );
  }

  Widget _compactChip(Player p) {
    final name = p.lastName.isNotEmpty ? p.lastName : p.firstName;
    return Container(
      constraints: const BoxConstraints(maxWidth: 160),
      padding: const EdgeInsets.fromLTRB(4, 4, 10, 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PlayerAvatar(player: p, radius: 13),
          const SizedBox(width: 6),
          if (p.number != null) ...[
            Text('${p.number}',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(name,
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}
