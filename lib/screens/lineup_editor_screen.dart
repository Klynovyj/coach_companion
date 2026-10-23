import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/enums.dart';
import '../models/lineup.dart';
import '../models/player.dart';
import '../state/app_state.dart';
import '../widgets/pitch_field.dart';
import '../widgets/player_avatar.dart';
import 'nomination_screen.dart';

/// Aufstellungs-Editor mit frei bespielbarem Feld (Spieler überall platzieren).
/// Auswahl kommt aus den zugesagten Spielern. Die Formation dient nur als
/// Startanordnung – danach verschiebst du alles frei.
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
  // Interne Standard-Formation nur für die Default-Position beim Einteilen
  // über die Liste (kein UI-Auswahlfeld mehr – es wird frei platziert).
  static const _defaultFormation = '4-4-2';

  final GlobalKey _pitchKey = GlobalKey();

  Lineup? _lineup;
  String _formation = '4-4-2';
  final Map<String, Player> _byId = {};
  List<Player> _nominated = [];
  final Map<String, Offset> _starters = {}; // playerId -> relative Position
  final Set<String> _bench = {};
  bool _loading = true;
  bool _restricted = false;
  // Start immer in der Listen-Ansicht (wie SpielerPlus): erst Start/Bank
  // einteilen, danach im Feld frei anordnen.
  bool _listMode = true;

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
    final slots = slotsForFormation(lineup.formation);

    if (!mounted) return;
    setState(() {
      _lineup = lineup;
      _formation = lineup.formation;
      _byId
        ..clear()
        ..addEntries(players.map((p) => MapEntry(p.id, p)));
      _nominated = pool;
      _restricted = nominated.isNotEmpty;
      _starters.clear();
      _bench.clear();
      var idx = 0;
      for (final e in entries) {
        if (!_byId.containsKey(e.playerId)) continue;
        if (e.role == LineupRole.starter) {
          final x = e.posX;
          final y = e.posY;
          if (x != null && y != null) {
            _starters[e.playerId] = Offset(x, y);
          } else {
            // Altbestand ohne Position -> auf Formations-Slot setzen.
            final s = idx < slots.length ? slots[idx] : null;
            _starters[e.playerId] =
                s != null ? Offset(s.x, s.y) : const Offset(0.5, 0.5);
          }
          idx++;
        } else if (e.role == LineupRole.substitute) {
          _bench.add(e.playerId);
        }
      }
      _loading = false;
    });
  }

  List<Player> get _pool => _nominated
      .where((p) => !_starters.containsKey(p.id) && !_bench.contains(p.id))
      .toList();

  void _removeEverywhere(String pid) {
    _starters.remove(pid);
    _bench.remove(pid);
  }

  void _placeAt(String pid, Offset rel) {
    setState(() {
      _bench.remove(pid);
      _starters[pid] = Offset(
        rel.dx.clamp(0.05, 0.95),
        rel.dy.clamp(0.05, 0.95),
      );
    });
  }

  void _toBench(String pid) => setState(() {
        _removeEverywhere(pid);
        _bench.add(pid);
      });

  void _toPool(String pid) => setState(() => _removeEverywhere(pid));

  /// Position eines Drop-Punkts (global) in relative Feldkoordinaten.
  Offset? _relFromGlobal(Offset global) {
    final box = _pitchKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return null;
    final local = box.globalToLocal(global);
    return Offset(local.dx / box.size.width, local.dy / box.size.height);
  }

  /// Fügt einen Spieler (aus der Liste) als Starter an einer freien Position ein.
  void _addStarterDefault(String pid) {
    final slots = slotsForFormation(_defaultFormation);
    final idx = _starters.length;
    final pos = idx < slots.length
        ? Offset(slots[idx].x, slots[idx].y)
        : const Offset(0.5, 0.5);
    setState(() {
      _bench.remove(pid);
      _starters[pid] = pos;
    });
  }

  Future<void> _save() async {
    final lineup = _lineup!;
    final entries = <LineupEntry>[];
    var i = 0;
    _starters.forEach((pid, pos) {
      entries.add(LineupEntry(
        id: context.read<AppState>().newEntryId(),
        lineupId: lineup.id,
        playerId: pid,
        role: LineupRole.starter,
        orderIndex: i++,
        posX: pos.dx,
        posY: pos.dy,
      ));
    });
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

  Future<void> _resetLineup() async {
    final state = context.read<AppState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Aufstellung zurücksetzen?'),
        content: const Text(
            'Alle Spieler werden vom Feld und der Bank entfernt.'),
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
    if (ok != true) return;
    setState(() {
      _starters.clear();
      _bench.clear();
    });
    // Leere Aufstellung speichern, damit der Reset auch persistent ist.
    await state.saveLineup(_lineup!.copyWith(formation: _formation), const []);
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
    final starters = _starters.length;
    return Scaffold(
      appBar: AppBar(
        title: Text('Aufstellung · ${widget.teamName}'),
        actions: [
          IconButton(
            tooltip: 'Aufstellung zurücksetzen',
            icon: const Icon(Icons.restart_alt),
            onPressed: _resetLineup,
          ),
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
          if (_listMode)
            _listEditor()
          else ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Startelf',
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  Text('$starters/11',
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: starters == 11
                              ? Colors.green.shade700
                              : Colors.orange.shade800)),
                ],
              ),
            ),
            Padding(padding: const EdgeInsets.all(12), child: _pitch()),
            _benchSection(),
            _poolSection(),
          ],
          const SizedBox(height: 24),
        ],
      ),
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
            child: Text(
              !_restricted
                  ? 'Noch keine Zusagen – es wird der ganze Kader gezeigt'
                  : _listMode
                      ? 'Erst Start/Bank einteilen – dann im Feld anordnen'
                      : 'Ziehe die Spieler frei auf das Feld',
            ),
          ),
          TextButton(
              onPressed: _openNomination, child: const Text('Nominierung')),
        ],
      ),
    );
  }

  // --------------------------------------------------------------- Feld-Modus
  Widget _pitch() {
    // Responsiv: Feld füllt die verfügbare Breite, Höhe folgt dem
    // Seitenverhältnis – aber gedeckelt an die Viewport-Höhe, damit das ganze
    // Feld auf Mobilgeräten sichtbar bleibt. Spieler-Chips skalieren mit.
    return LayoutBuilder(
      builder: (context, outer) {
        final media = MediaQuery.of(context);
        final maxW = outer.maxWidth.isFinite
            ? outer.maxWidth
            : media.size.width - 24;
        final maxH = media.size.height * 0.60;
        const ratio = 0.66; // Breite / Höhe
        var w = maxW;
        var h = w / ratio;
        if (h > maxH) {
          h = maxH;
          w = h * ratio;
        }
        final chip = (w * 0.145).clamp(40.0, 58.0);
        final chipH = chip + chip * 0.32;
        return Center(
          child: SizedBox(
            width: w,
            height: h,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Stack(
                key: _pitchKey,
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
                  // Ganzflächiges Drop-Ziel: Spieler landen dort, wo du loslässt.
                  Positioned.fill(
                    child: DragTarget<String>(
                      onWillAcceptWithDetails: (_) => true,
                      onAcceptWithDetails: (d) {
                        final rel = _relFromGlobal(d.offset);
                        if (rel != null) _placeAt(d.data, rel);
                      },
                      builder: (context, cand, rej) => const SizedBox.expand(),
                    ),
                  ),
                  for (final entry in _starters.entries)
                    if (_byId.containsKey(entry.key))
                      Positioned(
                        left: entry.value.dx * w - chip / 2,
                        top: entry.value.dy * h - chipH / 2,
                        width: chip,
                        height: chipH,
                        child: _draggable(
                          _byId[entry.key]!,
                          _pitchChip(_byId[entry.key]!, chip),
                          anchor: chip / 2,
                        ),
                      ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _pitchChip(Player p, double chip) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        PlayerAvatar(player: p, radius: chip * 0.38),
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
            style: TextStyle(
                color: Colors.white,
                fontSize: (chip * 0.19).clamp(8.0, 12.0),
                fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }

  /// Draggable mit pointer-Anker: Drop-Punkt = Zeigerposition.
  Widget _draggable(Player p, Widget child, {double anchor = 26}) {
    return Draggable<String>(
      data: p.id,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Transform.translate(
        offset: Offset(-anchor, -anchor),
        child: Material(color: Colors.transparent, child: child),
      ),
      childWhenDragging: Opacity(opacity: 0.3, child: child),
      child: child,
    );
  }

  Widget _benchSection() => _dropZone(
        title: 'Ersatzbank',
        empty: 'Spieler hierher ziehen',
        players: _bench.where(_byId.containsKey).map((id) => _byId[id]!).toList(),
        onAccept: _toBench,
        highlightColor: Theme.of(context).colorScheme.secondaryContainer,
      );

  Widget _poolSection() => _dropZone(
        title: 'Verfügbar',
        empty: 'Alle zugesagten Spieler sind eingeteilt.',
        players: _pool,
        onAccept: _toPool,
        highlightColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      );

  Widget _dropZone({
    required String title,
    required String empty,
    required List<Player> players,
    required void Function(String) onAccept,
    required Color highlightColor,
  }) {
    return DragTarget<String>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (d) => onAccept(d.data),
      builder: (context, cand, rej) => Container(
        margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: cand.isNotEmpty
              ? highlightColor
              : Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$title (${players.length})',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (players.isEmpty)
              Text(empty, style: const TextStyle(color: Colors.grey))
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: players.map((p) => _draggable(p, _compactChip(p))).toList(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _compactChip(Player p) {
    final name = p.lastName.isNotEmpty ? p.lastName : p.firstName;
    return Container(
      constraints: const BoxConstraints(maxWidth: 170),
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
            child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------- Listen-Modus
  Widget _listEditor() {
    // Gruppiert wie bei SpielerPlus: Startelf, Ersatzbank, Verfügbar.
    final starters =
        _nominated.where((p) => _starters.containsKey(p.id)).toList();
    final bench = _nominated.where((p) => _bench.contains(p.id)).toList();
    final available = _pool;
    return Column(
      children: [
        _listGroup('Startelf', starters, countLabel: '${starters.length}/11'),
        _listGroup('Ersatzbank', bench),
        _listGroup('Verfügbar', available,
            emptyHint: 'Alle Spieler sind eingeteilt.'),
      ],
    );
  }

  Widget _listGroup(String title, List<Player> players,
      {String? countLabel, String? emptyHint}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
          child: Row(
            children: [
              Text(title,
                  style: Theme.of(context)
                      .textTheme
                      .labelLarge
                      ?.copyWith(
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.bold)),
              const SizedBox(width: 8),
              Text(countLabel ?? '${players.length}',
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        if (players.isEmpty && emptyHint != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
            child: Text(emptyHint,
                style: const TextStyle(color: Colors.grey)),
          )
        else
          for (final p in players) _listRow(p),
      ],
    );
  }

  Widget _listRow(Player p) {
    final isStarter = _starters.containsKey(p.id);
    final onBench = _bench.contains(p.id);
    final role = isStarter ? 'start' : (onBench ? 'bank' : 'raus');
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
            if (!isStarter) _addStarterDefault(p.id);
          } else if (v == 'bank') {
            _toBench(p.id);
          } else {
            _toPool(p.id);
          }
        },
      ),
    );
  }
}
