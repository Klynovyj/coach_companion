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
  final String playerId;
  final String title;
  final DateTime scheduledAt;
  final String? notes;
  final bool done;
  const TalkFormData(
      this.playerId, this.title, this.scheduledAt, this.notes, this.done);
}

/// Formular zum Anlegen/Bearbeiten eines Spielergesprächs. [fixedPlayer] fixiert
/// den Spieler (z.B. aus dem Profil), sonst wird er per Picker gewählt.
Future<TalkFormData?> showTalkForm(
  BuildContext context, {
  PlayerTalk? existing,
  Player? fixedPlayer,
  required List<Player> players,
}) {
  return Navigator.push<TalkFormData>(
    context,
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _TalkFormPage(
        existing: existing,
        fixedPlayer: fixedPlayer,
        players: players,
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

class _SpielergespraecheScreenState extends State<SpielergespraecheScreen> {
  static final _df = DateFormat('EEE, dd.MM.yyyy  HH:mm', 'de_DE');

  Future<(List<PlayerTalk>, Map<String, Player>)> _load(AppState s) async {
    final talks = await s.talks();
    final team = s.ownTeam;
    final players = team == null ? <Player>[] : await s.playersOf(team.id);
    return (talks, {for (final p in players) p.id: p});
  }

  Future<void> _add(AppState state) async {
    final team = state.ownTeam;
    final players = team == null ? <Player>[] : await state.playersOf(team.id);
    if (!mounted) return;
    if (players.isEmpty) {
      _snack('Kein Kader vorhanden – Spieler zuerst ergänzen.');
      return;
    }
    final data = await showTalkForm(context, players: players);
    if (data == null) return;
    await state.addTalk(
      playerId: data.playerId,
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
    if (data == null || !mounted) return;
    await state.saveTalk(talk.copyWith(
      playerId: data.playerId,
      title: data.title,
      scheduledAt: data.scheduledAt,
      notes: data.notes,
      clearNotes: data.notes == null,
      done: data.done,
    ));
    if (mounted) setState(() {});
  }

  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      drawer: const AppDrawer(),
      appBar: AppBar(title: const Text('Spielergespräche')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _add(state),
        icon: const Icon(Icons.add),
        label: const Text('Gespräch'),
      ),
      body: FutureBuilder<(List<PlayerTalk>, Map<String, Player>)>(
        future: _load(state),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final talks = snap.data!.$1;
          final players = snap.data!.$2;
          if (talks.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.record_voice_over,
                        size: 56, color: Colors.grey),
                    SizedBox(height: 12),
                    Text(
                      'Noch keine Spielergespräche.\n'
                      'Unten rechts ein Gespräch planen.',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.only(bottom: 88),
            itemCount: talks.length,
            itemBuilder: (context, i) {
              final t = talks[i];
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
                      if (t.done) '✓ durchgeführt',
                      if (t.notes != null && t.notes!.isNotEmpty) '📝',
                    ].join('  ·  ')),
                    trailing: Checkbox(
                      value: t.done,
                      onChanged: (v) =>
                          state.saveTalk(t.copyWith(done: v ?? false)),
                    ),
                    onTap: () =>
                        _edit(state, t, players.values.toList(), p),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _TalkFormPage extends StatefulWidget {
  const _TalkFormPage({
    this.existing,
    this.fixedPlayer,
    required this.players,
  });

  final PlayerTalk? existing;
  final Player? fixedPlayer;
  final List<Player> players;

  @override
  State<_TalkFormPage> createState() => _TalkFormPageState();
}

class _TalkFormPageState extends State<_TalkFormPage> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _notesCtrl;
  late DateTime _date;
  String? _playerId;
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
    _playerId = widget.fixedPlayer?.id ?? e?.playerId;
    _done = e?.done ?? false;
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Player? get _selPlayer {
    final id = _playerId;
    if (id == null) return null;
    if (widget.fixedPlayer?.id == id) return widget.fixedPlayer;
    return widget.players.where((p) => p.id == id).firstOrNull;
  }

  Future<void> _pickPlayer() async {
    final res = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => PlayerPickerPage(
          players: widget.players,
          selected: _playerId,
          allowNone: false,
        ),
      ),
    );
    if (res == null || res == kPlayerPickNone) return;
    setState(() => _playerId = res);
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
    if (_playerId == null) {
      _snack('Bitte einen Spieler wählen.');
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
        _playerId!,
        _titleCtrl.text.trim(),
        _date,
        notes.isEmpty ? null : notes,
        _done,
      ),
    );
  }

  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing != null;
    final fixed = widget.fixedPlayer != null;
    final sel = _selPlayer;
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
          Row(
            children: [
              Text('Spieler:', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(width: 10),
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: sel != null
                      ? Chip(
                          avatar: PlayerAvatar(player: sel, radius: 11),
                          label: Text(sel.displayName),
                        )
                      : OutlinedButton.icon(
                          onPressed: _pickPlayer,
                          icon: const Icon(Icons.person_add_alt, size: 18),
                          label: const Text('Spieler wählen'),
                        ),
                ),
              ),
              if (sel != null && !fixed)
                TextButton(
                    onPressed: _pickPlayer, child: const Text('Ändern')),
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
