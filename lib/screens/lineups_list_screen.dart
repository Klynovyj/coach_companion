import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/enums.dart';
import '../models/lineup.dart';
import '../services/cloud_service.dart';
import '../state/app_state.dart';
import 'lineup_editor_screen.dart';

/// Übersicht aller Aufstellungen eines Spiels (je Trainer eine). Alle sichtbar;
/// bearbeiten darf nur der Ersteller, jeder kann eine für „Live" freigeben.
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

  /// Spiel beendet: die freigegebene Aufstellung ist nur noch ansehbar.
  final bool matchFinished;

  @override
  State<LineupsListScreen> createState() => _LineupsListScreenState();
}

class _LineupsListScreenState extends State<LineupsListScreen> {
  late final AppState _app = context.read<AppState>();
  List<Lineup> _lineups = [];
  final Map<String, int> _starters = {}; // lineupId -> Anzahl Startelf
  bool _loading = true;

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
    final lineups = await _app.lineupsForMatch(widget.matchId, widget.teamId);
    _starters.clear();
    for (final l in lineups) {
      final entries = await _app.lineupEntries(l.id);
      _starters[l.id] = entries
          .where((e) => e.role == LineupRole.starter)
          .length;
    }
    if (!mounted) return;
    setState(() {
      _lineups = lineups;
      _loading = false;
    });
  }

  bool _mine(Lineup l) {
    final me = CloudService.userId;
    return l.createdBy == null || (me != null && l.createdBy == me);
  }

  Future<void> _openMine() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => LineupEditorScreen(
          matchId: widget.matchId,
          teamId: widget.teamId,
          teamName: widget.teamName,
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

  Future<void> _release(Lineup l) async {
    await _app.releaseLineup(l);
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final hasMine = _lineups.any((l) => l.suggestionOf == null && _mine(l));
    return Scaffold(
      appBar: AppBar(title: Text('Aufstellungen · ${widget.teamName}')),
      floatingActionButton: hasMine
          ? null
          : FloatingActionButton.extended(
              onPressed: _openMine,
              icon: const Icon(Icons.add),
              label: const Text('Meine Aufstellung'),
            ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 90),
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(
                    'Jeder Trainer hat seine eigene Aufstellung. Bearbeiten darf '
                    'nur der Ersteller; für „Live" muss eine freigegeben werden.',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
                if (_lineups.where((l) => l.suggestionOf == null).isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(
                      child: Text('Noch keine Aufstellung – lege deine an.'),
                    ),
                  )
                else
                  for (final l in _lineups.where((l) => l.suggestionOf == null))
                    _lineupCard(context, l),
              ],
            ),
    );
  }

  List<Lineup> _suggestionsFor(String lineupId) =>
      _lineups.where((s) => s.suggestionOf == lineupId).toList();

  Future<void> _editAsSuggestion(Lineup original) async {
    final sugg = await _app.createOrOpenSuggestion(original);
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => LineupEditorScreen(
          matchId: widget.matchId,
          teamId: widget.teamId,
          teamName: widget.teamName,
          lineupId: sugg.id,
          readOnly: false,
        ),
      ),
    );
    if (mounted) _load();
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

  Future<void> _adopt(Lineup sugg) async {
    await _app.adoptSuggestion(sugg);
    if (mounted) _load();
  }

  Widget _lineupCard(BuildContext context, Lineup l) {
    final scheme = Theme.of(context).colorScheme;
    final mine = _mine(l);
    final count = _starters[l.id] ?? 0;
    final who = mine
        ? 'Meine Aufstellung'
        : (l.creatorName?.trim().isNotEmpty == true
              ? l.creatorName!.trim()
              : 'Anderer Trainer');
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      shape: l.released
          ? RoundedRectangleBorder(
              side: BorderSide(color: scheme.primary, width: 2),
              borderRadius: BorderRadius.circular(12),
            )
          : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  mine ? Icons.person : Icons.person_outline,
                  size: 18,
                  color: scheme.primary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    who,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                ),
                if (l.released)
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
                      'FREIGEGEBEN',
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
              '$count/11 Startelf',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).hintColor,
              ),
            ),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 4,
              children: [
                if (!l.released && !widget.matchFinished)
                  TextButton.icon(
                    onPressed: () => _release(l),
                    icon: const Icon(Icons.verified, size: 16),
                    label: const Text('Freigeben'),
                  ),
                if (mine)
                  (widget.matchFinished && l.released)
                      ? OutlinedButton.icon(
                          onPressed: () => _openView(l),
                          icon: const Icon(Icons.visibility, size: 16),
                          label: const Text('Ansehen'),
                        )
                      : FilledButton.tonalIcon(
                          onPressed: _openMine,
                          icon: const Icon(Icons.edit, size: 16),
                          label: const Text('Bearbeiten'),
                        )
                else ...[
                  OutlinedButton.icon(
                    onPressed: () => _openView(l),
                    icon: const Icon(Icons.visibility, size: 16),
                    label: const Text('Ansehen'),
                  ),
                  if (!_suggestionsFor(l.id).any(_mine))
                    FilledButton.tonalIcon(
                      onPressed: () => _editAsSuggestion(l),
                      icon: const Icon(Icons.edit_note, size: 16),
                      label: const Text('Als Vorschlag'),
                    ),
                ],
              ],
            ),
            ..._suggestionsFor(l.id).map((s) => _suggestionTile(context, l, s)),
          ],
        ),
      ),
    );
  }

  /// Zeile für einen Vorschlag unter einer Aufstellung.
  Widget _suggestionTile(BuildContext context, Lineup original, Lineup s) {
    final scheme = Theme.of(context).colorScheme;
    final mineSugg = _mine(s);
    final iAmOwner = _mine(original);
    final count = _starters[s.id] ?? 0;
    final who = mineSugg
        ? 'Mein Vorschlag'
        : 'Vorschlag von ${s.creatorName?.trim().isNotEmpty == true ? s.creatorName!.trim() : 'Trainer'}';
    return Container(
      margin: const EdgeInsets.only(left: 12, top: 6),
      padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.edit_note, size: 16, color: scheme.secondary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '$who · $count/11',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 4,
            children: [
              if (mineSugg)
                FilledButton.tonalIcon(
                  onPressed: () => _openEditable(s),
                  icon: const Icon(Icons.edit, size: 15),
                  label: const Text('Bearbeiten'),
                )
              else
                OutlinedButton.icon(
                  onPressed: () => _openView(s),
                  icon: const Icon(Icons.visibility, size: 15),
                  label: const Text('Ansehen'),
                ),
              if (iAmOwner)
                FilledButton.icon(
                  onPressed: () => _adopt(s),
                  icon: const Icon(Icons.download_done, size: 15),
                  label: const Text('Übernehmen'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
