import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/card_entry.dart';
import '../models/enums.dart';
import '../models/match.dart';
import '../models/match_event.dart';
import '../models/note_category.dart';
import '../models/player.dart';
import '../models/player_note.dart';
import '../state/app_state.dart';
import '../widgets/availability_controls.dart';
import '../widgets/player_avatar.dart';
import '../widgets/rich_note_view.dart';
import 'note_editor_screen.dart';

/// Spielerprofil – alles nach Kategorien geordnet und direkt im Profil
/// bearbeitbar (Felder antippen, Änderungen werden sofort gespeichert).
class PlayerDetailScreen extends StatefulWidget {
  const PlayerDetailScreen({super.key, required this.player});
  final Player player;

  @override
  State<PlayerDetailScreen> createState() => _PlayerDetailScreenState();
}

class _PlayerDetailScreenState extends State<PlayerDetailScreen> {
  late Player _player;

  @override
  void initState() {
    super.initState();
    _player = widget.player;
  }

  /// Übernimmt eine Änderung am Spieler: sofort speichern + Ansicht aktualisieren.
  Future<void> _apply(Player updated) async {
    setState(() => _player = updated);
    await context.read<AppState>().updatePlayer(updated);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final df = DateFormat('dd.MM.yyyy', 'de_DE');
    final p = _player;

    return Scaffold(
      appBar: AppBar(
        title: Text(p.fullName.isEmpty ? 'Spieler' : p.fullName),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'delete') _deletePlayer();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'delete', child: Text('Spieler löschen')),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 28),
        children: [
          _header(context),
          _stammdatenCard(context),
          _statusCard(context),
          _cardsCard(context, state, df),
          _goalsCard(context, state, df),
          _notesCard(context, state, df),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ Header
  Widget _header(BuildContext context) {
    final p = _player;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Row(
        children: [
          PlayerAvatar(player: p, radius: 34),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(p.fullName.isEmpty ? 'Neuer Spieler' : p.fullName,
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 2),
                Text([
                  if (p.number != null) 'Nr. ${p.number}',
                  if (p.position != null) p.position!,
                ].join('  ·  ')),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _statusChip(context, p.status),
                    if (p.captainRole != CaptainRole.none)
                      Chip(
                        label: Text(
                            '${p.captainRole.badge} ${p.captainRole.label}'),
                        visualDensity: VisualDensity.compact,
                      ),
                    _ratingChip(context),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _ratingChip(BuildContext context) {
    return FutureBuilder<(double?, int)>(
      future: context.read<AppState>().ratingAverage(_player.id),
      builder: (context, snap) {
        if (!snap.hasData) return const SizedBox.shrink();
        final (avg, count) = snap.data!;
        if (avg == null || count == 0) return const SizedBox.shrink();
        return Chip(
          avatar: Icon(Icons.star, size: 16, color: Colors.amber.shade700),
          label: Text('${avg.toStringAsFixed(1)} ($count)'),
          visualDensity: VisualDensity.compact,
        );
      },
    );
  }

  Widget _statusChip(BuildContext context, PlayerStatus s) {
    final color = playerStatusColor(s);
    return Chip(
      avatar: Text(s.symbol, style: const TextStyle(fontSize: 12)),
      label: Text(s.label),
      visualDensity: VisualDensity.compact,
      side: BorderSide(color: color),
    );
  }

  // -------------------------------------------------------------- Stammdaten
  Widget _stammdatenCard(BuildContext context) {
    final p = _player;
    return _SectionCard(
      icon: Icons.badge_outlined,
      title: 'Stammdaten',
      child: Column(
        children: [
          _EditableField(
            label: 'Vorname',
            initial: p.firstName,
            onSave: (v) => _apply(p.copyWith(firstName: v.trim())),
          ),
          const SizedBox(height: 10),
          _EditableField(
            label: 'Nachname',
            initial: p.lastName,
            onSave: (v) => _apply(p.copyWith(lastName: v.trim())),
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 80,
                child: _EditableField(
                  label: 'Nr.',
                  initial: p.number?.toString() ?? '',
                  keyboardType: TextInputType.number,
                  onSave: (v) {
                    final t = v.trim();
                    if (t.isEmpty) {
                      _apply(p.copyWith(clearNumber: true));
                    } else {
                      final n = int.tryParse(t);
                      if (n != null) _apply(p.copyWith(number: n));
                    }
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _EditableField(
                  label: 'Position',
                  initial: p.position ?? '',
                  onSave: (v) {
                    final t = v.trim();
                    _apply(t.isEmpty
                        ? p.copyWith(clearPosition: true)
                        : p.copyWith(position: t));
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _EditableField(
            label: 'Wunschposition',
            initial: p.wishPosition ?? '',
            onSave: (v) {
              final t = v.trim();
              _apply(t.isEmpty
                  ? p.copyWith(clearWishPosition: true)
                  : p.copyWith(wishPosition: t));
            },
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ Status/Rolle
  Widget _statusCard(BuildContext context) {
    final p = _player;
    return _SectionCard(
      icon: Icons.verified_user_outlined,
      title: 'Status & Rolle',
      child: Column(
        children: [
          DropdownButtonFormField<PlayerStatus>(
            initialValue: p.status,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Status',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: PlayerStatus.values
                .map((s) => DropdownMenuItem(
                    value: s, child: Text('${s.symbol} ${s.label}')))
                .toList(),
            onChanged: (v) {
              if (v != null) _apply(p.copyWith(status: v));
            },
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<CaptainRole>(
            initialValue: p.captainRole,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Kapitäns-Rolle',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: CaptainRole.values
                .map((c) => DropdownMenuItem(
                    value: c,
                    child: Text(c == CaptainRole.none
                        ? 'Keine'
                        : '${c.badge} ${c.label}')))
                .toList(),
            onChanged: (v) {
              if (v != null) _apply(p.copyWith(captainRole: v));
            },
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ Karten
  Widget _cardsCard(BuildContext context, AppState state, DateFormat df) {
    return _SectionCard(
      icon: Icons.style_outlined,
      title: 'Karten',
      action: TextButton.icon(
        onPressed: () => _addCard(context),
        icon: const Icon(Icons.add),
        label: const Text('Karte'),
      ),
      child: FutureBuilder<(List<CardEntry>, Map<String, GameMatch>)>(
        future: _loadCards(state),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Padding(
              padding: EdgeInsets.all(8),
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
                  padding: EdgeInsets.all(8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Noch keine Karten erfasst.',
                        style: TextStyle(color: Colors.grey)),
                  ),
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
                        contentPadding: EdgeInsets.zero,
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
            ],
          );
        },
      ),
    );
  }

  // --------------------------------------------------------- Tore & Vorlagen
  Widget _goalsCard(BuildContext context, AppState state, DateFormat df) {
    return _SectionCard(
      icon: Icons.sports_soccer,
      title: 'Tore & Vorlagen',
      child: FutureBuilder<(List<MatchEvent>, Map<String, GameMatch>)>(
        future: _loadEvents(state),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Padding(
              padding: EdgeInsets.all(8),
              child: LinearProgressIndicator(),
            );
          }
          final events = snap.data!.$1
              .where((e) => e.type == MatchEventType.goal)
              .toList();
          if (events.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Noch keine Tore/Vorlagen erfasst.',
                    style: TextStyle(color: Colors.grey)),
              ),
            );
          }
          final matches = snap.data!.$2;
          return Column(
            children: events.map((e) {
              final isScorer = e.playerId == _player.id;
              final m = matches[e.matchId];
              return ListTile(
                contentPadding: EdgeInsets.zero,
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
    );
  }

  // ----------------------------------------------------------------- Notizen
  Widget _notesCard(BuildContext context, AppState state, DateFormat df) {
    return _SectionCard(
      icon: Icons.sticky_note_2_outlined,
      title: 'Notizen',
      action: TextButton.icon(
        onPressed: () => _addNote(context),
        icon: const Icon(Icons.add),
        label: const Text('Notiz'),
      ),
      child: FutureBuilder<(List<PlayerNote>, List<NoteCategory>)>(
        future: _loadNotes(state),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Padding(
              padding: EdgeInsets.all(8),
              child: LinearProgressIndicator(),
            );
          }
          final notes = snap.data!.$1;
          final cats = snap.data!.$2;
          if (notes.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Noch keine Notizen.',
                    style: TextStyle(color: Colors.grey)),
              ),
            );
          }
          // Nach Rubrik gruppieren – Reihenfolge wie in den Einstellungen,
          // „Ohne Rubrik" ganz unten.
          final byCat = <String?, List<PlayerNote>>{};
          final known = {for (final c in cats) c.id};
          for (final n in notes) {
            final key = (n.categoryId != null && known.contains(n.categoryId))
                ? n.categoryId
                : null;
            byCat.putIfAbsent(key, () => []).add(n);
          }
          final groups = <(String, List<PlayerNote>)>[
            for (final c in cats)
              if (byCat[c.id] != null) (c.name, byCat[c.id]!),
            if (byCat[null] != null) ('Ohne Rubrik', byCat[null]!),
          ];
          return Column(
            children: [
              for (final g in groups) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(0, 8, 0, 0),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(g.$1,
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                            color: Theme.of(context).colorScheme.primary)),
                  ),
                ),
                for (final n in g.$2)
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
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.sticky_note_2_outlined),
                      title: RichNoteView(stored: n.text),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(df.format(n.createdAt)),
                      ),
                      trailing: const Icon(Icons.edit, size: 18),
                      onTap: () => _editNote(context, n),
                    ),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }

  // --------------------------------------------------------------- Aktionen
  Future<void> _deletePlayer() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Spieler löschen?'),
        content: Text('„${_player.fullName}" wirklich entfernen?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Löschen')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await context.read<AppState>().deletePlayer(_player.id);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _addNote(BuildContext context) async {
    final result = await Navigator.push<NoteEditResult>(
      context,
      MaterialPageRoute(
        builder: (_) => NoteEditorScreen(playerName: _player.fullName),
      ),
    );
    if (result == null || !context.mounted) return;
    await context
        .read<AppState>()
        .addNote(_player.id, result.stored, categoryId: result.categoryId);
  }

  Future<void> _editNote(BuildContext context, PlayerNote note) async {
    final result = await Navigator.push<NoteEditResult>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            NoteEditorScreen(playerName: _player.fullName, existing: note),
      ),
    );
    if (result == null || !context.mounted) return;
    await context.read<AppState>().updateNote(
          note.copyWith(
            text: result.stored,
            categoryId: result.categoryId,
            clearCategory: result.categoryId == null,
          ),
        );
  }

  Future<(List<PlayerNote>, List<NoteCategory>)> _loadNotes(AppState s) async {
    final notes = await s.notesOf(_player.id);
    final cats = await s.noteCategories();
    return (notes, cats);
  }

  Future<(List<CardEntry>, Map<String, GameMatch>)> _loadCards(
      AppState s) async {
    final cards = await s.cardsOf(_player.id);
    final mm = await s.matchMap(_player.teamId);
    return (cards, mm);
  }

  Future<(List<MatchEvent>, Map<String, GameMatch>)> _loadEvents(
      AppState s) async {
    final events = await s.playerMatchEvents(_player.id);
    final mm = await s.matchMap(_player.teamId);
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
      padding: const EdgeInsets.only(bottom: 4),
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
    final matches = await _matchesFor(context);
    if (!context.mounted) return;
    final data = await showCardDialog(context, matches: matches);
    if (data == null || !context.mounted) return;
    await context.read<AppState>().addCard(
          playerId: _player.id,
          type: data.type,
          date: data.date,
          matchId: data.matchId,
          note: data.note,
        );
  }

  Future<void> _editCard(BuildContext context, CardEntry card) async {
    final matches = await _matchesFor(context);
    if (!context.mounted) return;
    final data = await showCardDialog(context, existing: card, matches: matches);
    if (data == null || !context.mounted) return;
    await context.read<AppState>().updateCard(
          card.copyWith(
            type: data.type,
            date: data.date,
            note: data.note,
            matchId: data.matchId,
            clearMatchId: data.matchId == null,
          ),
        );
  }

  /// Spiele des Teams, neueste zuerst – für die Spielauswahl im Kartendialog.
  Future<List<GameMatch>> _matchesFor(BuildContext context) async {
    final mm = await context.read<AppState>().matchMap(_player.teamId);
    final list = mm.values.toList()
      ..sort((a, b) => (b.kickoff ?? b.createdAt)
          .compareTo(a.kickoff ?? a.createdAt));
    return list;
  }
}

/// Karten-Abschnitt mit Icon-Titel und optionaler Aktion – für ein modernes,
/// nach Kategorien geordnetes Profil.
class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.icon,
    required this.title,
    required this.child,
    this.action,
  });

  final IconData icon;
  final String title;
  final Widget child;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                Text(title,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
                const Spacer(),
                ?action,
              ],
            ),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }
}

/// Einzelnes, direkt editierbares Feld: speichert automatisch beim Verlassen
/// (Fokusverlust) oder mit Enter – kein Extra-Bearbeiten-Modus.
class _EditableField extends StatefulWidget {
  const _EditableField({
    required this.label,
    required this.initial,
    required this.onSave,
    this.keyboardType,
  });

  final String label;
  final String initial;
  final ValueChanged<String> onSave;
  final TextInputType? keyboardType;

  @override
  State<_EditableField> createState() => _EditableFieldState();
}

class _EditableFieldState extends State<_EditableField> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  late String _lastSaved;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
    _lastSaved = widget.initial;
    _focusNode = FocusNode()..addListener(_onFocusChange);
  }

  void _onFocusChange() {
    if (!_focusNode.hasFocus) _commit();
  }

  void _commit() {
    if (_controller.text == _lastSaved) return;
    _lastSaved = _controller.text;
    widget.onSave(_controller.text);
  }

  @override
  void didUpdateWidget(covariant _EditableField old) {
    super.didUpdateWidget(old);
    // Externe Änderung (z.B. nach Speichern) übernehmen, solange nicht im Fokus.
    if (!_focusNode.hasFocus && widget.initial != _lastSaved) {
      _lastSaved = widget.initial;
      _controller.text = widget.initial;
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      focusNode: _focusNode,
      keyboardType: widget.keyboardType,
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => _commit(),
      onTapOutside: (_) {
        if (_focusNode.hasFocus) _focusNode.unfocus();
      },
      decoration: InputDecoration(
        labelText: widget.label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }
}

class CardDialogData {
  final CardType type;
  final DateTime date;
  final String? matchId;
  final String? note;
  const CardDialogData(this.type, this.date, this.matchId, this.note);
}

Future<CardDialogData?> showCardDialog(
  BuildContext context, {
  CardEntry? existing,
  List<GameMatch> matches = const [],
}) {
  var type = existing?.type ?? CardType.yellow;
  var date = existing?.date ?? DateTime.now();
  // Vorauswahl nur gültig, wenn das Spiel noch existiert.
  var matchId = (existing?.matchId != null &&
          matches.any((m) => m.id == existing!.matchId))
      ? existing!.matchId
      : null;
  final noteCtrl = TextEditingController(text: existing?.note ?? '');
  final df = DateFormat('dd.MM.yyyy', 'de_DE');

  String matchLabel(GameMatch m) {
    final d = m.kickoff == null ? '' : '${df.format(m.kickoff!.toLocal())} · ';
    return '$d${m.venue == Venue.home ? 'H' : 'A'} vs ${m.opponentName}';
  }

  return showDialog<CardDialogData>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(existing == null ? 'Karte hinzufügen' : 'Karte bearbeiten'),
        content: SingleChildScrollView(
          child: Column(
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
              if (matches.isNotEmpty)
                DropdownButtonFormField<String?>(
                  initialValue: matchId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Spiel'),
                  items: [
                    const DropdownMenuItem<String?>(
                        value: null, child: Text('Kein Spiel')),
                    ...matches.map((m) => DropdownMenuItem<String?>(
                          value: m.id,
                          child: Text(matchLabel(m),
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                        )),
                  ],
                  onChanged: (v) => setState(() {
                    matchId = v;
                    // Datum aus dem gewählten Spiel übernehmen.
                    if (v != null) {
                      final m = matches.firstWhere((e) => e.id == v);
                      if (m.kickoff != null) date = m.kickoff!.toLocal();
                    }
                  }),
                ),
              if (matches.isNotEmpty) const SizedBox(height: 12),
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
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Abbrechen')),
          FilledButton(
            onPressed: () => Navigator.pop(
              context,
              CardDialogData(type, date, matchId,
                  noteCtrl.text.trim().isEmpty ? null : noteCtrl.text.trim()),
            ),
            child: const Text('Speichern'),
          ),
        ],
      ),
    ),
  );
}
