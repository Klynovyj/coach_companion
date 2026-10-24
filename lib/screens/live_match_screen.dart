import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/enums.dart';
import '../models/match.dart';
import '../models/match_event.dart';
import '../models/player.dart';
import '../models/team.dart';
import '../services/live_clock.dart';
import '../services/share_service.dart';
import '../state/app_state.dart';
import '../widgets/player_avatar.dart';
import '../widgets/reset_dialog.dart';
import '../widgets/team_logo.dart';

/// Spielphasen des Live-Modus.
enum _Phase {
  notStarted,
  firstHalf,
  halftime,
  secondHalf,
  finished,
  // Pokal: Verlängerung (2×15) + Elfmeterschießen.
  extraFirstHalf,
  extraHalftime,
  extraSecondHalf,
  shootout,
}

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

  // Anker für die aus den Phasen-Marken abgeleitete Uhr: Basiszeit der Phase
  // (z.B. 45:00 für die 2. HZ) und Wall-Clock-Zeitpunkt der Marke in ms. Damit
  // läuft die Uhr auf allen Geräten identisch (siehe _deriveClock).
  int _baseElapsed = 0;
  int? _anchorMs;

  // Berechtigte (Trainer/Ticker) können hier auf „nur zuschauen" umschalten.
  bool _watchMode = false;

  static const _halfSeconds = 45 * 60;
  static const _fullSeconds = 90 * 60;
  static const _extraFirstEnd = 105 * 60;
  static const _fullExtra = 120 * 60;

  /// Aktuelle Fußball-Minute inkl. Nachspielzeit (z.B. 45 + 2).
  (int, int) get _footMinute {
    final m = _elapsedSeconds ~/ 60;
    switch (_phase) {
      case _Phase.secondHalf:
        if (_elapsedSeconds < _fullSeconds) return (m + 1, 0);
        return (90, m - 90 + 1);
      case _Phase.extraFirstHalf:
      case _Phase.extraHalftime:
        if (_elapsedSeconds < _extraFirstEnd) return (m + 1, 0);
        return (105, m - 105 + 1);
      case _Phase.extraSecondHalf:
      case _Phase.shootout:
        if (_elapsedSeconds < _fullExtra) return (m + 1, 0);
        return (120, m - 120 + 1);
      default: // notStarted, firstHalf, halftime, finished
        if (_elapsedSeconds < _halfSeconds) return (m + 1, 0);
        return (45, m - 45 + 1);
    }
  }

  int get _currentMinute => _footMinute.$1;
  int get _currentExtra => _footMinute.$2;

  late final AppState _state;

  @override
  void initState() {
    super.initState();
    _state = context.read<AppState>();
    // Eingehende Live-Daten anderer Trainer (per Realtime) sofort anzeigen.
    _state.addListener(_onAppStateChanged);
    // Eigene Live-Rolle (Mitschreiben vs. Zuschauer) frisch ermitteln.
    _state.refreshLiveRole();
    _load();
  }

  void _onAppStateChanged() {
    if (mounted) _refreshEvents();
  }

  @override
  void dispose() {
    _state.removeListener(_onAppStateChanged);
    _timer?.cancel();
    super.dispose();
  }

  /// Leitet Spielphase + Uhr aus den Phasen-Marken (kickoff/halftime/… als
  /// Ereignisse) ab. Da diese Marken über die Cloud synchronisieren und einen
  /// gemeinsamen Zeitstempel tragen, ergibt sich auf jedem Gerät dieselbe Uhr –
  /// ohne eigene Cloud-Spalte. Die späteste Marke gewinnt (robust gegen
  /// Reihenfolge und „Verlängerung nach Abpfiff").
  ({_Phase phase, int base, bool running, int? anchorMs}) _deriveClock(
      List<MatchEvent> events) {
    const markers = <MatchEventType, (_Phase, int, bool)>{
      MatchEventType.kickoff: (_Phase.firstHalf, 0, true),
      MatchEventType.halftime: (_Phase.halftime, _halfSeconds, false),
      MatchEventType.secondHalfStart: (_Phase.secondHalf, _halfSeconds, true),
      MatchEventType.fulltime: (_Phase.finished, _fullSeconds, false),
      MatchEventType.extraFirstStart: (_Phase.extraFirstHalf, _fullSeconds, true),
      MatchEventType.extraHalftimeMark:
          (_Phase.extraHalftime, _extraFirstEnd, false),
      MatchEventType.extraSecondStart:
          (_Phase.extraSecondHalf, _extraFirstEnd, true),
      MatchEventType.shootoutStart: (_Phase.shootout, _fullExtra, false),
    };
    MatchEvent? latest;
    for (final e in events) {
      if (!markers.containsKey(e.type)) continue;
      if (latest == null || e.createdAt.isAfter(latest.createdAt)) latest = e;
    }
    if (latest == null) {
      return (phase: _Phase.notStarted, base: 0, running: false, anchorMs: null);
    }
    final (phase, base, running) = markers[latest.type]!;
    return (
      phase: phase,
      base: base,
      running: running,
      anchorMs: running ? latest.createdAt.millisecondsSinceEpoch : null,
    );
  }

  /// Übernimmt die abgeleitete Uhr in den State: Phase, laufende Zeit, Timer und
  /// Hintergrunduhr. Wird beim Öffnen und bei jeder Ereignis-Aktualisierung
  /// (auch per Realtime von anderen Trainern) aufgerufen.
  Future<void> _applyDerivedClock() async {
    final d = _deriveClock(_events);
    var phase = d.phase;
    var base = d.base;
    var running = d.running;
    var anchorMs = d.anchorMs;
    // Fallback: Status „beendet" ohne Abpfiff-Marke → Abpfiff-Ansicht.
    if (phase == _Phase.notStarted && _match?.status == MatchStatus.finished) {
      phase = _Phase.finished;
      base = _fullSeconds;
      running = false;
      anchorMs = null;
    }
    final elapsed = (running && anchorMs != null)
        ? base + ((DateTime.now().millisecondsSinceEpoch - anchorMs) ~/ 1000)
        : base;
    if (!mounted) return;
    setState(() {
      _phase = phase;
      _baseElapsed = base;
      _anchorMs = anchorMs;
      _running = running;
      _elapsedSeconds = elapsed < 0 ? 0 : elapsed;
    });
    if (running) {
      _startTimer();
    } else {
      _timer?.cancel();
    }
    // Hintergrunduhr (Tray/Benachrichtigung) nachführen bzw. beenden.
    if (_isLiveClockPhase) {
      await _startClock();
    } else {
      await LiveClock.stop();
    }
  }

  /// Baut den aktuellen Uhr-Zustand für die Hintergrund-Uhr (Benachrichtigung).
  MatchClockData? _buildClock() {
    final m = _match;
    if (m == null) return null;
    final label = switch (_phase) {
      _Phase.firstHalf => '1. Halbzeit',
      _Phase.halftime => 'Halbzeit (Pause)',
      _Phase.secondHalf => '2. Halbzeit',
      _Phase.extraFirstHalf => '1. Verlängerung',
      _Phase.extraHalftime => 'Verlängerung (Pause)',
      _Phase.extraSecondHalf => '2. Verlängerung',
      _Phase.shootout => 'Elfmeterschießen',
      _Phase.finished => 'Abpfiff',
      _Phase.notStarted => 'Anpfiff',
    };
    // half nur für den 45/90-Alarm; in der Verlängerung/Schießen kein Alarm.
    final half = _phase == _Phase.firstHalf || _phase == _Phase.halftime
        ? 1
        : _phase == _Phase.secondHalf
            ? 2
            : 3;
    return MatchClockData(
      running: _running,
      baseElapsed: _elapsedSeconds,
      startedAtMs: DateTime.now().millisecondsSinceEpoch,
      half: half,
      phaseLabel: label,
      ownName: _ownTeam?.shortName ?? _ownTeam?.name ?? 'Heim',
      oppName: _opponentTeam?.name ?? m.opponentName,
      ownScore: m.ownScore,
      oppScore: m.opponentScore,
    );
  }

  /// Startet/aktualisiert die Hintergrund-Uhr (Android-Dienst / Windows-Tray).
  Future<void> _startClock() async {
    final d = _buildClock();
    if (d != null) await LiveClock.start(d);
  }

  Future<void> _updateClock() async {
    final d = _buildClock();
    if (d != null) await LiveClock.update(d);
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
    final ownPlayersRaw = await state.playersOf(match.ownTeamId);
    // Abweichende Rückennummern für dieses Spiel anwenden (für Picker/Ticker).
    final matchNumbers = await state.matchNumbers(widget.matchId);
    final ownPlayers = matchNumbers.isEmpty
        ? ownPlayersRaw
        : ownPlayersRaw.map((p) {
            final n = matchNumbers[p.id];
            return n == null ? p : p.copyWith(number: n);
          }).toList();
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
      // Zugesagte UND „unter Vorbehalt" nominierte Spieler sind einsetzbar.
      _nominatedIds = {
        for (final e in noms.entries)
          if (e.value == NominationStatus.zugesagt ||
              e.value == NominationStatus.unterVorbehalt)
            e.key,
      };
      _starterIds = starterIds;
      _events = events;
      _loading = false;
    });

    // Spielphase + laufende Uhr aus den (synchronisierten) Phasen-Marken
    // ableiten – dadurch ist die Zeit auf allen Geräten gleich und nach
    // Neustart/Rückkehr korrekt, ohne lokalen Zwischenspeicher.
    await _applyDerivedClock();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      // Zeit aus dem gemeinsamen Anker neu berechnen (statt nur +1), damit sie
      // auf allen Geräten gleich bleibt – bei fehlendem Anker hilfsweise +1.
      setState(() {
        final a = _anchorMs;
        _elapsedSeconds = a != null
            ? _baseElapsed +
                ((DateTime.now().millisecondsSinceEpoch - a) ~/ 1000)
            : _elapsedSeconds + 1;
      });
      // Auf Desktop die Hintergrund-Uhr (Tray-Tooltip + Halbzeit/Abpfiff-
      // Alarm) sekündlich nachführen; auf Android erledigt das der Dienst.
      if (!Platform.isAndroid) _updateClock();
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
    // Phase + Uhr aus den (ggf. per Realtime aktualisierten) Marken neu
    // ableiten: ein zuschauender Trainer folgt dadurch live, sobald eine Marke
    // ankommt. Hält zugleich Torstand/Phase in der Hintergrunduhr aktuell.
    await _applyDerivedClock();
  }

  /// Phasen mit laufender/pausierter Spieluhr (ohne Elfmeterschießen).
  bool get _isLiveClockPhase =>
      _phase == _Phase.firstHalf ||
      _phase == _Phase.halftime ||
      _phase == _Phase.secondHalf ||
      _phase == _Phase.extraFirstHalf ||
      _phase == _Phase.extraHalftime ||
      _phase == _Phase.extraSecondHalf;

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
    await _logPhase(MatchEventType.kickoff, 1, 0);
    await _refreshEvents();
  }

  /// Halbzeitpfiff: Uhr hält, 1. HZ zu Ende.
  Future<void> _halftime() async {
    final (min, extra) = _footMinute;
    setState(() {
      _phase = _Phase.halftime;
      _running = false;
    });
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
    await _logPhase(MatchEventType.secondHalfStart, 46, 0);
    await _refreshEvents();
  }

  /// Abpfiff: Spielende.
  Future<void> _finish() async {
    final state = context.read<AppState>();
    final (min, extra) = _footMinute;
    setState(() {
      _phase = _Phase.finished;
      _running = false;
    });
    await LiveClock.stop();
    await state.setMatchStatus(widget.matchId, MatchStatus.finished);
    await _logPhase(MatchEventType.fulltime, min, extra);
    await _refreshEvents();
    // Kein automatischer Bewerten-Dialog nach dem Abpfiff – das Bewerten
    // ist jederzeit über das 3-Punkte-Menü („Spieler bewerten") erreichbar.
  }

  /// Verlängerung starten (ab 90:00). Auch nach dem Abpfiff möglich.
  Future<void> _startExtra() async {
    await context
        .read<AppState>()
        .setMatchStatus(widget.matchId, MatchStatus.live);
    setState(() {
      _phase = _Phase.extraFirstHalf;
      _elapsedSeconds = _fullSeconds;
      _running = true;
    });
    final (min, extra) = _footMinute;
    await _logPhase(MatchEventType.extraFirstStart, min, extra);
    await _refreshEvents();
  }

  /// Halbzeit der Verlängerung (bei 105:00).
  Future<void> _extraHalftime() async {
    final (min, extra) = _footMinute;
    setState(() {
      _phase = _Phase.extraHalftime;
      _running = false;
    });
    await _logPhase(MatchEventType.extraHalftimeMark, min, extra);
    await _refreshEvents();
  }

  /// Anpfiff 2. Verlängerung (ab 105:00).
  Future<void> _startExtraSecond() async {
    setState(() {
      _phase = _Phase.extraSecondHalf;
      _elapsedSeconds = _extraFirstEnd;
      _running = true;
    });
    final (min, extra) = _footMinute;
    await _logPhase(MatchEventType.extraSecondStart, min, extra);
    await _refreshEvents();
  }

  /// Ins Elfmeterschießen wechseln.
  Future<void> _startShootout() async {
    final (min, extra) = _footMinute;
    setState(() {
      _phase = _Phase.shootout;
      _running = false;
    });
    await _logPhase(MatchEventType.shootoutStart, min, extra);
    await _refreshEvents();
  }

  /// Ein Schuss im Elfmeterschießen (Tor oder kein Tor), optional mit Schütze.
  Future<void> _addShootoutShot(
      {required bool ownSide, required bool scored}) async {
    final state = context.read<AppState>();
    // Platzverwiesene dürfen nicht zum Elfmeterschießen antreten.
    final players = ownSide
        ? _playersFor(true).where((p) => !_sentOffIds.contains(p.id)).toList()
        : _opponentPlayers;
    String? playerId;
    if (players.isNotEmpty) {
      final res = await showPlayerPickSheet(context, players);
      if (res == null) return; // abgebrochen
      if (res != _kPickNone) playerId = res;
    }
    if (!mounted) return;
    await state.addEvent(
      matchId: widget.matchId,
      teamId: _teamIdFor(ownSide),
      minute: _currentMinute,
      minuteExtra: _currentExtra,
      type: scored ? MatchEventType.soGoal : MatchEventType.soMiss,
      playerId: playerId,
    );
    await _refreshEvents();
  }

  /// Verwandelte Elfmeter im Schießen je Team.
  int _shootoutScore(bool ownSide) {
    final ownId = _match?.ownTeamId;
    return _events.where((e) {
      if (e.type != MatchEventType.soGoal) return false;
      final isOwn = e.teamId == ownId;
      return ownSide ? isOwn : !isOwn;
    }).length;
  }

  /// Erfassungs-Panel für das Elfmeterschießen.
  Widget _shootoutPanel(BuildContext context, GameMatch match) {
    final own = _shootoutScore(true);
    final opp = _shootoutScore(false);
    final ownName = _ownTeam?.shortName ?? _ownTeam?.name ?? 'Heim';
    final oppName = _opponentTeam?.name ?? match.opponentName;

    Widget teamCard(String name, bool ownSide, Color color) => Card(
          margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    style:
                        TextStyle(fontWeight: FontWeight.bold, color: color)),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(backgroundColor: color),
                      onPressed: () =>
                          _addShootoutShot(ownSide: ownSide, scored: true),
                      icon: const Text('⚽'),
                      label: const Text('Tor'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () =>
                          _addShootoutShot(ownSide: ownSide, scored: false),
                      icon: const Icon(Icons.close, size: 18),
                      label: const Text('Kein Tor'),
                    ),
                  ),
                ]),
              ],
            ),
          ),
        );

    return Column(
      children: [
        Card(
          margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          color: Theme.of(context).colorScheme.primaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              children: [
                const Text('Elfmeterschießen',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text('$ownName  $own : $opp  $oppName',
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
        ),
        teamCard(ownName, true, Theme.of(context).colorScheme.primary),
        teamCard(oppName, false, const Color(0xFFB26A00)),
      ],
    );
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

    // Darf dieser Nutzer mitschreiben? Zuschauer (und „nur zuschauen"-Modus)
    // sehen nur den Ticker.
    final canEdit = _state.canLiveEdit;
    final editing = canEdit && !_watchMode;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Live-Spiel'),
        actions: [
          if (canEdit)
            IconButton(
              tooltip: _watchMode
                  ? 'Nur zuschauen – tippen zum Mitschreiben'
                  : 'Mitschreiben – tippen für nur zuschauen',
              icon: Icon(_watchMode ? Icons.visibility : Icons.edit_note),
              onPressed: () => setState(() => _watchMode = !_watchMode),
            ),
          IconButton(
            tooltip: 'Bericht teilen (WhatsApp)',
            icon: const Icon(Icons.share),
            onPressed: _shareReport,
          ),
          if (editing)
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'reset') _resetMatch();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                    value: 'reset', child: Text('Spiel zurücksetzen')),
              ],
            ),
        ],
      ),
      body: Column(
        children: [
          if (!canEdit)
            Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.secondaryContainer,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.visibility, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                        'Du schaust zu – du siehst nur den Ticker.',
                        style: Theme.of(context).textTheme.bodySmall),
                  ),
                ],
              ),
            ),
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
            shootoutOwn: _shootoutScore(true),
            shootoutOpp: _shootoutScore(false),
            showShootout: _phase == _Phase.shootout ||
                _events.any((e) =>
                    e.type == MatchEventType.soGoal ||
                    e.type == MatchEventType.soMiss),
          ),
          if (editing)
            _Controls(
              phase: _phase,
              onKickoff: _kickoff,
              onHalftime: _halftime,
              onSecondHalf: _startSecondHalf,
              onFinish: _finish,
              onExtra: _startExtra,
              onExtraHalftime: _extraHalftime,
              onExtraSecond: _startExtraSecond,
              onShootout: _startShootout,
            ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 16),
              children: [
                if (editing && _phase == _Phase.shootout)
                  _shootoutPanel(context, match),
                if (_phase != _Phase.shootout &&
                    _events.any((e) =>
                        e.type == MatchEventType.soGoal ||
                        e.type == MatchEventType.soMiss))
                  Card(
                    margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    color: Theme.of(context).colorScheme.secondaryContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        'Elfmeterschießen: '
                        '${_ownTeam?.shortName ?? _ownTeam?.name ?? 'Heim'} '
                        '${_shootoutScore(true)} : ${_shootoutScore(false)} '
                        '${_opponentTeam?.name ?? match.opponentName}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                if (editing && _phase != _Phase.shootout) ...[
                  _TeamActionBar(
                    label: _ownTeam?.name ?? 'Eigenes Team',
                    color: Theme.of(context).colorScheme.primary,
                    isOwn: true,
                    // Erst nach Anpfiff (während einer Halbzeit) erfassbar.
                    enabled: _actionsEnabled,
                    onGoal: () => _addGoal(ownSide: true),
                    onCard: () => _addCard(ownSide: true),
                    onSub: () => _addSub(ownSide: true),
                    onEvent: () => _addOtherEvent(ownSide: true),
                  ),
                  _TeamActionBar(
                    label: match.opponentName,
                    color: const Color(0xFFB26A00), // Gegner klar abgesetzt
                    isOwn: false,
                    enabled: _actionsEnabled,
                    onGoal: () => _addGoal(ownSide: false),
                    // Gegner: nur Tore für den Spielstand – keine Karten/Wechsel.
                    onCard: null,
                    onSub: null,
                    onEvent: () => _addOtherEvent(ownSide: false),
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _actionsEnabled ? _addComment : null,
                        icon: const Icon(Icons.chat_bubble_outline, size: 18),
                        label: const Text('Kommentar'),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                _EventLog(
                  events: _events,
                  ownTeamId: match.ownTeamId,
                  resolveName: _playerName,
                  resolvePlayer: _playerById,
                  onDelete: editing ? _deleteEvent : null,
                  onEdit: editing ? _editEvent : null,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _teamIdFor(bool ownSide) => ownSide
      ? _match!.ownTeamId
      // Gegner-Ereignis nie fälschlich dem eigenen Team zuordnen (sonst zählt
      // ein Gegner-Tor als eigenes): bevorzugt die Gegner-Team-ID des Spiels.
      : (_opponentTeam?.id ?? _match!.opponentTeamId ?? _match!.ownTeamId);

  List<Player> _playersFor(bool ownSide) {
    if (!ownSide) return _opponentPlayers;
    // Eigenes Team: ausschließlich nominierte (zugesagte) Spieler.
    return _ownPlayers.where((p) => _nominatedIds.contains(p.id)).toList();
  }

  /// Tor/Karte/Wechsel nur während einer laufenden Halbzeit (nach Anpfiff) –
  /// auch in der Verlängerung.
  bool get _actionsEnabled =>
      _phase == _Phase.firstHalf ||
      _phase == _Phase.secondHalf ||
      _phase == _Phase.extraFirstHalf ||
      _phase == _Phase.extraSecondHalf;

  /// Eigene Spieler, die aktuell auf dem Feld stehen (für Tor/Karte).
  List<Player> _onFieldPlayers(bool ownSide) {
    if (!ownSide) return _opponentPlayers;
    final ids = _onFieldIds;
    return _ownPlayers.where((p) => ids.contains(p.id)).toList();
  }

  /// Spieler, die in diesem Spiel Rot oder Gelb-Rot gesehen haben – vom Platz
  /// gestellt, dürfen nicht mehr mitspielen (kein Tor/Karte, nicht ein-/aus-
  /// wechselbar).
  Set<String> get _sentOffIds => {
        for (final e in _events)
          if ((e.type == MatchEventType.redCard ||
                  e.type == MatchEventType.secondYellow) &&
              e.playerId != null)
            e.playerId!,
      };

  /// Wer aktuell auf dem Feld steht: Startelf, fortgeschrieben durch alle
  /// bisherigen Wechsel (ein Spieler kann hin- und zurückgewechselt werden).
  /// Platzverwiesene Spieler (Rot/Gelb-Rot) sind raus.
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
    onField.removeAll(_sentOffIds);
    return onField;
  }

  String _playerName(String? playerId) {
    if (playerId == null) return 'Unbekannt';
    final all = [..._ownPlayers, ..._opponentPlayers];
    final p = all.where((e) => e.id == playerId).firstOrNull;
    return p?.displayName ?? 'Spieler';
  }

  Player? _playerById(String? playerId) {
    if (playerId == null) return null;
    final all = [..._ownPlayers, ..._opponentPlayers];
    return all.where((e) => e.id == playerId).firstOrNull;
  }

  // ------------------------------------------------- Ereignis-Erfassung
  /// Optionaler Kommentar beim Erfassen einer Aktion.
  /// proceed=false → Aktion abbrechen; note=null → ohne Kommentar speichern.
  Future<({bool proceed, String? note})> _askNote() async {
    final ctrl = TextEditingController();
    final res = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Kommentar (optional)'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          minLines: 1,
          maxLines: 3,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
              hintText: 'z.B. Traumtor aus 20 m', border: OutlineInputBorder()),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, '\u0000cancel'),
              child: const Text('Abbrechen')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, ''),
              child: const Text('Ohne')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Speichern')),
        ],
      ),
    );
    if (res == null || res == '\u0000cancel') {
      return (proceed: false, note: null);
    }
    return (proceed: true, note: res.isEmpty ? null : res);
  }

  Future<void> _addGoal({required bool ownSide}) async {
    final state = context.read<AppState>();

    // Gegner-Tor: einfach ein Tor (nur für den Spielstand) – ohne Torschütze/Vorlage.
    if (!ownSide) {
      final n = await _askNote();
      if (!n.proceed || !mounted) return;
      await state.addEvent(
        matchId: widget.matchId,
        teamId: _teamIdFor(false),
        minute: _currentMinute,
        minuteExtra: _currentExtra,
        type: MatchEventType.goal,
        note: n.note,
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

    if (!mounted) return;
    final n = await _askNote();
    if (!n.proceed || !mounted) return;
    await state.addEvent(
      matchId: widget.matchId,
      teamId: _teamIdFor(ownSide),
      minute: _currentMinute,
      minuteExtra: _currentExtra,
      type: MatchEventType.goal,
      playerId: scorer == _pickUnknown ? null : scorer,
      assistPlayerId: assistId,
      note: n.note,
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
    final pid = player == _pickUnknown ? null : player;
    // Hat der Spieler in diesem Spiel schon Gelb? Dann kein zweites Gelb.
    final hasYellow = pid != null &&
        _events.any((e) =>
            e.type == MatchEventType.yellowCard && e.playerId == pid);
    final type = await showModalBottomSheet<MatchEventType>(
      context: context,
      builder: (_) => _CardTypeSheet(hideYellow: hasYellow),
    );
    if (type == null || !mounted) return;
    final n = await _askNote();
    if (!n.proceed || !mounted) return;
    await state.addEvent(
      matchId: widget.matchId,
      teamId: _teamIdFor(ownSide),
      minute: _currentMinute,
      minuteExtra: _currentExtra,
      type: type,
      playerId: pid,
      note: n.note,
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
    // Raus = aktuell auf dem Feld, Rein = auf der Bank (ohne Platzverwiesene).
    final onIds = _onFieldIds;
    final sentOff = _sentOffIds;
    final onField = players.where((p) => onIds.contains(p.id)).toList();
    final bench = players
        .where((p) => !onIds.contains(p.id) && !sentOff.contains(p.id))
        .toList();
    if (onField.isEmpty) {
      _snack('Niemand auf dem Feld – bitte zuerst aufstellen.');
      return;
    }
    if (bench.isEmpty) {
      _snack('Keine Spieler auf der Bank für einen Wechsel.');
      return;
    }
    // Doppel-/Mehrfachwechsel: mehrere Paare (Raus → Rein) in einem Fenster
    // sammeln und auf einmal bestätigen. Jedes Paar wird als eigenes
    // Wechsel-Ereignis (zur aktuellen Minute) gespeichert.
    final pairs = await showModalBottomSheet<List<({String off, String on})>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _SubstitutionSheet(onField: onField, bench: bench),
    );
    if (pairs == null || pairs.isEmpty || !mounted) return;
    final n = await _askNote();
    if (!n.proceed || !mounted) return;
    for (final pair in pairs) {
      await state.addEvent(
        matchId: widget.matchId,
        teamId: _teamIdFor(ownSide),
        minute: _currentMinute,
        minuteExtra: _currentExtra,
        type: MatchEventType.substitution,
        playerId: pair.on, // kommt
        assistPlayerId: pair.off, // geht
        note: n.note,
      );
    }
    await _refreshEvents();
  }

  /// Weitere Ereignisse: Typ wählen, optional Spieler + Notiz.
  Future<void> _addOtherEvent({required bool ownSide}) async {
    const types = [
      MatchEventType.corner,
      MatchEventType.freeKick,
      MatchEventType.penalty,
      MatchEventType.foul,
      MatchEventType.bigChance,
      MatchEventType.meckern,
    ];
    final type = await showModalBottomSheet<MatchEventType>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Ereignis',
                    style:
                        TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ),
            ),
            const Divider(height: 1),
            for (final t in types)
              ListTile(
                leading: Text(t.symbol, style: const TextStyle(fontSize: 20)),
                title: Text(t.label),
                onTap: () => Navigator.pop(context, t),
              ),
          ],
        ),
      ),
    );
    if (type == null || !mounted) return;
    // Elfmeter: erst den Ausgang abfragen (Tor / verschossen / gehalten).
    var resolved = type;
    if (type == MatchEventType.penalty) {
      final outcome = await _askPenaltyOutcome();
      if (outcome == null || !mounted) return;
      resolved = outcome;
    }
    final detail = await _eventDetail(resolved, _onFieldPlayers(ownSide));
    if (detail == null || !mounted) return;
    await context.read<AppState>().addEvent(
          matchId: widget.matchId,
          teamId: _teamIdFor(ownSide),
          minute: _currentMinute,
          minuteExtra: _currentExtra,
          type: resolved,
          playerId: detail.playerId,
          note: detail.note,
        );
    await _refreshEvents();
  }

  /// Abfrage des Elfmeter-Ausgangs.
  Future<MatchEventType?> _askPenaltyOutcome() {
    return showModalBottomSheet<MatchEventType>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Elfmeter – Ausgang',
                    style:
                        TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Text('⚽', style: TextStyle(fontSize: 20)),
              title: const Text('Tor (verwandelt)'),
              onTap: () => Navigator.pop(context, MatchEventType.penalty),
            ),
            ListTile(
              leading: const Text('❌', style: TextStyle(fontSize: 20)),
              title: const Text('Verschossen'),
              onTap: () => Navigator.pop(context, MatchEventType.penaltyMissed),
            ),
            ListTile(
              leading: const Text('🧤', style: TextStyle(fontSize: 20)),
              title: const Text('Gehalten'),
              onTap: () => Navigator.pop(context, MatchEventType.penaltySaved),
            ),
          ],
        ),
      ),
    );
  }

  /// Vollbild-Seite: optionaler Spieler (mit Foto) + optionale Notiz.
  Future<({String? playerId, String? note, List<String> mentions})?>
      _eventDetail(MatchEventType type, List<Player> players) {
    return Navigator.of(context)
        .push<({String? playerId, String? note, List<String> mentions})>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _EventDetailPage(type: type, players: players),
      ),
    );
  }

  /// Neutraler Freitext-Kommentar (ebenfalls als Vollbild-Seite). Erwähnte
  /// Spieler werden verknüpft und erscheinen im jeweiligen Profil.
  Future<void> _addComment() async {
    final detail =
        await _eventDetail(MatchEventType.comment, _playersFor(true));
    if (detail == null ||
        detail.note == null ||
        detail.note!.isEmpty ||
        !mounted) {
      return;
    }
    await context.read<AppState>().addEvent(
          matchId: widget.matchId,
          teamId: _teamIdFor(true),
          minute: _currentMinute,
          minuteExtra: _currentExtra,
          type: MatchEventType.comment,
          note: detail.note,
          mentions: detail.mentions,
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
              leading: const Icon(Icons.edit_outlined),
              title: Text(e.type == MatchEventType.comment
                  ? 'Text ändern'
                  : 'Text/Spieler ändern'),
              onTap: () => Navigator.pop(context, 'edit'),
            ),
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
    } else if (action == 'edit') {
      await _editEventDetail(e);
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

  /// Ereignis-Text (und bei Nicht-Kommentaren den Spieler) nachträglich ändern.
  Future<void> _editEventDetail(MatchEvent e) async {
    final isComment = e.type == MatchEventType.comment;
    final own = e.teamId == _match?.ownTeamId;
    final players = isComment ? _playersFor(true) : _onFieldPlayers(own);
    final detail = await Navigator.of(context)
        .push<({String? playerId, String? note, List<String> mentions})>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _EventDetailPage(
          type: e.type,
          players: players,
          initialPlayerId: e.playerId,
          initialNote: e.note,
        ),
      ),
    );
    if (detail == null || !mounted) return;
    // Direkt neu bauen (copyWith kann playerId/note nicht auf null setzen).
    final updated = MatchEvent(
      id: e.id,
      matchId: e.matchId,
      teamId: e.teamId,
      minute: e.minute,
      minuteExtra: e.minuteExtra,
      type: e.type,
      playerId: isComment ? e.playerId : detail.playerId,
      assistPlayerId: e.assistPlayerId,
      note: detail.note,
      createdAt: e.createdAt,
    );
    await context.read<AppState>().updateEvent(updated);
    await _refreshEvents();
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
      // Die Uhr leitet sich aus den Marken-Ereignissen ab; durch das Löschen
      // des Verlaufs (oben) ergibt _load()/_applyDerivedClock unten „nicht
      // gestartet". Hier nur die Hintergrunduhr beenden.
      await LiveClock.stop();
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
    required this.shootoutOwn,
    required this.shootoutOpp,
    required this.showShootout,
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
  final int shootoutOwn;
  final int shootoutOpp;
  final bool showShootout;

  String get _minuteLabel {
    switch (phase) {
      case _Phase.notStarted:
        return 'Anpfiff ausstehend';
      case _Phase.halftime:
        return 'Halbzeit';
      case _Phase.extraHalftime:
        return 'Halbzeit Verl.';
      case _Phase.shootout:
        return 'Elfmeterschießen';
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
          // Elfmeterschießen oben mitzählen.
          if (showShootout) ...[
            const SizedBox(height: 4),
            Text('Elfmeterschießen  $shootoutOwn : $shootoutOpp',
                style: TextStyle(
                    color: scheme.onPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700)),
          ],
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
    required this.onKickoff,
    required this.onHalftime,
    required this.onSecondHalf,
    required this.onFinish,
    required this.onExtra,
    required this.onExtraHalftime,
    required this.onExtraSecond,
    required this.onShootout,
  });

  final _Phase phase;
  final VoidCallback onKickoff;
  final VoidCallback onHalftime;
  final VoidCallback onSecondHalf;
  final VoidCallback onFinish;
  final VoidCallback onExtra;
  final VoidCallback onExtraHalftime;
  final VoidCallback onExtraSecond;
  final VoidCallback onShootout;

  @override
  Widget build(BuildContext context) {
    Widget full(Widget button) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: SizedBox(width: double.infinity, child: button),
        );
    Widget two(Widget a, Widget b) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(children: [
            Expanded(child: a),
            const SizedBox(width: 8),
            Expanded(child: b),
          ]),
        );

    final finishBtn = FilledButton.icon(
      style: FilledButton.styleFrom(backgroundColor: Colors.red),
      onPressed: onFinish,
      icon: const Icon(Icons.stop),
      label: const Text('Abpfiff'),
    );

    switch (phase) {
      case _Phase.notStarted:
        return full(FilledButton.icon(
          onPressed: onKickoff,
          icon: const Icon(Icons.play_arrow),
          label: const Text('Anpfiff'),
        ));
      case _Phase.firstHalf:
        return full(FilledButton.icon(
          onPressed: onHalftime,
          icon: const Icon(Icons.timer),
          label: const Text('Halbzeit'),
        ));
      case _Phase.halftime:
        return full(FilledButton.icon(
          onPressed: onSecondHalf,
          icon: const Icon(Icons.play_arrow),
          label: const Text('Anpfiff 2. Halbzeit'),
        ));
      case _Phase.secondHalf:
        return two(
          finishBtn,
          OutlinedButton.icon(
            onPressed: onExtra,
            icon: const Icon(Icons.more_time),
            label: const Text('Verlängerung'),
          ),
        );
      case _Phase.finished:
        return two(
          OutlinedButton.icon(
            onPressed: onExtra,
            icon: const Icon(Icons.more_time),
            label: const Text('Verlängerung'),
          ),
          OutlinedButton.icon(
            onPressed: onKickoff,
            icon: const Icon(Icons.replay),
            label: const Text('Neues Spiel'),
          ),
        );
      case _Phase.extraFirstHalf:
        return full(FilledButton.icon(
          onPressed: onExtraHalftime,
          icon: const Icon(Icons.timer),
          label: const Text('Halbzeit Verlängerung'),
        ));
      case _Phase.extraHalftime:
        return full(FilledButton.icon(
          onPressed: onExtraSecond,
          icon: const Icon(Icons.play_arrow),
          label: const Text('Anpfiff 2. Verlängerung'),
        ));
      case _Phase.extraSecondHalf:
        return two(
          finishBtn,
          OutlinedButton.icon(
            onPressed: onShootout,
            icon: const Icon(Icons.sports_soccer),
            label: const Text('Elfmeterschießen'),
          ),
        );
      case _Phase.shootout:
        return full(FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: Colors.red),
          onPressed: onFinish,
          icon: const Icon(Icons.emoji_events),
          label: const Text('Spiel beenden'),
        ));
    }
  }
}

class _TeamActionBar extends StatelessWidget {
  const _TeamActionBar({
    required this.label,
    required this.color,
    required this.onGoal,
    this.onCard,
    this.onSub,
    this.onEvent,
    this.enabled = true,
    this.isOwn = true,
  });

  final String label;
  final Color color;
  final VoidCallback onGoal;
  final VoidCallback? onCard;
  final VoidCallback? onSub;

  /// Weitere Ereignisse (Ecke/Freistoß/Elfmeter/Foul/Großchance).
  final VoidCallback? onEvent;

  /// Nur nach Anpfiff aktiv.
  final bool enabled;

  /// Eigenes Team (true) vs. Gegner (false) – für die Unterscheidung.
  final bool isOwn;

  // Icon über Label – Text bleibt auch auf schmalen Handys lesbar.
  static final _actionStyle = ButtonStyle(
    padding: WidgetStateProperty.all(
        const EdgeInsets.symmetric(horizontal: 4, vertical: 8)),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );

  Widget _actionChild(Widget icon, String text) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          icon,
          const SizedBox(height: 2),
          Text(text,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.visible,
              style:
                  const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final torStyle = FilledButton.styleFrom(
      backgroundColor: color,
      foregroundColor: Colors.white,
    ).merge(_actionStyle);
    final outStyle = OutlinedButton.styleFrom(
      foregroundColor: color,
      side: BorderSide(color: color.withValues(alpha: 0.5)),
    ).merge(_actionStyle);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          border: Border(left: BorderSide(color: color, width: 6)),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(isOwn ? Icons.home : Icons.flag_outlined,
                    size: 16, color: color),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontWeight: FontWeight.bold, color: color)),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(isOwn ? 'MEIN TEAM' : 'GEGNER',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Immer drei gleich breite Slots – auch wenn Karte/Wechsel fehlen.
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: enabled ? onGoal : null,
                    style: torStyle,
                    child: _actionChild(
                        const Text('⚽', style: TextStyle(fontSize: 18)), 'Tor'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: onCard == null
                      ? const SizedBox.shrink()
                      : OutlinedButton(
                          onPressed: enabled ? onCard : null,
                          style: outStyle,
                          child: _actionChild(
                              const Icon(Icons.style, size: 20), 'Karte'),
                        ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: onSub == null
                      ? const SizedBox.shrink()
                      : OutlinedButton(
                          onPressed: enabled ? onSub : null,
                          style: outStyle,
                          child: _actionChild(
                              const Icon(Icons.swap_horiz, size: 20), 'Wechsel'),
                        ),
                ),
              ],
            ),
            if (onEvent != null) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: enabled ? onEvent : null,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: color,
                    side: BorderSide(color: color.withValues(alpha: 0.5)),
                  ),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Ereignis (Ecke, Freistoß, Elfmeter …)'),
                ),
              ),
            ],
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
    required this.resolvePlayer,
    required this.onDelete,
    required this.onEdit,
  });

  final List<MatchEvent> events;
  final String ownTeamId;
  final String Function(String?) resolveName;
  final Player? Function(String?) resolvePlayer;
  final Future<void> Function(MatchEvent)? onDelete;
  final void Function(MatchEvent)? onEdit;

  /// Zuschauer-Modus: Ticker nur lesen (kein Löschen/Bearbeiten).
  bool get _readOnly => onEdit == null;

  String _minuteLabel(MatchEvent e) =>
      e.minuteExtra > 0 ? '${e.minute}+${e.minuteExtra}' : "${e.minute}'";

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
          // Zeigt der Avatar links ein Foto (Spieler/Wechsel), gehört das
          // Typ-Symbol wieder in den Titel. Nur ohne Spieler (Symbol-Kreis
          // links) würde es sonst doppelt erscheinen.
          final leadingIsPhoto = e.type == MatchEventType.substitution ||
              resolvePlayer(e.playerId) != null;
          final content = Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Minute oben links (wie im FuPa-Ticker).
                _MinuteBadge(label: _minuteLabel(e), own: own),
                const SizedBox(width: 10),
                _eventAvatar(context, e, own),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          leadingIsPhoto
                              ? '${e.type.symbol} ${_describe(e)}'
                              : _describe(e),
                          style: const TextStyle(
                              fontWeight: FontWeight.w500, height: 1.2)),
                      ..._subtitleLine(context, e, own),
                    ],
                  ),
                ),
                if (!_readOnly)
                  IconButton(
                    tooltip: 'Korrigieren',
                    icon: const Icon(Icons.more_vert),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => onEdit!(e),
                  ),
              ],
            ),
          );
          if (_readOnly) return content;
          return Dismissible(
            key: ValueKey(e.id),
            direction: DismissDirection.endToStart,
            background: Container(
              color: Colors.red,
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 20),
              child: const Icon(Icons.delete, color: Colors.white),
            ),
            onDismissed: (_) => onDelete!(e),
            child: InkWell(
              onTap: () => onEdit!(e),
              child: content,
            ),
          );
        }),
      ],
    );
  }

  Widget _phaseRow(BuildContext context, MatchEvent e) {
    final score = e.note ?? '';
    final t = e.createdAt.toLocal();
    final time =
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')} Uhr';
    final label = [
      e.type.label,
      time,
      if (score.isNotEmpty) score,
    ].join('  ·  ');
    return InkWell(
      onTap: _readOnly ? null : () => onEdit!(e),
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
      case MatchEventType.penalty:
        return e.playerId == null
            ? 'Elfmeter verwandelt'
            : 'Elfmeter verwandelt – ${resolveName(e.playerId)}';
      case MatchEventType.penaltyMissed:
        return e.playerId == null
            ? 'Elfmeter verschossen'
            : 'Elfmeter verschossen – ${resolveName(e.playerId)}';
      case MatchEventType.penaltySaved:
        return e.playerId == null
            ? 'Elfmeter gehalten'
            : 'Elfmeter gehalten – ${resolveName(e.playerId)}';
      case MatchEventType.corner:
      case MatchEventType.freeKick:
      case MatchEventType.foul:
      case MatchEventType.bigChance:
      case MatchEventType.meckern:
        return e.playerId == null
            ? e.type.label
            : '${e.type.label} – ${resolveName(e.playerId)}';
      case MatchEventType.comment:
        return (e.note == null || e.note!.isEmpty) ? 'Kommentar' : e.note!;
      case MatchEventType.soGoal:
        return e.playerId == null
            ? 'Elfmeterschießen: Tor'
            : 'Elfmeterschießen: Tor – ${resolveName(e.playerId)}';
      case MatchEventType.soMiss:
        return e.playerId == null
            ? 'Elfmeterschießen: kein Tor'
            : 'Elfmeterschießen: kein Tor – ${resolveName(e.playerId)}';
      case MatchEventType.kickoff:
      case MatchEventType.halftime:
      case MatchEventType.secondHalfStart:
      case MatchEventType.fulltime:
      case MatchEventType.extraFirstStart:
      case MatchEventType.extraHalftimeMark:
      case MatchEventType.extraSecondStart:
      case MatchEventType.shootoutStart:
        return e.type.label;
    }
  }

  /// Untertitel im Ticker: Team + Notiz; beim Kommentar steht der Text schon
  /// im Titel, daher kein Untertitel.
  List<Widget> _subtitleLine(BuildContext context, MatchEvent e, bool own) {
    if (e.type == MatchEventType.comment) return const [];
    final parts = [
      own ? 'Eigenes Team' : 'Gegner',
      if (e.note != null && e.note!.isNotEmpty) e.note!,
    ];
    return [
      Text(parts.join('  ·  '),
          style: TextStyle(
              fontSize: 12, color: Theme.of(context).colorScheme.outline)),
    ];
  }

  /// Spielerfoto(s) für die Ticker-Zeile. Beim Wechsel beide Spieler mit
  /// Pfeil (rein/raus) wie im FuPa-Ticker; sonst das Foto des Spielers.
  Widget _eventAvatar(BuildContext context, MatchEvent e, bool own) {
    const r = 18.0;
    if (e.type == MatchEventType.substitution) {
      final inP = resolvePlayer(e.playerId);
      final outP = resolvePlayer(e.assistPlayerId);
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _avatarWithArrow(outP, Icons.arrow_downward, Colors.red),
          const SizedBox(width: 3),
          _avatarWithArrow(inP, Icons.arrow_upward, Colors.green),
        ],
      );
    }
    final p = resolvePlayer(e.playerId);
    if (p != null) return PlayerAvatar(player: p, radius: r);
    // Kein zugeordneter Spieler (Gegner-Tor, Ecke ohne Spieler, Kommentar …).
    return CircleAvatar(
      radius: r,
      backgroundColor: own
          ? Theme.of(context).colorScheme.primaryContainer
          : Theme.of(context).colorScheme.tertiaryContainer,
      child: Text(e.type.symbol, style: const TextStyle(fontSize: 16)),
    );
  }

  Widget _avatarWithArrow(Player? p, IconData arrow, Color color) {
    final avatar = p != null
        ? PlayerAvatar(player: p, radius: 14)
        : const CircleAvatar(radius: 14, child: Icon(Icons.person, size: 14));
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [avatar, Icon(arrow, size: 13, color: color)],
    );
  }
}

/// Minuten-Badge für die Ticker-Zeile (oben links).
class _MinuteBadge extends StatelessWidget {
  const _MinuteBadge({required this.label, required this.own});

  final String label;
  final bool own;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 2),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: own ? scheme.primaryContainer : scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: own ? scheme.onPrimaryContainer : scheme.onTertiaryContainer,
        ),
      ),
    );
  }
}

/// Vollbild-Seite für ein dokumentiertes Ereignis (Ecke, Freistoß, Foul …)
/// oder einen Kommentar: optionale Notiz + optionale Spielerauswahl mit Fotos.
class _EventDetailPage extends StatefulWidget {
  const _EventDetailPage({
    required this.type,
    required this.players,
    this.initialPlayerId,
    this.initialNote,
  });

  final MatchEventType type;
  final List<Player> players;
  final String? initialPlayerId;
  final String? initialNote;

  @override
  State<_EventDetailPage> createState() => _EventDetailPageState();
}

class _EventDetailPageState extends State<_EventDetailPage> {
  String? _selPlayer;
  final List<String> _mentions = [];
  final _noteCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _selPlayer = widget.initialPlayerId;
    if (widget.initialNote != null) _noteCtrl.text = widget.initialNote!;
  }

  @override
  void dispose() {
    _noteCtrl.dispose();
    super.dispose();
  }

  void _save() {
    final note = _noteCtrl.text.trim();
    Navigator.pop(context, (
      playerId: _selPlayer,
      note: note.isEmpty ? null : note,
      mentions: List<String>.from(_mentions),
    ));
  }

  Future<void> _pickPlayer() async {
    final res = await showPlayerPickSheet(context, widget.players,
        selected: _selPlayer);
    if (res == null) return; // abgebrochen → unverändert
    setState(() => _selPlayer = res == _kPickNone ? null : res);
  }

  /// Spieler erwähnen: Namen an der Cursor-Position einfügen + verknüpfen.
  Future<void> _mentionPlayer() async {
    final res = await showPlayerPickSheet(context, widget.players);
    if (res == null || res == _kPickNone) return;
    final p = widget.players.where((x) => x.id == res).firstOrNull;
    if (p == null) return;
    final name = p.displayName;
    final text = _noteCtrl.text;
    var sel = _noteCtrl.selection;
    var start = sel.start;
    var end = sel.end;
    if (start < 0 || end < 0) {
      start = text.length;
      end = text.length;
    }
    final needSpaceBefore = start > 0 && text[start - 1] != ' ';
    final insert = '${needSpaceBefore ? ' ' : ''}$name ';
    final newText = text.replaceRange(start, end, insert);
    _noteCtrl.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + insert.length),
    );
    setState(() {
      if (!_mentions.contains(p.id)) _mentions.add(p.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final isComment = widget.type == MatchEventType.comment;
    final showPlayers = !isComment && widget.players.isNotEmpty;
    final sel = _selPlayer == null
        ? null
        : widget.players.where((p) => p.id == _selPlayer).firstOrNull;
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.type.symbol}  ${widget.type.label}'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.check, size: 18),
              label: Text(isComment ? 'Senden' : 'Speichern'),
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Spieler-Auswahl per Button (kompakt), Notiz bekommt den Platz.
            if (showPlayers) ...[
              Row(
                children: [
                  Text('Spieler:',
                      style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: sel == null
                          ? OutlinedButton.icon(
                              onPressed: _pickPlayer,
                              icon: const Icon(Icons.person_add_alt, size: 18),
                              label: const Text('Spieler wählen'),
                            )
                          : InputChip(
                              avatar: PlayerAvatar(player: sel, radius: 11),
                              label: Text(sel.displayName),
                              onPressed: _pickPlayer,
                              onDeleted: () => setState(() => _selPlayer = null),
                            ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            // Kommentar: Spieler erwähnen (Name an Cursor-Position einfügen).
            if (isComment && widget.players.isNotEmpty) ...[
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _mentions.isEmpty
                          ? 'Spieler erwähnen (optional)'
                          : '${_mentions.length} erwähnt',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: _mentionPlayer,
                    icon: const Icon(Icons.alternate_email, size: 18),
                    label: const Text('Erwähnen'),
                  ),
                ],
              ),
              const SizedBox(height: 10),
            ],
            // Notiz – nimmt den restlichen Platz ein.
            Expanded(
              child: TextField(
                controller: _noteCtrl,
                autofocus: isComment,
                expands: true,
                minLines: null,
                maxLines: null,
                textAlignVertical: TextAlignVertical.top,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: isComment ? 'Kommentar' : 'Notiz (optional)',
                  hintText:
                      isComment ? 'Was passiert gerade?' : 'Notiz zum Ereignis …',
                  border: const OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Sentinel für „— ohne —" im Spieler-Picker.
const String _kPickNone = '\u0000none';

/// Spieler-Einzelauswahl als Bottom-Sheet (wie beim Einwechseln): Foto + Name
/// + Nr./Position, antippen wählt aus. Mit Suchfeld und „— ohne —".
/// Gibt die Spieler-ID zurück, [_kPickNone] für „ohne", oder null bei Abbruch.
Future<String?> showPlayerPickSheet(BuildContext context, List<Player> players,
    {String? selected}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _EventPlayerSheet(players: players, selected: selected),
  );
}

class _EventPlayerSheet extends StatefulWidget {
  const _EventPlayerSheet({required this.players, this.selected});

  final List<Player> players;
  final String? selected;

  @override
  State<_EventPlayerSheet> createState() => _EventPlayerSheetState();
}

class _EventPlayerSheetState extends State<_EventPlayerSheet> {
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
    final scheme = Theme.of(context).colorScheme;
    final maxH = MediaQuery.of(context).size.height * 0.82;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text('Spieler wählen',
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
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
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 8),
                children: [
                  ListTile(
                    leading: const CircleAvatar(
                        radius: 20, child: Icon(Icons.block)),
                    title: const Text('— ohne —'),
                    trailing: widget.selected == null
                        ? Icon(Icons.check_circle, color: scheme.primary)
                        : null,
                    onTap: () => Navigator.pop(context, _kPickNone),
                  ),
                  for (final p in _filtered)
                    ListTile(
                      leading: PlayerAvatar(player: p),
                      title: Text(p.fullName),
                      subtitle: Text([
                        if (p.number != null) 'Nr. ${p.number}',
                        if (p.position != null) p.position!,
                      ].join('  ·  ')),
                      trailing: widget.selected == p.id
                          ? Icon(Icons.check_circle, color: scheme.primary)
                          : null,
                      onTap: () => Navigator.pop(context, p.id),
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

class _CardTypeSheet extends StatelessWidget {
  const _CardTypeSheet({this.hideYellow = false});

  /// Hat der Spieler bereits Gelb → kein zweites Gelb, nur Gelb-Rot/Rot.
  final bool hideYellow;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: const Text('Kartentyp'),
            subtitle: hideYellow
                ? const Text('Spieler hat bereits Gelb – nur Gelb-Rot/Rot')
                : null,
          ),
          if (!hideYellow)
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

/// Wechsel-Fenster für Doppel-/Mehrfachwechsel: Paare (Raus → Rein) sammeln
/// und am Ende gemeinsam bestätigen. Jedes Paar wird als eigener Wechsel
/// gespeichert. Gibt die Liste der Paare zurück (oder null bei Abbruch).
class _SubstitutionSheet extends StatefulWidget {
  const _SubstitutionSheet({required this.onField, required this.bench});

  final List<Player> onField;
  final List<Player> bench;

  @override
  State<_SubstitutionSheet> createState() => _SubstitutionSheetState();
}

class _SubstitutionSheetState extends State<_SubstitutionSheet> {
  final List<({String off, String on})> _pairs = [];
  String? _pendingOff; // Spieler, der raus geht und auf einen Rein wartet.

  Player _byId(String id) =>
      [...widget.onField, ...widget.bench].firstWhere((p) => p.id == id);

  void _onTap(String id, bool selectingIn) {
    setState(() {
      if (selectingIn) {
        _pairs.add((off: _pendingOff!, on: id));
        _pendingOff = null;
      } else {
        _pendingOff = id;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final usedOff = _pairs.map((e) => e.off).toSet();
    final usedOn = _pairs.map((e) => e.on).toSet();
    final availOff =
        widget.onField.where((p) => !usedOff.contains(p.id)).toList();
    final availOn = widget.bench.where((p) => !usedOn.contains(p.id)).toList();
    final selectingIn = _pendingOff != null;
    final candidates = selectingIn ? availOn : availOff;

    final maxH = MediaQuery.of(context).size.height * 0.82;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Kopf
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  const Icon(Icons.swap_horiz),
                  const SizedBox(width: 8),
                  Text('Wechsel',
                      style: Theme.of(context)
                          .textTheme
                          .titleLarge
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const Spacer(),
                  if (_pairs.isNotEmpty)
                    Text('${_pairs.length} geplant',
                        style: TextStyle(
                            color: scheme.primary,
                            fontWeight: FontWeight.w600)),
                ],
              ),
            ),
            // Geplante Paare
            if (_pairs.isNotEmpty) ...[
              const Divider(height: 1),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [for (final pair in _pairs) _plannedPairRow(pair)],
                ),
              ),
            ],
            const Divider(height: 1),
            // Hinweiszeile
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
              child: selectingIn
                  ? Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Wer kommt für ${_byId(_pendingOff!).displayName} rein?',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        TextButton(
                          onPressed: () =>
                              setState(() => _pendingOff = null),
                          child: const Text('Zurück'),
                        ),
                      ],
                    )
                  : const Text('Wer geht raus? (Feldspieler antippen)',
                      style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            // Auswahlliste
            Flexible(
              child: candidates.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(selectingIn
                          ? 'Keine Spieler mehr auf der Bank.'
                          : 'Keine Feldspieler mehr verfügbar.'),
                    )
                  : ListView(
                      padding: const EdgeInsets.only(bottom: 8),
                      children: [
                        for (final p in candidates)
                          ListTile(
                            leading: PlayerAvatar(player: p),
                            title: Text(p.fullName),
                            subtitle: Text([
                              if (p.number != null) 'Nr. ${p.number}',
                              if (p.position != null) p.position!,
                            ].join('  ·  ')),
                            trailing: Icon(
                              selectingIn ? Icons.login : Icons.logout,
                              color: selectingIn
                                  ? scheme.primary
                                  : Colors.redAccent,
                            ),
                            onTap: () => _onTap(p.id, selectingIn),
                          ),
                      ],
                    ),
            ),
            const Divider(height: 1),
            // Bestätigen
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _pairs.isEmpty
                      ? null
                      : () => Navigator.pop(context, _pairs),
                  icon: const Icon(Icons.check),
                  label: Text(_pairs.length <= 1
                      ? 'Wechsel bestätigen'
                      : '${_pairs.length} Wechsel bestätigen'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _plannedPairRow(({String off, String on}) pair) {
    final off = _byId(pair.off);
    final on = _byId(pair.on);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          const Icon(Icons.logout, size: 16, color: Colors.redAccent),
          const SizedBox(width: 4),
          Expanded(
              child: Text(off.displayName, overflow: TextOverflow.ellipsis)),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4),
            child: Icon(Icons.arrow_forward, size: 16),
          ),
          const Icon(Icons.login, size: 16, color: Colors.green),
          const SizedBox(width: 4),
          Expanded(
              child: Text(on.displayName, overflow: TextOverflow.ellipsis)),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            visualDensity: VisualDensity.compact,
            tooltip: 'Wechsel entfernen',
            onPressed: () => setState(() => _pairs.remove(pair)),
          ),
        ],
      ),
    );
  }
}
