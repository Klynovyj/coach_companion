import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/player.dart';
import '../models/player_talk.dart';
import '../state/app_state.dart';
import '../widgets/app_drawer.dart';
import '../widgets/player_avatar.dart';
import '../widgets/player_picker_page.dart';

/// Ergebnis des Gespräch-Formulars.
class TalkFormData {
  /// Ein oder mehrere Spieler – je Spieler wird ein eigenes Gespräch angelegt.
  final List<String> playerIds;
  final String title;
  final DateTime scheduledAt;
  final String? notes;
  final bool done;
  const TalkFormData(
      this.playerIds, this.title, this.scheduledAt, this.notes, this.done);
}

/// Formular zum Anlegen/Bearbeiten eines Spielergesprächs. [fixedPlayer] fixiert
/// den Spieler (z.B. aus dem Profil), sonst wird er per Picker gewählt.
Future<TalkFormData?> showTalkForm(
  BuildContext context, {
  PlayerTalk? existing,
  Player? fixedPlayer,
  required List<Player> players,
  bool multi = false,
}) {
  return Navigator.push<TalkFormData>(
    context,
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _TalkFormPage(
        existing: existing,
        fixedPlayer: fixedPlayer,
        players: players,
        multi: multi,
      ),
    ),
  );
}

class SpielergespraecheScreen extends StatefulWidget {
  const SpielergespraecheScreen({super.key});

  @override
  State<SpielergespraecheScreen> createState() =>
      _SpielergespraecheScreenState();
}

class _SpielergespraecheScreenState extends State<SpielergespraecheScreen>
    with SingleTickerProviderStateMixin {
  static final _df = DateFormat('EEE, dd.MM.yyyy  HH:mm', 'de_DE');

  late final TabController _tab = TabController(length: 3, vsync: this);
  bool _groupByPlayerMode = false; // false = nach Datum, true = nach Spieler

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  Future<(List<PlayerTalk>, List<Player>)> _load(AppState s) async {
    final talks = await s.talks();
    final team = s.ownTeam;
    final players = team == null ? <Player>[] : await s.playersOf(team.id);
    return (talks, players);
  }

  /// Neues Gespräch – Mehrfachauswahl: je Spieler ein eigener Eintrag.
  Future<void> _add(AppState state, List<Player> players) async {
    if (players.isEmpty) {
      _snack('Kein Kader vorhanden – Spieler zuerst ergänzen.');
      return;
    }
    final data = await showTalkForm(context, players: players, multi: true);
    if (data == null || !mounted) return;
    for (final pid in data.playerIds) {
      await state.addTalk(
        playerId: pid,
        title: data.title,
        scheduledAt: data.scheduledAt,
        notes: data.notes,
        done: data.done,
      );
    }
    if (mounted) setState(() {});
  }

  /// Gespräch für einen bestimmten Spieler (aus den Vorschlägen).
  Future<void> _planFor(AppState state, Player player) async {
    final data = await showTalkForm(context,
        fixedPlayer: player, players: [player]);
    if (data == null || !mounted) return;
    await state.addTalk(
      playerId: data.playerIds.first,
      title: data.title,
      scheduledAt: data.scheduledAt,
      notes: data.notes,
      done: data.done,
    );
    if (mounted) setState(() {});
  }

  Future<void> _edit(AppState state, PlayerTalk talk, List<Player> players,
      Player? player) async {
    final data = await showTalkForm(context,
        existing: talk, fixedPlayer: player, players: players);
    if (data == null || !mounted || data.playerIds.isEmpty) return;
    final wasDone = talk.done;
    await state.saveTalk(talk.copyWith(
      playerId: data.playerIds.first,
      title: data.title,
      scheduledAt: data.scheduledAt,
      notes: data.notes,
      clearNotes: data.notes == null,
      done: data.done,
    ));
    if (!mounted) return;
    setState(() {});
    if (data.done && !wasDone) {
      _tab.animateTo(1); // in den Reiter „Durchgeführt" wechseln
      _snack('Als durchgeführt gespeichert.');
    } else {
      _snack('Gespeichert.');
    }
  }

  Future<void> _toggleDone(AppState state, PlayerTalk t, bool v) async {
    await state.saveTalk(t.copyWith(done: v));
    if (!mounted) return;
    setState(() {});
    if (v) {
      _tab.animateTo(1);
      _snack('Als durchgeführt markiert.');
    }
  }

  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return FutureBuilder<(List<PlayerTalk>, List<Player>)>(
        future: _load(state),
        builder: (context, snap) {
          final hasData = snap.hasData;
          final talks = hasData ? snap.data!.$1 : <PlayerTalk>[];
          final players = hasData ? snap.data!.$2 : <Player>[];
          final playerMap = {for (final p in players) p.id: p};

          final planned = talks.where((t) => !t.done).toList()
            ..sort((a, b) => a.scheduledAt.compareTo(b.scheduledAt));
          final done = talks.where((t) => t.done).toList()
            ..sort((a, b) => b.scheduledAt.compareTo(a.scheduledAt));
          final talkedIds = talks.map((t) => t.playerId).toSet();
          // Vorschläge: aktive Kaderspieler (ohne Trainerteam) ohne Gespräch.
          final suggestions = players
              .where((p) =>
                  p.active && !p.isStaff && !talkedIds.contains(p.id))
              .toList();

          return Scaffold(
            drawer: const AppDrawer(),
            appBar: AppBar(
              title: const Text('Spielergespräche'),
              bottom: TabBar(
                controller: _tab,
                labelColor: Colors.white,
                unselectedLabelColor: Colors.white70,
                indicatorColor: Colors.white,
                tabs: [
                  Tab(text: 'Geplant (${planned.length})'),
                  Tab(text: 'Durchgeführt (${done.length})'),
                  Tab(text: 'Vorschläge (${suggestions.length})'),
                ],
              ),
            ),
            floatingActionButton: FloatingActionButton.extended(
              onPressed: () => _add(state, players),
              icon: const Icon(Icons.add),
              label: const Text('Gespräch'),
            ),
            body: !hasData
                ? const Center(child: CircularProgressIndicator())
                : TabBarView(
                    controller: _tab,
                    children: [
                      _talkList(state, planned, playerMap,
                          'Keine geplanten Gespräche.'),
                      _talkList(state, done, playerMap,
                          'Noch keine durchgeführten Gespräche.'),
                      _suggestionList(state, suggestions),
                    ],
                  ),
          );
        },
    );
  }

  Widget _talkList(AppState state, List<PlayerTalk> talks,
      Map<String, Player> players, String empty) {
    final groups = _grouped(talks, players);
    return ListView(
      padding: const EdgeInsets.only(bottom: 88),
      children: [
        _groupToggle(),
        if (talks.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(empty,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.grey)),
          )
        else
          for (final g in groups) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
              child: Text(g.$1,
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.primary)),
            ),
            for (final t in g.$2) _talkRow(state, t, players),
          ],
      ],
    );
  }

  Widget _groupToggle() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(
        children: [
          Text('Gruppieren:', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(width: 8),
          SegmentedButton<bool>(
            style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap),
            segments: const [
              ButtonSegment(
                  value: false,
                  label: Text('Datum'),
                  icon: Icon(Icons.event, size: 16)),
              ButtonSegment(
                  value: true,
                  label: Text('Spieler'),
                  icon: Icon(Icons.person, size: 16)),
            ],
            selected: {_groupByPlayerMode},
            onSelectionChanged: (s) =>
                setState(() => _groupByPlayerMode = s.first),
          ),
        ],
      ),
    );
  }

  /// Gruppiert nach Datum (Reihenfolge der Liste) oder nach Spieler (alpha).
  List<(String, List<PlayerTalk>)> _grouped(
      List<PlayerTalk> talks, Map<String, Player> players) {
    if (_groupByPlayerMode) {
      final map = <String, List<PlayerTalk>>{};
      for (final t in talks) {
        map.putIfAbsent(t.playerId, () => []).add(t);
      }
      final keys = map.keys.toList()
        ..sort((a, b) => (players[a]?.displayName ?? '')
            .toLowerCase()
            .compareTo((players[b]?.displayName ?? '').toLowerCase()));
      return [
        for (final k in keys)
          (
            players[k]?.displayName ?? 'Spieler',
            map[k]!..sort((x, y) => y.scheduledAt.compareTo(x.scheduledAt)),
          ),
      ];
    }
    // Nach Datum: Reihenfolge der (bereits sortierten) Liste beibehalten.
    final df = DateFormat('EEE, dd.MM.yyyy', 'de_DE');
    final map = <String, List<PlayerTalk>>{};
    final order = <String>[];
    for (final t in talks) {
      final d = t.scheduledAt;
      final key = '${d.year}-${d.month}-${d.day}';
      if (!map.containsKey(key)) {
        map[key] = [];
        order.add(key);
      }
      map[key]!.add(t);
    }
    return [for (final k in order) (df.format(map[k]!.first.scheduledAt), map[k]!)];
  }

  Widget _talkRow(AppState state, PlayerTalk t, Map<String, Player> players) {
    final p = players[t.playerId];
    return Dismissible(
      key: ValueKey(t.id),
      direction: DismissDirection.endToStart,
      background: Container(
        color: Colors.red,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      onDismissed: (_) => state.deleteTalk(t.id),
      child: Card(
        child: ListTile(
          leading: p != null
              ? PlayerAvatar(player: p, radius: 20)
              : const CircleAvatar(child: Icon(Icons.person)),
          title: Text(t.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: t.done
                  ? const TextStyle(
                      decoration: TextDecoration.lineThrough,
                      color: Colors.grey)
                  : null),
          subtitle: Text([
            p?.displayName ?? 'Spieler',
            _df.format(t.scheduledAt),
            if (t.notes != null && t.notes!.isNotEmpty) '📝',
          ].join('  ·  ')),
          trailing: Checkbox(
            value: t.done,
            onChanged: (v) => _toggleDone(state, t, v ?? false),
          ),
          onTap: () => _edit(state, t, players.values.toList(), p),
        ),
      ),
    );
  }

  Widget _suggestionList(AppState state, List<Player> players) {
    if (players.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Alle aktiven Spieler hatten schon ein Gespräch.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey)),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: players.length,
      itemBuilder: (context, i) {
        final p = players[i];
        return Card(
          child: ListTile(
            leading: PlayerAvatar(player: p, radius: 20),
            title: Text(p.displayName),
            subtitle: Text([
              if (p.number != null) 'Nr. ${p.number}',
              if (p.position != null) p.position!,
              'noch kein Gespräch',
            ].join('  ·  ')),
            trailing: FilledButton.tonalIcon(
              onPressed: () => _planFor(state, p),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Planen'),
            ),
            onTap: () => _planFor(state, p),
          ),
        );
      },
    );
  }
}

class _TalkFormPage extends StatefulWidget {
  const _TalkFormPage({
    this.existing,
    this.fixedPlayer,
    required this.players,
    this.multi = false,
  });

  final PlayerTalk? existing;
  final Player? fixedPlayer;
  final List<Player> players;

  /// Mehrfachauswahl (nur beim Neu-Planen im Hauptfenster).
  final bool multi;

  @override
  State<_TalkFormPage> createState() => _TalkFormPageState();
}

class _TalkFormPageState extends State<_TalkFormPage> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _notesCtrl;
  late DateTime _date;
  List<String> _playerIds = [];
  bool _done = false;

  final _df = DateFormat('EEE, dd.MM.yyyy  HH:mm', 'de_DE');

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _titleCtrl = TextEditingController(text: e?.title ?? '');
    _notesCtrl = TextEditingController(text: e?.notes ?? '');
    _date = e?.scheduledAt ??
        DateTime.now().add(const Duration(days: 1));
    final initId = widget.fixedPlayer?.id ?? e?.playerId;
    _playerIds = initId == null ? [] : [initId];
    _done = e?.done ?? false;
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Player? _playerById(String id) {
    if (widget.fixedPlayer?.id == id) return widget.fixedPlayer;
    return widget.players.where((p) => p.id == id).firstOrNull;
  }

  Future<void> _pickSingle() async {
    final res = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => PlayerPickerPage(
          players: widget.players,
          selected: _playerIds.isEmpty ? null : _playerIds.first,
          allowNone: false,
        ),
      ),
    );
    if (res == null || res == kPlayerPickNone) return;
    setState(() => _playerIds = [res]);
  }

  Future<void> _pickMulti() async {
    final res = await Navigator.of(context).push<List<String>>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) =>
            _MultiPlayerPickPage(players: widget.players, selected: _playerIds),
      ),
    );
    if (res == null) return;
    setState(() => _playerIds = res);
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(_date.year - 1),
      lastDate: DateTime(_date.year + 2),
    );
    if (d == null || !mounted) return;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_date),
    );
    if (!mounted) return;
    setState(() => _date =
        DateTime(d.year, d.month, d.day, t?.hour ?? 18, t?.minute ?? 0));
  }

  void _save() {
    if (_playerIds.isEmpty) {
      _snack(widget.multi
          ? 'Bitte mindestens einen Spieler wählen.'
          : 'Bitte einen Spieler wählen.');
      return;
    }
    if (_titleCtrl.text.trim().isEmpty) {
      _snack('Bitte ein Thema eingeben.');
      return;
    }
    final notes = _notesCtrl.text.trim();
    Navigator.pop(
      context,
      TalkFormData(
        _playerIds,
        _titleCtrl.text.trim(),
        _date,
        notes.isEmpty ? null : notes,
        _done,
      ),
    );
  }

  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Widget _multiPlayerRow() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Spieler (${_playerIds.length})',
                  style: Theme.of(context).textTheme.titleSmall),
            ),
            OutlinedButton.icon(
              onPressed: _pickMulti,
              icon: const Icon(Icons.group_add, size: 18),
              label: const Text('Spieler wählen'),
            ),
          ],
        ),
        if (_playerIds.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: _playerIds.map((id) {
              final p = _playerById(id);
              return InputChip(
                avatar:
                    p == null ? null : PlayerAvatar(player: p, radius: 11),
                label: Text(p?.displayName ?? 'Spieler'),
                onDeleted: () => setState(() =>
                    _playerIds = _playerIds.where((x) => x != id).toList()),
              );
            }).toList(),
          ),
        ],
        const SizedBox(height: 4),
        Text('Pro Spieler wird ein eigenes Gespräch angelegt.',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing != null;
    final fixed = widget.fixedPlayer != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(editing ? 'Gespräch bearbeiten' : 'Gespräch planen'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.check, size: 18),
              label: const Text('Speichern'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          // Spieler
          if (widget.multi)
            _multiPlayerRow()
          else
            Row(
              children: [
                Text('Spieler:',
                    style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(width: 10),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _playerIds.isEmpty
                        ? OutlinedButton.icon(
                            onPressed: _pickSingle,
                            icon: const Icon(Icons.person_add_alt, size: 18),
                            label: const Text('Spieler wählen'),
                          )
                        : Builder(builder: (_) {
                            final sel = _playerById(_playerIds.first);
                            return Chip(
                              avatar: sel == null
                                  ? null
                                  : PlayerAvatar(player: sel, radius: 11),
                              label: Text(sel?.displayName ?? 'Spieler'),
                            );
                          }),
                  ),
                ),
                if (_playerIds.isNotEmpty && !fixed)
                  TextButton(
                      onPressed: _pickSingle, child: const Text('Ändern')),
              ],
            ),
          const SizedBox(height: 16),
          TextField(
            controller: _titleCtrl,
            autofocus: !editing,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Thema',
              hintText: 'z.B. Rolle im Team, Trainingsbeteiligung',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          InkWell(
            onTap: _pickDate,
            borderRadius: BorderRadius.circular(4),
            child: InputDecorator(
              decoration: const InputDecoration(
                labelText: 'Datum & Uhrzeit',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.schedule),
              ),
              child: Text(_df.format(_date)),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _notesCtrl,
            minLines: 4,
            maxLines: 10,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Notizen (optional)',
              hintText: 'Besprochene Punkte, Vereinbarungen …',
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            value: _done,
            onChanged: (v) => setState(() => _done = v),
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.check_circle_outline),
            title: const Text('Gespräch durchgeführt'),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.check),
            label: Text(editing ? 'Änderungen speichern' : 'Gespräch planen'),
          ),
        ],
      ),
    );
  }
}

/// Vollbild-Mehrfachauswahl von Spielern (Foto + Suche, Checkboxen).
class _MultiPlayerPickPage extends StatefulWidget {
  const _MultiPlayerPickPage({required this.players, required this.selected});

  final List<Player> players;
  final List<String> selected;

  @override
  State<_MultiPlayerPickPage> createState() => _MultiPlayerPickPageState();
}

class _MultiPlayerPickPageState extends State<_MultiPlayerPickPage> {
  late final Set<String> _sel = {...widget.selected};
  String _query = '';

  List<Player> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return widget.players;
    return widget.players
        .where((p) => p.displayName.toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Spieler (${_sel.length})'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: FilledButton.icon(
              onPressed: () => Navigator.pop(context, _sel.toList()),
              icon: const Icon(Icons.check, size: 18),
              label: const Text('Fertig'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          TextField(
            onChanged: (v) => setState(() => _query = v),
            decoration: InputDecoration(
              hintText: 'Spieler suchen …',
              prefixIcon: const Icon(Icons.search),
              isDense: true,
              border: const OutlineInputBorder(),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () => setState(() => _query = ''),
                    ),
            ),
          ),
          const SizedBox(height: 8),
          for (final p in _filtered)
            CheckboxListTile(
              value: _sel.contains(p.id),
              onChanged: (v) => setState(() {
                if (v == true) {
                  _sel.add(p.id);
                } else {
                  _sel.remove(p.id);
                }
              }),
              secondary: PlayerAvatar(player: p, radius: 18),
              title: Text(p.displayName),
              subtitle: Text([
                if (p.number != null) 'Nr. ${p.number}',
                if (p.position != null) p.position!,
              ].join('  ·  ')),
              controlAffinity: ListTileControlAffinity.trailing,
              contentPadding: EdgeInsets.zero,
            ),
        ],
      ),
    );
  }
}
