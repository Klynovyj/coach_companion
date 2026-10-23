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
import '../widgets/player_avatar.dart';
import '../widgets/reset_dialog.dart';
import '../widgets/team_logo.dart';
import 'rating_screen.dart';

/// Spielphasen des Live-Modus.
enum _Phase { notStarted, firstHalf, halftime, secondHalf, finished }

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
  Set<String> _starterIds = {}; // Startelf aus der Aufstellung
  List<MatchEvent> _events = [];
  bool _loading = true;

  // Live-Uhr & Spielphase
  Timer? _timer;
  int _elapsedSeconds = 0; // Gesamt-Spielzeit in Sekunden (2. HZ ab 45:00)
  bool _running = false;
  _Phase _phase = _Phase.notStarted;

  static const _halfSeconds = 45 * 60;
  static const _fullSeconds = 90 * 60;

  /// Aktuelle Fußball-Minute inkl. Nachspielzeit (z.B. 45 + 2).
  (int, int) get _footMinute {
    final sec = _elapsedSeconds;
    final secondHalf =
        _phase == _Phase.secondHalf || _phase == _Phase.finished;
    if (!secondHalf) {
      if (sec < _halfSeconds) return ((sec ~/ 60) + 1, 0);
      return (45, (sec ~/ 60) - 45 + 1);
    } else {
      if (sec < _fullSeconds) return ((sec ~/ 60) + 1, 0);
      return (90, (sec ~/ 60) - 90 + 1);
    }
  }

  int get _currentMinute => _footMinute.$1;
  int get _currentExtra => _footMinute.$2;

  late final AppState _state;

  @override
  void initState() {
    super.initState();
    _state = context.read<AppState>();
    _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _saveClock();
    super.dispose();
  }

  String get _clockKey => 'liveclock_${widget.matchId}';

  /// Sichert Spielphase + Uhr, damit die Zeit bei Rückkehr korrekt ist.
  void _saveClock() {
    _state.repository.setSetting(_clockKey,
        '${_phase.index}|$_elapsedSeconds|${_running ? 1 : 0}|${DateTime.now().millisecondsSinceEpoch}');
  }

  void _clearClock() {
    _state.repository.setSetting(_clockKey, null);
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
    // Startelf aus der Aufstellung (für Wechsel: Feld vs Bank).
    final starterIds = <String>{};
    final lineup = await state.repository.getLineup(widget.matchId, match.ownTeamId);
    if (lineup != null) {
      final entries = await state.lineupEntries(lineup.id);
      for (final e in entries) {
        if (e.role == LineupRole.starter) starterIds.add(e.playerId);
      }
    }
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
      _starterIds = starterIds;
      _events = events;
      // Spielphase aus den Phasen-Marken rekonstruieren.
      bool has(MatchEventType t) => events.any((e) => e.type == t);
      if (has(MatchEventType.fulltime) ||
          match!.status == MatchStatus.finished) {
        _phase = _Phase.finished;
        _elapsedSeconds = _fullSeconds;
      } else if (has(MatchEventType.secondHalfStart)) {
        _phase = _Phase.secondHalf;
        _elapsedSeconds = _halfSeconds;
      } else if (has(MatchEventType.halftime)) {
        _phase = _Phase.halftime;
        _elapsedSeconds = _halfSeconds;
      } else if (has(MatchEventType.kickoff)) {
        _phase = _Phase.firstHalf;
        _elapsedSeconds = 0;
      } else {
        _phase = _Phase.notStarted;
        _elapsedSeconds = 0;
      }
      _running = false; // beim Öffnen pausiert; Trainer setzt fort
      _loading = false;
    });

    // Gesicherte Uhr wiederherstellen (hat Vorrang vor der groben Rekonstruktion).
    final saved = await state.repository.getSetting(_clockKey);
    if (saved != null && mounted) {
      final parts = saved.split('|');
      if (parts.length == 4) {
        final phaseIdx = int.tryParse(parts[0]);
        final elapsed = int.tryParse(parts[1]);
        final wasRunning = parts[2] == '1';
        final ts = int.tryParse(parts[3]);
        if (phaseIdx != null &&
            elapsed != null &&
            ts != null &&
            phaseIdx >= 0 &&
            phaseIdx < _Phase.values.length) {
          var e = elapsed;
          if (wasRunning) {
            e += ((DateTime.now().millisecondsSinceEpoch - ts) / 1000).floor();
          }
          setState(() {
            _phase = _Phase.values[phaseIdx];
            _elapsedSeconds = e;
            _running = wasRunning;
          });
          if (wasRunning) _startTimer();
        }
      }
    }
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => _elapsedSeconds++);
      // Alle 10 Sekunden sichern (für korrekte Zeit bei Rückkehr).
      if (_elapsedSeconds % 10 == 0) _saveClock();
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

  Future<void> _logPhase(MatchEventType type, int minute, int extra) async {
    final m = _match!;
    await context.read<AppState>().addEvent(
          matchId: widget.matchId,
          teamId: m.ownTeamId,
          minute: minute,
          minuteExtra: extra,
          type: type,
          note: '${m.ownScore}:${m.opponentScore}',
        );
  }

  /// Anpfiff 1. Halbzeit.
  Future<void> _kickoff() async {
    await context.read<AppState>().setMatchStatus(widget.matchId, MatchStatus.live);
    setState(() {
      _phase = _Phase.firstHalf;
      _elapsedSeconds = 0;
      _running = true;
    });
    _startTimer();
    _saveClock();
    await _logPhase(MatchEventType.kickoff, 1, 0);
    await _refreshEvents();
  }

  /// Halbzeitpfiff: Uhr hält, 1. HZ zu Ende.
  Future<void> _halftime() async {
    _timer?.cancel();
    final (min, extra) = _footMinute;
    setState(() {
      _phase = _Phase.halftime;
      _running = false;
    });
    _saveClock();
    await _logPhase(MatchEventType.halftime, min, extra);
    await _refreshEvents();
  }

  /// Anpfiff 2. Halbzeit (ab 45:00).
  Future<void> _startSecondHalf() async {
    setState(() {
      _phase = _Phase.secondHalf;
      _elapsedSeconds = _halfSeconds;
      _running = true;
    });
    _startTimer();
    _saveClock();
    await _logPhase(MatchEventType.secondHalfStart, 46, 0);
    await _refreshEvents();
  }

  void _togglePause() {
    setState(() => _running = !_running);
    if (_running) {
      _startTimer();
    } else {
      _timer?.cancel();
    }
    _saveClock();
  }

  /// Abpfiff: Spielende.
  Future<void> _finish() async {
    _timer?.cancel();
    final (min, extra) = _footMinute;
    setState(() {
      _phase = _Phase.finished;
      _running = false;
    });
    _saveClock();
    await context
        .read<AppState>()
        .setMatchStatus(widget.matchId, MatchStatus.finished);
    await _logPhase(MatchEventType.fulltime, min, extra);
    await _refreshEvents();
    if (mounted) await _promptRating();
  }

  /// Direkt nach Abpfiff zum Bewerten einladen (jederzeit auch später möglich).
  Future<void> _promptRating() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Spiel beendet'),
        content: const Text('Möchtest du die Spieler jetzt bewerten?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Später')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Jetzt bewerten')),
        ],
      ),
    );
    if (go == true && mounted) {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => RatingScreen(matchId: widget.matchId),
        ),
      );
    }
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
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'reset') _resetMatch();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'reset', child: Text('Spiel zurücksetzen')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          _Scoreboard(
            match: match,
            ownName: _ownTeam?.shortName ?? _ownTeam?.name ?? 'Heim',
            oppName: _opponentTeam?.name ?? match.opponentName,
            ownLogo: _ownTeam?.logoPath,
            oppLogo: _opponentTeam?.logoPath ?? match.opponentLogoPath,
            clockText: _clockText,
            minute: _currentMinute,
            extra: _currentExtra,
            phase: _phase,
            running: _running,
          ),
          _Controls(
            phase: _phase,
            running: _running,
            onKickoff: _kickoff,
            onHalftime: _halftime,
            onSecondHalf: _startSecondHalf,
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

  /// Eigene Spieler, die aktuell auf dem Feld stehen (für Tor/Karte).
  List<Player> _onFieldPlayers(bool ownSide) {
    if (!ownSide) return _opponentPlayers;
    final ids = _onFieldIds;
    return _ownPlayers.where((p) => ids.contains(p.id)).toList();
  }

  /// Wer aktuell auf dem Feld steht: Startelf, fortgeschrieben durch alle
  /// bisherigen Wechsel (ein Spieler kann hin- und zurückgewechselt werden).
  Set<String> get _onFieldIds {
    final onField = _starterIds.isNotEmpty
        ? {..._starterIds}
        : {..._nominatedIds}; // Fallback ohne Aufstellung
    for (final e in _events) {
      if (e.type != MatchEventType.substitution) continue;
      final off = e.assistPlayerId; // geht
      final on = e.playerId; // kommt
      if (off != null) onField.remove(off);
      if (on != null) onField.add(on);
    }
    return onField;
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

    // Gegner-Tor: einfach ein Tor (nur für den Spielstand) – ohne Torschütze/Vorlage.
    if (!ownSide) {
      await state.addEvent(
        matchId: widget.matchId,
        teamId: _teamIdFor(false),
        minute: _currentMinute,
        minuteExtra: _currentExtra,
        type: MatchEventType.goal,
      );
      await _refreshEvents();
      return;
    }

    // Nur Spieler, die aktuell auf dem Feld sind (Bank kann nicht treffen).
    final players = _onFieldPlayers(ownSide);
    // Eigenes Tor: Torschütze direkt wählen (oder "Unbekannt").
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
      minuteExtra: _currentExtra,
      type: MatchEventType.goal,
      playerId: scorer == _pickUnknown ? null : scorer,
      assistPlayerId: assistId,
    );
    await _refreshEvents();
  }

  Future<void> _addCard({required bool ownSide}) async {
    final state = context.read<AppState>();
    // Karte nur für Spieler auf dem Feld.
    final players = _onFieldPlayers(ownSide);
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
      minuteExtra: _currentExtra,
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
    // Raus = aktuell auf dem Feld, Rein = aktuell auf der Bank.
    final onIds = _onFieldIds;
    final onField = players.where((p) => onIds.contains(p.id)).toList();
    final bench = players.where((p) => !onIds.contains(p.id)).toList();
    if (onField.isEmpty) {
      _snack('Niemand auf dem Feld – bitte zuerst aufstellen.');
      return;
    }
    if (bench.isEmpty) {
      _snack('Keine Spieler auf der Bank für einen Wechsel.');
      return;
    }
    final off = await _pickPlayer(
      title: 'Raus (auf dem Feld)',
      players: onField,
      allowUnknown: false,
    );
    if (off == _pickCancelled || !mounted) return;
    final on = await _pickPlayer(
      title: 'Rein (von der Bank)',
      players: bench,
      allowUnknown: false,
    );
    if (on == _pickCancelled) return;
    await state.addEvent(
      matchId: widget.matchId,
      teamId: _teamIdFor(ownSide),
      minute: _currentMinute,
      minuteExtra: _currentExtra,
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

  Future<void> _resetMatch() async {
    final match = _match;
    if (match == null) return;
    final choice = await showResetMatchDialog(context);
    if (choice == null || !choice.any || !mounted) return;
    _timer?.cancel();
    await context.read<AppState>().resetMatchParts(
          widget.matchId,
          match.ownTeamId,
          verlauf: choice.verlauf,
          aufstellung: choice.aufstellung,
          nominierung: choice.nominierung,
        );
    if (!mounted) return;
    if (choice.verlauf) {
      _clearClock();
      setState(() {
        _phase = _Phase.notStarted;
        _elapsedSeconds = 0;
        _running = false;
      });
    }
    await _load();
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
      showDragHandle: true,
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
    required this.ownLogo,
    required this.oppLogo,
    required this.clockText,
    required this.minute,
    required this.extra,
    required this.phase,
    required this.running,
  });

  final GameMatch match;
  final String ownName;
  final String oppName;
  final String? ownLogo;
  final String? oppLogo;
  final String clockText;
  final int minute;
  final int extra;
  final _Phase phase;
  final bool running;

  String get _minuteLabel {
    switch (phase) {
      case _Phase.notStarted:
        return 'Anpfiff ausstehend';
      case _Phase.halftime:
        return 'Halbzeit';
      case _Phase.finished:
        return 'Spielende';
      default:
        return extra > 0 ? "$minute+$extra'" : "$minute'";
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final live = phase == _Phase.firstHalf || phase == _Phase.secondHalf;
    return Container(
      width: double.infinity,
      color: scheme.primary,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (live && running)
                Container(
                  margin: const EdgeInsets.only(right: 8),
                  width: 10,
                  height: 10,
                  decoration: const BoxDecoration(
                      color: Colors.red, shape: BoxShape.circle),
                ),
              Text(
                phase == _Phase.finished ? 'Beendet' : clockText,
                style: TextStyle(
                    color: scheme.onPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 10),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.onPrimary.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(_minuteLabel,
                    style: TextStyle(
                        color: scheme.onPrimary,
                        fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(child: _side(scheme, ownLogo, ownName)),
              Text('${match.ownScore} : ${match.opponentScore}',
                  style: TextStyle(
                      color: scheme.onPrimary,
                      fontSize: 34,
                      fontWeight: FontWeight.bold)),
              Expanded(child: _side(scheme, oppLogo, oppName)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _side(ColorScheme scheme, String? logo, String name) {
    return Column(
      children: [
        if (logo != null) ...[
          TeamLogo(logoPath: logo, size: 40),
          const SizedBox(height: 4),
        ],
        Text(name,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: scheme.onPrimary, fontWeight: FontWeight.bold)),
      ],
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.phase,
    required this.running,
    required this.onKickoff,
    required this.onHalftime,
    required this.onSecondHalf,
    required this.onPause,
    required this.onFinish,
  });

  final _Phase phase;
  final bool running;
  final VoidCallback onKickoff;
  final VoidCallback onHalftime;
  final VoidCallback onSecondHalf;
  final VoidCallback onPause;
  final VoidCallback onFinish;

  @override
  Widget build(BuildContext context) {
    Widget wrap(List<Widget> children) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(children: children),
        );

    if (phase == _Phase.finished) {
      return wrap([
        Expanded(
          child: OutlinedButton.icon(
            onPressed: onKickoff,
            icon: const Icon(Icons.replay),
            label: const Text('Neues Spiel starten'),
          ),
        ),
      ]);
    }

    // Primärer Button vereint Anpfiff / Pause / Weiter / Anpfiff 2. Halbzeit.
    final VoidCallback onPrimary;
    final IconData icon;
    final String label;
    if (running) {
      onPrimary = onPause;
      icon = Icons.pause;
      label = 'Pause';
    } else {
      switch (phase) {
        case _Phase.notStarted:
          onPrimary = onKickoff;
          label = 'Anpfiff';
        case _Phase.halftime:
          onPrimary = onSecondHalf;
          label = 'Anpfiff 2. Halbzeit';
        default: // firstHalf/secondHalf pausiert
          onPrimary = onPause;
          label = 'Weiter';
      }
      icon = Icons.play_arrow;
    }

    final primary = Expanded(
      child: FilledButton.icon(
        onPressed: onPrimary,
        icon: Icon(icon),
        label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );

    // Sekundärer Button: Halbzeit (1. HZ) bzw. Abpfiff (2. HZ).
    Widget? secondary;
    if (phase == _Phase.firstHalf) {
      secondary = Expanded(
        child: OutlinedButton.icon(
          onPressed: onHalftime,
          icon: const Icon(Icons.timer),
          label: const Text('Halbzeit'),
        ),
      );
    } else if (phase == _Phase.secondHalf) {
      secondary = Expanded(
        child: FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: Colors.red),
          onPressed: onFinish,
          icon: const Icon(Icons.stop),
          label: const Text('Abpfiff'),
        ),
      );
    }

    return wrap([
      primary,
      if (secondary != null) ...[const SizedBox(width: 8), secondary],
    ]);
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
          if (e.type.isPhaseMarker) return _phaseRow(context, e);
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
                child: Text(
                    e.minuteExtra > 0
                        ? '${e.minute}+${e.minuteExtra}'
                        : "${e.minute}'",
                    style: const TextStyle(fontSize: 10)),
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

  Widget _phaseRow(BuildContext context, MatchEvent e) {
    final score = e.note ?? '';
    final label = '${e.type.label}${score.isNotEmpty ? '  ·  $score' : ''}';
    return InkWell(
      onTap: () => onEdit(e),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            const Expanded(child: Divider()),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(label,
                  style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.outline)),
            ),
            const Expanded(child: Divider()),
          ],
        ),
      ),
    );
  }

  String _describe(MatchEvent e) {
    switch (e.type) {
      case MatchEventType.goal:
        if (e.playerId == null) return 'Tor'; // z.B. Gegner-Tor
        final assist = e.assistPlayerId == null
            ? ''
            : ' (Vorlage: ${resolveName(e.assistPlayerId)})';
        return 'Tor – ${resolveName(e.playerId)}$assist';
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
      case MatchEventType.kickoff:
      case MatchEventType.halftime:
      case MatchEventType.secondHalfStart:
      case MatchEventType.fulltime:
        return e.type.label;
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
    final maxH = MediaQuery.of(context).size.height * 0.7;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Text(title,
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold)),
            ),
            const Divider(height: 1),
            if (players.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Keine Spieler auf dem Feld.'),
              ),
            Flexible(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 8),
                children: [
                  for (final p in players)
                    ListTile(
                      leading: PlayerAvatar(player: p),
                      title: Text(p.fullName),
                      subtitle: Text([
                        if (p.number != null) 'Nr. ${p.number}',
                        if (p.position != null) p.position!,
                      ].join('  ·  ')),
                      onTap: () => Navigator.pop(context, p.id),
                    ),
                  if (allowUnknown)
                    ListTile(
                      leading: const CircleAvatar(
                          child: Icon(Icons.help_outline)),
                      title: const Text('Unbekannt'),
                      onTap: () => Navigator.pop(context, unknownValue),
                    ),
                  if (allowNone)
                    ListTile(
                      leading:
                          const CircleAvatar(child: Icon(Icons.block)),
                      title: const Text('Keine (ohne Vorlage)'),
                      onTap: () => Navigator.pop(context, noneValue),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
