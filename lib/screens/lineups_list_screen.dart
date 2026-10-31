import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/enums.dart';
import '../models/lineup.dart';
import '../services/cloud_service.dart';
import '../state/app_state.dart';
import 'lineup_editor_screen.dart';

/// Übersicht aller Aufstellungen eines Spiels (teamweit, von allen Trainern
/// sichtbar). Beliebig viele, selbst benannt. Die OBERSTE ist die Start-11 –
/// sie zählt für Live & Spielbericht. Bearbeiten darf nur der Ersteller;
/// jeder kann eine fremde als eigene kopieren („Duplizieren").
class LineupsListScreen extends StatefulWidget {
  const LineupsListScreen({
    super.key,
    required this.matchId,
    required this.teamId,
    required this.teamName,
    this.matchFinished = false,
  });

  final String matchId;
  final String teamId;
  final String teamName;

  /// Spiel beendet: die Start-11 ist nur noch ansehbar.
  final bool matchFinished;

  @override
  State<LineupsListScreen> createState() => _LineupsListScreenState();
}

class _LineupsListScreenState extends State<LineupsListScreen> {
  late final AppState _app = context.read<AppState>();
  List<Lineup> _lineups = [];
  Map<String, int> _starters = {}; // lineupId -> Anzahl Startelf
  bool _loading = true;
  bool _reloading =
      false; // verhindert überlappende (flackernde) Mehrfach-Loads
  bool _reloadQueued = false;

  @override
  void initState() {
    super.initState();
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
    // Mehrere Benachrichtigungen kurz nacheinander (Speichern + Cloud-Echo +
    // Realtime) nicht parallel laden lassen – sonst rendert ein Zwischenstand
    // und es flackert. Läuft schon ein Load, nur einen weiteren vormerken.
    if (_reloading) {
      _reloadQueued = true;
      return;
    }
    _reloading = true;
    try {
      final all = await _app.lineupsForMatch(widget.matchId, widget.teamId);
      // Vorschläge aus dem alten Modell nicht mehr anzeigen.
      final lineups = all.where((l) => l.suggestionOf == null).toList();
      final starters = <String, int>{};
      for (final l in lineups) {
        final entries = await _app.lineupEntries(l.id);
        starters[l.id] = entries
            .where((e) => e.role == LineupRole.starter)
            .length;
      }
      if (!mounted) return;
      setState(() {
        _lineups = lineups;
        _starters = starters;
        _loading = false;
      });
    } finally {
      _reloading = false;
      if (_reloadQueued && mounted) {
        _reloadQueued = false;
        _load();
      }
    }
  }

  bool _mine(Lineup l) {
    final me = CloudService.userId;
    return l.createdBy == null || (me != null && l.createdBy == me);
  }

  /// Anzeigename: eigener Name oder Default „Aufstellung N".
  String _displayName(Lineup l, int index) {
    final n = l.name?.trim();
    return (n != null && n.isNotEmpty) ? n : 'Aufstellung ${index + 1}';
  }

  Future<void> _openEditable(Lineup l) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => LineupEditorScreen(
          matchId: widget.matchId,
          teamId: widget.teamId,
          teamName: widget.teamName,
          lineupId: l.id,
          readOnly: false,
        ),
      ),
    );
    if (mounted) _load();
  }

  Future<void> _openView(Lineup l) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => LineupEditorScreen(
          matchId: widget.matchId,
          teamId: widget.teamId,
          teamName: widget.teamName,
          lineupId: l.id,
          readOnly: true,
        ),
      ),
    );
    if (mounted) _load();
  }

  /// Neue Aufstellung: Name eingeben, optional aus einer Vorlage kopieren.
  Future<void> _createNew() async {
    final nameCtrl = TextEditingController();
    Lineup? template;
    final created = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Neue Aufstellung'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'z. B. Plan A offensiv',
                ),
              ),
              if (_lineups.isNotEmpty) ...[
                const SizedBox(height: 16),
                DropdownButtonFormField<Lineup?>(
                  initialValue: template,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Vorlage',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem<Lineup?>(
                      value: null,
                      child: Text('Leer beginnen'),
                    ),
                    for (var i = 0; i < _lineups.length; i++)
                      DropdownMenuItem<Lineup?>(
                        value: _lineups[i],
                        child: Text(
                          'Kopie von ${_displayName(_lineups[i], i)}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (v) => setLocal(() => template = v),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Anlegen'),
            ),
          ],
        ),
      ),
    );
    if (created != true || !mounted) return;
    final l = await _app.createLineup(
      widget.matchId,
      widget.teamId,
      name: nameCtrl.text,
      copyFrom: template,
    );
    if (!mounted) return;
    await _load();
    // Direkt in den Editor springen.
    await _openEditable(l);
  }

  Future<void> _rename(Lineup l, int index) async {
    final ctrl = TextEditingController(text: l.name ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Aufstellung umbenennen'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            labelText: 'Name',
            hintText: _displayName(l, index),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
    if (result == null || !mounted) return;
    await _app.renameLineup(l, result);
    if (mounted) _load();
  }

  Future<void> _duplicate(Lineup l, int index) async {
    final copy = await _app.createLineup(
      widget.matchId,
      widget.teamId,
      name: 'Kopie von ${_displayName(l, index)}',
      copyFrom: l,
    );
    if (!mounted) return;
    await _load();
    await _openEditable(copy);
  }

  Future<void> _delete(Lineup l, int index) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Aufstellung löschen?'),
        content: Text('„${_displayName(l, index)}" wird endgültig gelöscht.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _app.deleteLineup(l);
    if (mounted) _load();
  }

  Future<void> _setStart(Lineup l) async {
    await _app.setAsStartEleven(l);
    if (mounted) _load();
  }

  Future<void> _move(int index, int delta) async {
    final target = index + delta;
    if (target < 0 || target >= _lineups.length) return;
    final ids = _lineups.map((l) => l.id).toList();
    final moved = ids.removeAt(index);
    ids.insert(target, moved);
    await _app.reorderLineups(widget.matchId, widget.teamId, ids);
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Aufstellungen · ${widget.teamName}')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createNew,
        icon: const Icon(Icons.add),
        label: const Text('Neue Aufstellung'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 90),
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(
                    'Lege beliebig viele Aufstellungen an und benenne sie selbst. '
                    'Die OBERSTE ist die Start-11 (zählt für Live & Bericht) – '
                    'mit ↑ oder „Start-11" nach oben schieben.',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
                if (_lineups.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(
                      child: Text('Noch keine Aufstellung – lege eine an.'),
                    ),
                  )
                else
                  for (var i = 0; i < _lineups.length; i++)
                    _lineupCard(context, _lineups[i], i),
              ],
            ),
    );
  }

  Widget _lineupCard(BuildContext context, Lineup l, int index) {
    final scheme = Theme.of(context).colorScheme;
    final mine = _mine(l);
    final isStart = index == 0;
    final count = _starters[l.id] ?? 0;
    final who = mine
        ? 'von mir'
        : (l.creatorName?.trim().isNotEmpty == true
              ? 'von ${l.creatorName!.trim()}'
              : 'anderer Trainer');
    final canEdit = mine && !(widget.matchFinished && isStart);
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      shape: isStart
          ? RoundedRectangleBorder(
              side: BorderSide(color: scheme.primary, width: 2),
              borderRadius: BorderRadius.circular(12),
            )
          : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _displayName(l, index),
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                ),
                if (isStart)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      'START-11',
                      style: TextStyle(
                        color: scheme.onPrimary,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              '$count/11 Startelf · $who',
              style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                // Reihenfolge-Pfeile.
                IconButton(
                  tooltip: 'Nach oben',
                  visualDensity: VisualDensity.compact,
                  onPressed: index == 0 ? null : () => _move(index, -1),
                  icon: const Icon(Icons.keyboard_arrow_up),
                ),
                IconButton(
                  tooltip: 'Nach unten',
                  visualDensity: VisualDensity.compact,
                  onPressed: index == _lineups.length - 1
                      ? null
                      : () => _move(index, 1),
                  icon: const Icon(Icons.keyboard_arrow_down),
                ),
                const Spacer(),
                _menu(l, index, mine, isStart),
                if (canEdit)
                  FilledButton.tonalIcon(
                    onPressed: () => _openEditable(l),
                    icon: const Icon(Icons.edit, size: 16),
                    label: const Text('Bearbeiten'),
                  )
                else
                  OutlinedButton.icon(
                    onPressed: () => _openView(l),
                    icon: const Icon(Icons.visibility, size: 16),
                    label: const Text('Ansehen'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _menu(Lineup l, int index, bool mine, bool isStart) {
    return PopupMenuButton<String>(
      tooltip: 'Mehr',
      onSelected: (v) {
        switch (v) {
          case 'start':
            _setStart(l);
          case 'rename':
            _rename(l, index);
          case 'duplicate':
            _duplicate(l, index);
          case 'delete':
            _delete(l, index);
        }
      },
      itemBuilder: (ctx) => [
        if (!isStart)
          const PopupMenuItem(
            value: 'start',
            child: ListTile(
              leading: Icon(Icons.vertical_align_top),
              title: Text('Als Start-11'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        const PopupMenuItem(
          value: 'duplicate',
          child: ListTile(
            leading: Icon(Icons.copy_all_outlined),
            title: Text('Duplizieren'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        if (mine) ...[
          const PopupMenuItem(
            value: 'rename',
            child: ListTile(
              leading: Icon(Icons.drive_file_rename_outline),
              title: Text('Umbenennen'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
          const PopupMenuItem(
            value: 'delete',
            child: ListTile(
              leading: Icon(Icons.delete_outline),
              title: Text('Löschen'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ],
      ],
    );
  }
}
