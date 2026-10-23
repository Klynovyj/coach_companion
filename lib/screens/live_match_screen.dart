import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/enums.dart';
import '../models/match.dart';
import '../models/match_event.dart';
import '../models/player.dart';
import '../models/team.dart';
import '../services/share_service.dart';
import '../state/app_state.dart';

/// Live-Spielerfassung für beide Mannschaften.
///
/// Tore, Karten und Wechsel werden mit wenigen Klicks erfasst; jede Aktion
/// bekommt automatisch die aktuelle Spielminute aus der Live-Uhr. Der
/// Spielstand aktualisiert sich bei Toren automatisch.
class LiveMatchScreen extends StatefulWidget {
  const LiveMatchScreen({super.key, required this.matchId});
  final String matchId;

  @override
  State<LiveMatchScreen> createState() => _LiveMatchScreenState();
}

class _LiveMatchScreenState extends State<LiveMatchScreen> {
  GameMatch? _match;
  Team? _ownTeam;
  Team? _opponentTeam;
  List<Player> _ownPlayers = [];
  List<Player> _opponentPlayers = [];
  Set<String> _nominatedIds = {};
  List<MatchEvent> _events = [];
  bool _loading = true;

  // Live-Uhr
  Timer? _timer;
  int _elapsedSeconds = 0;
  bool _running = false;

  int get _currentMinute => (_elapsedSeconds ~/ 60) + 1;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    var match = await state.getMatch(widget.matchId);
    if (match == null) {
      setState(() => _loading = false);
      return;
    }
    // Gegner-Team sicherstellen (Platzhalter), falls noch nicht verknüpft.
    if (match.opponentTeamId == null) {
      await state.openMatch(match);
      match = await state.getMatch(widget.matchId);
    }
    final own = await state.repository.getTeam(match!.ownTeamId);
    final opp = match.opponentTeamId == null
        ? null
        : await state.repository.getTeam(match.opponentTeamId!);
    final ownPlayers = await state.playersOf(match.ownTeamId);
    final oppPlayers =
        opp == null ? <Player>[] : await state.playersOf(opp.id);
    final events = await state.eventsOf(widget.matchId);
    final noms = await state.nominationsOf(widget.matchId);
    if (!mounted) return;
    setState(() {
      _match = match;
      _ownTeam = own;
      _opponentTeam = opp;
      _ownPlayers = ownPlayers;
      _opponentPlayers = oppPlayers;
      _nominatedIds = {
        for (final e in noms.entries)
          if (e.value == NominationStatus.zugesagt) e.key,
      };
      _events = events;
      _running = match!.status == MatchStatus.live;
      _loading = false;
    });
    if (_running) _startTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => _elapsedSeconds++);
    });
  }

  Future<void> _refreshEvents() async {
    final state = context.read<AppState>();
    final match = await state.getMatch(widget.matchId);
    final events = await state.eventsOf(widget.matchId);
    if (!mounted) return;
    setState(() {
      _match = match;
      _events = events;
    });
  }

  Future<void> _kickoff() async {
    await context.read<AppState>().setMatchStatus(widget.matchId, MatchStatus.live);
    setState(() => _running = true);
    _startTimer();
    await _refreshEvents();
  }

  void _togglePause() {
    setState(() => _running = !_running);
    if (_running) {
      _startTimer();
    } else {
      _timer?.cancel();
    }
  }

  Future<void> _finish() async {
    _timer?.cancel();
    setState(() => _running = false);
    await context
        .read<AppState>()
        .setMatchStatus(widget.matchId, MatchStatus.finished);
    await _refreshEvents();
  }

  String get _clockText {
    final m = (_elapsedSeconds ~/ 60).toString().padLeft(2, '0');
    final s = (_elapsedSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final match = _match;
    if (match == null) {
      return const Scaffold(body: Center(child: Text('Spiel nicht gefunden.')));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Live-Spiel'),
        actions: [
          IconButton(
            tooltip: 'Bericht teilen (WhatsApp)',
            icon: const Icon(Icons.share),
            onPressed: _shareReport,
          ),
        ],
      ),
      body: Column(
        children: [
          _Scoreboard(
            match: match,
            ownName: _ownTeam?.shortName ?? _ownTeam?.name ?? 'Heim',
            oppName: _opponentTeam?.name ?? match.opponentName,
            clockText: _clockText,
            minute: _currentMinute,
            running: _running,
            status: match.status,
          ),
          _Controls(
            status: match.status,
            running: _running,
            onKickoff: _kickoff,
            onPause: _togglePause,
            onFinish: _finish,
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 16),
              children: [
                _TeamActionBar(
                  label: _ownTeam?.name ?? 'Eigenes Team',
                  color: Theme.of(context).colorScheme.primary,
                  onGoal: () => _addGoal(ownSide: true),
                  onCard: () => _addCard(ownSide: true),
                  onSub: () => _addSub(ownSide: true),
                ),
                _TeamActionBar(
                  label: match.opponentName,
                  color: Theme.of(context).colorScheme.tertiary,
                  onGoal: () => _addGoal(ownSide: false),
                  // Gegner: nur Tore für den Spielstand – keine Karten/Wechsel.
                  onCard: null,
                  onSub: null,
                ),
                const SizedBox(height: 8),
                _EventLog(
                  events: _events,
                  ownTeamId: match.ownTeamId,
                  resolveName: _playerName,
                  onDelete: _deleteEvent,
                  onEdit: _editEvent,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _teamIdFor(bool ownSide) =>
      ownSide ? _match!.ownTeamId : (_opponentTeam?.id ?? _match!.ownTeamId);

  List<Player> _playersFor(bool ownSide) {
    if (!ownSide) return _opponentPlayers;
    // Eigenes Team: ausschließlich nominierte (zugesagte) Spieler.
    return _ownPlayers.where((p) => _nominatedIds.contains(p.id)).toList();
  }

  String _playerName(String? playerId) {
    if (playerId == null) return 'Unbekannt';
    final all = [..._ownPlayers, ..._opponentPlayers];
    final p = all.where((e) => e.id == playerId).firstOrNull;
    return p?.displayName ?? 'Spieler';
  }

  // ------------------------------------------------- Ereignis-Erfassung
  Future<void> _addGoal({required bool ownSide}) async {
    final state = context.read<AppState>();
    final players = _playersFor(ownSide);
    // Wenige Klicks: Torschütze direkt wählen (oder "Unbekannt").
    final scorer = await _pickPlayer(
      title: 'Torschütze',
      players: players,
      allowUnknown: true,
    );
    if (scorer == _pickCancelled) return;

    String? assistId;
    if (players.isNotEmpty) {
      final assist = await _pickPlayer(
        title: 'Vorlage (optional)',
        players: players.where((p) => p.id != scorer).toList(),
        allowUnknown: false,
        allowNone: true,
      );
      if (assist != _pickCancelled && assist != _pickNone) assistId = assist;
    }

    await state.addEvent(
      matchId: widget.matchId,
      teamId: _teamIdFor(ownSide),
      minute: _currentMinute,
      type: MatchEventType.goal,
      playerId: scorer == _pickUnknown ? null : scorer,
      assistPlayerId: assistId,
    );
    await _refreshEvents();
  }

  Future<void> _addCard({required bool ownSide}) async {
    final state = context.read<AppState>();
    final players = _playersFor(ownSide);
    final player = await _pickPlayer(
      title: 'Spieler',
      players: players,
      allowUnknown: true,
    );
    if (player == _pickCancelled || !mounted) return;
    final type = await showModalBottomSheet<MatchEventType>(
      context: context,
      builder: (_) => _CardTypeSheet(),
    );
    if (type == null) return;
    await state.addEvent(
      matchId: widget.matchId,
      teamId: _teamIdFor(ownSide),
      minute: _currentMinute,
      type: type,
      playerId: player == _pickUnknown ? null : player,
    );
    await _refreshEvents();
  }

  Future<void> _addSub({required bool ownSide}) async {
    final state = context.read<AppState>();
    final players = _playersFor(ownSide);
    if (players.isEmpty) {
      _snack('Kein Kader vorhanden – Spieler zuerst ergänzen.');
      return;
    }
    final off = await _pickPlayer(
      title: 'Raus',
      players: players,
      allowUnknown: false,
    );
    if (off == _pickCancelled) return;
    final on = await _pickPlayer(
      title: 'Rein',
      players: players.where((p) => p.id != off).toList(),
      allowUnknown: false,
    );
    if (on == _pickCancelled) return;
    await state.addEvent(
      matchId: widget.matchId,
      teamId: _teamIdFor(ownSide),
      minute: _currentMinute,
      type: MatchEventType.substitution,
      playerId: on, // kommt
      assistPlayerId: off, // geht
    );
    await _refreshEvents();
  }

  Future<void> _deleteEvent(MatchEvent e) async {
    await context.read<AppState>().deleteEvent(widget.matchId, e.id);
    await _refreshEvents();
  }

  /// Ereignis korrigieren: Minute ändern oder löschen.
  Future<void> _editEvent(MatchEvent e) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text('${e.type.symbol} ${e.type.label} · ${e.minute}\''),
              subtitle: Text(_playerName(e.playerId)),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.timer),
              title: const Text('Minute ändern'),
              onTap: () => Navigator.pop(context, 'minute'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('Löschen'),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'delete') {
      await _deleteEvent(e);
    } else if (action == 'minute') {
      final ctrl = TextEditingController(text: '${e.minute}');
      final newMin = await showDialog<int>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Minute'),
          content: TextField(
            controller: ctrl,
            keyboardType: TextInputType.number,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Spielminute'),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Abbrechen')),
            FilledButton(
                onPressed: () =>
                    Navigator.pop(context, int.tryParse(ctrl.text.trim())),
                child: const Text('Speichern')),
          ],
        ),
      );
      if (newMin != null && mounted) {
        await context.read<AppState>().updateEvent(e.copyWith(minute: newMin));
        await _refreshEvents();
      }
    }
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _shareReport() async {
    final match = _match;
    if (match == null) return;
    final text = buildMatchReport(
      match: match,
      ownName: teamDisplay(_ownTeam, 'Heim'),
      oppName: _opponentTeam?.name ?? match.opponentName,
      events: _events,
      resolveName: _playerName,
    );
    final ok = await shareViaWhatsApp(text);
    if (!ok) _snack('WhatsApp konnte nicht geöffnet werden.');
  }

  // Spieler-Picker; Rückgabe: playerId, _pickUnknown, _pickNone oder _pickCancelled.
  static const _pickCancelled = '__cancel__';
  static const _pickUnknown = '__unknown__';
  static const _pickNone = '__none__';

  Future<String> _pickPlayer({
    required String title,
    required List<Player> players,
    bool allowUnknown = false,
    bool allowNone = false,
  }) async {
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _PlayerPickSheet(
        title: title,
        players: players,
        allowUnknown: allowUnknown,
        allowNone: allowNone,
        unknownValue: _pickUnknown,
        noneValue: _pickNone,
      ),
    );
    return result ?? _pickCancelled;
  }
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}

// --------------------------------------------------------------- Widgets

class _Scoreboard extends StatelessWidget {
  const _Scoreboard({
    required this.match,
    required this.ownName,
    required this.oppName,
    required this.clockText,
    required this.minute,
    required this.running,
    required this.status,
  });

  final GameMatch match;
  final String ownName;
  final String oppName;
  final String clockText;
  final int minute;
  final bool running;
  final MatchStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.primary,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (status == MatchStatus.live)
                Container(
                  margin: const EdgeInsets.only(right: 8),
                  width: 10,
                  height: 10,
                  decoration: const BoxDecoration(
                      color: Colors.red, shape: BoxShape.circle),
                ),
              Text(
                status == MatchStatus.finished ? 'Beendet' : clockText,
                style: TextStyle(
                    color: scheme.onPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w600),
              ),
              if (status != MatchStatus.finished) ...[
                const SizedBox(width: 10),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: scheme.onPrimary.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text("$minute'",
                      style: TextStyle(
                          color: scheme.onPrimary,
                          fontWeight: FontWeight.bold)),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(ownName,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: scheme.onPrimary,
                        fontWeight: FontWeight.bold)),
              ),
              Text('${match.ownScore} : ${match.opponentScore}',
                  style: TextStyle(
                      color: scheme.onPrimary,
                      fontSize: 34,
                      fontWeight: FontWeight.bold)),
              Expanded(
                child: Text(oppName,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: scheme.onPrimary,
                        fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.status,
    required this.running,
    required this.onKickoff,
    required this.onPause,
    required this.onFinish,
  });

  final MatchStatus status;
  final bool running;
  final VoidCallback onKickoff;
  final VoidCallback onPause;
  final VoidCallback onFinish;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          if (status == MatchStatus.scheduled)
            Expanded(
              child: FilledButton.icon(
                onPressed: onKickoff,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Anpfiff'),
              ),
            ),
          if (status == MatchStatus.live) ...[
            Expanded(
              child: OutlinedButton.icon(
                onPressed: onPause,
                icon: Icon(running ? Icons.pause : Icons.play_arrow),
                label: Text(running ? 'Pause' : 'Weiter'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: Colors.red),
                onPressed: onFinish,
                icon: const Icon(Icons.stop),
                label: const Text('Abpfiff'),
              ),
            ),
          ],
          if (status == MatchStatus.finished)
            Expanded(
              child: OutlinedButton.icon(
                onPressed: onKickoff,
                icon: const Icon(Icons.replay),
                label: const Text('Erneut starten'),
              ),
            ),
        ],
      ),
    );
  }
}

class _TeamActionBar extends StatelessWidget {
  const _TeamActionBar({
    required this.label,
    required this.color,
    required this.onGoal,
    this.onCard,
    this.onSub,
  });

  final String label;
  final Color color;
  final VoidCallback onGoal;
  final VoidCallback? onCard;
  final VoidCallback? onSub;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(width: 4, height: 18, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: onGoal,
                    icon: const Text('⚽', style: TextStyle(fontSize: 16)),
                    label: const Text('Tor'),
                  ),
                ),
                if (onCard != null) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onCard,
                      icon: const Icon(Icons.style, size: 18),
                      label: const Text('Karte'),
                    ),
                  ),
                ],
                if (onSub != null) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onSub,
                      icon: const Icon(Icons.swap_horiz, size: 18),
                      label: const Text('Wechsel'),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _EventLog extends StatelessWidget {
  const _EventLog({
    required this.events,
    required this.ownTeamId,
    required this.resolveName,
    required this.onDelete,
    required this.onEdit,
  });

  final List<MatchEvent> events;
  final String ownTeamId;
  final String Function(String?) resolveName;
  final Future<void> Function(MatchEvent) onDelete;
  final void Function(MatchEvent) onEdit;

  @override
  Widget build(BuildContext context) {
    if (events.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(
          child: Text('Noch keine Ereignisse erfasst.',
              style: TextStyle(color: Colors.grey)),
        ),
      );
    }
    final reversed = events.reversed.toList();
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('Ticker', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ),
        ...reversed.map((e) {
          final own = e.teamId == ownTeamId;
          return Dismissible(
            key: ValueKey(e.id),
            direction: DismissDirection.endToStart,
            background: Container(
              color: Colors.red,
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 20),
              child: const Icon(Icons.delete, color: Colors.white),
            ),
            onDismissed: (_) => onDelete(e),
            child: ListTile(
              dense: true,
              leading: CircleAvatar(
                radius: 16,
                backgroundColor: own
                    ? Theme.of(context).colorScheme.primaryContainer
                    : Theme.of(context).colorScheme.tertiaryContainer,
                child: Text("${e.minute}'",
                    style: const TextStyle(fontSize: 11)),
              ),
              title: Text('${e.type.symbol} ${_describe(e)}'),
              subtitle: Text(own ? 'Eigenes Team' : 'Gegner'),
              trailing: IconButton(
                tooltip: 'Korrigieren',
                icon: const Icon(Icons.more_vert),
                onPressed: () => onEdit(e),
              ),
              onTap: () => onEdit(e),
            ),
          );
        }),
      ],
    );
  }

  String _describe(MatchEvent e) {
    switch (e.type) {
      case MatchEventType.goal:
        final scorer = resolveName(e.playerId);
        final assist = e.assistPlayerId == null
            ? ''
            : ' (Vorlage: ${resolveName(e.assistPlayerId)})';
        return 'Tor – $scorer$assist';
      case MatchEventType.ownGoal:
        return 'Eigentor – ${resolveName(e.playerId)}';
      case MatchEventType.substitution:
        return 'Wechsel – ${resolveName(e.playerId)} für ${resolveName(e.assistPlayerId)}';
      case MatchEventType.yellowCard:
        return 'Gelbe Karte – ${resolveName(e.playerId)}';
      case MatchEventType.secondYellow:
        return 'Gelb-Rot – ${resolveName(e.playerId)}';
      case MatchEventType.redCard:
        return 'Rote Karte – ${resolveName(e.playerId)}';
    }
  }
}

class _CardTypeSheet extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const ListTile(title: Text('Kartentyp')),
          ListTile(
            leading: const Text('🟨', style: TextStyle(fontSize: 22)),
            title: const Text('Gelbe Karte'),
            onTap: () => Navigator.pop(context, MatchEventType.yellowCard),
          ),
          ListTile(
            leading: const Text('🟨🟥', style: TextStyle(fontSize: 18)),
            title: const Text('Gelb-Rote Karte'),
            onTap: () => Navigator.pop(context, MatchEventType.secondYellow),
          ),
          ListTile(
            leading: const Text('🟥', style: TextStyle(fontSize: 22)),
            title: const Text('Rote Karte'),
            onTap: () => Navigator.pop(context, MatchEventType.redCard),
          ),
        ],
      ),
    );
  }
}

class _PlayerPickSheet extends StatelessWidget {
  const _PlayerPickSheet({
    required this.title,
    required this.players,
    required this.allowUnknown,
    required this.allowNone,
    required this.unknownValue,
    required this.noneValue,
  });

  final String title;
  final List<Player> players;
  final bool allowUnknown;
  final bool allowNone;
  final String unknownValue;
  final String noneValue;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(title,
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            if (players.isEmpty)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('Kein Kader vorhanden.'),
              ),
            Flexible(
              child: SingleChildScrollView(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final p in players)
                      ActionChip(
                        avatar: CircleAvatar(
                          radius: 12,
                          child: Text(p.number?.toString() ?? '?',
                              style: const TextStyle(fontSize: 10)),
                        ),
                        label: Text(p.fullName),
                        onPressed: () => Navigator.pop(context, p.id),
                      ),
                    if (allowUnknown)
                      ActionChip(
                        avatar: const Icon(Icons.help_outline, size: 16),
                        label: const Text('Unbekannt'),
                        onPressed: () => Navigator.pop(context, unknownValue),
                      ),
                    if (allowNone)
                      ActionChip(
                        avatar: const Icon(Icons.block, size: 16),
                        label: const Text('Keine'),
                        onPressed: () => Navigator.pop(context, noneValue),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
