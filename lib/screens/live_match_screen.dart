import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';

import '../models/enums.dart';
import '../models/match.dart';
import '../models/match_event.dart';
import '../models/player.dart';
import '../models/team.dart';
import '../services/live_clock.dart';
import '../services/share_service.dart';
import '../services/cloud_service.dart';
import '../state/app_state.dart';
import '../widgets/injury_icon.dart';
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

  // „Nachtragen": bei beendetem/pausiertem Spiel Aktionen mit gewählter Minute
  // erfassen. Minute wird beim Hinzufügen abgefragt und hier kurz überlagert.
  bool _addLater = false;
  int? _ovMinute;
  int _ovExtra = 0;

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

  int get _currentMinute => _ovMinute ?? _footMinute.$1;
  int get _currentExtra => _ovMinute != null ? _ovExtra : _footMinute.$2;

  /// Normalisiert (Minute, Nachspielzeit) zur Fußball-Schreibweise: liegt die
  /// Minute über der Halbzeit-Grenze (45 bzw. 90), wandert der Überhang in die
  /// Nachspielzeit (z.B. 47 → 45+2, 93 → 90+3).
  static (int, int) _normStoppage(int minute, int extra, int boundary) {
    final m = minute < 1 ? 1 : minute;
    final e = extra < 0 ? 0 : extra;
    if (m > boundary) return (boundary, (m - boundary) + e);
    return (m, e);
  }

  /// „Nachtragen" ist aktiv: Modus an, aber keine laufende Halbzeit (und kein
  /// Zuschauen). Dann sind die Aktions-Buttons nutzbar und fragen die Minute ab.
  bool get _nachtragen => _addLater && !_actionsEnabled && !_watchMode;

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
    List<MatchEvent> events,
  ) {
    const markers = <MatchEventType, (_Phase, int, bool)>{
      MatchEventType.kickoff: (_Phase.firstHalf, 0, true),
      MatchEventType.halftime: (_Phase.halftime, _halfSeconds, false),
      MatchEventType.secondHalfStart: (_Phase.secondHalf, _halfSeconds, true),
      MatchEventType.fulltime: (_Phase.finished, _fullSeconds, false),
      MatchEventType.extraFirstStart: (
        _Phase.extraFirstHalf,
        _fullSeconds,
        true,
      ),
      MatchEventType.extraHalftimeMark: (
        _Phase.extraHalftime,
        _extraFirstEnd,
        false,
      ),
      MatchEventType.extraSecondStart: (
        _Phase.extraSecondHalf,
        _extraFirstEnd,
        true,
      ),
      MatchEventType.shootoutStart: (_Phase.shootout, _fullExtra, false),
    };
    MatchEvent? latest;
    for (final e in events) {
      if (!markers.containsKey(e.type)) continue;
      if (latest == null || e.createdAt.isAfter(latest.createdAt)) latest = e;
    }
    if (latest == null) {
      return (
        phase: _Phase.notStarted,
        base: 0,
        running: false,
        anchorMs: null,
      );
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
    // Gegnerkader kann doppelte Zeilen je Spieler haben (Cloud/mehrere Geräte)
    // – fürs Erfassen/Auswählen zusammenführen.
    final oppPlayers = opp == null
        ? <Player>[]
        : dedupePlayersByName(await state.playersOf(opp.id));
    final events = await state.eventsOf(widget.matchId);
    final noms = await state.nominationsOf(widget.matchId);
    // Startelf aus der FREIGEGEBENEN Aufstellung (für Wechsel: Feld vs Bank).
    final starterIds = <String>{};
    final lineup = await state.repository.getReleasedLineup(
      widget.matchId,
      match.ownTeamId,
    );
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
    await context.read<AppState>().setMatchStatus(
      widget.matchId,
      MatchStatus.live,
    );
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
    await context.read<AppState>().setMatchStatus(
      widget.matchId,
      MatchStatus.live,
    );
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
  Future<void> _addShootoutShot({
    required bool ownSide,
    required bool scored,
  }) async {
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
            Text(
              name,
              style: TextStyle(fontWeight: FontWeight.bold, color: color),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
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
              ],
            ),
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
                const Text(
                  'Elfmeterschießen',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  '$ownName  $own : $opp  $oppName',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
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

  /// Schmaler Hinweisstreifen oben im Live-Screen.
  Widget _banner(
    BuildContext context,
    Color color,
    IconData icon,
    String text,
  ) {
    return Container(
      width: double.infinity,
      color: color,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }

  String _scopeLabel(String scope) => switch (scope) {
    'own' => 'eigene Mannschaft + Uhr',
    'opp' => 'Gegner',
    'both' => 'beide Seiten + Uhr',
    _ => scope,
  };

  /// Beantragt die Live-Erfassung beim Haupt-Ticker – mit Auswahl des Umfangs:
  /// eigene Mannschaft (inkl. Uhr), Gegner oder beide.
  Future<void> _requestControl() async {
    final match = _match;
    if (match == null) return;
    final me = CloudService.userId;
    // Was ich (als möglicher Delegierter) schon erfassen darf.
    final iOwn = match.liveDelegateOwn != null && match.liveDelegateOwn == me;
    final iOpp = match.liveControllerOpp != null &&
        match.liveControllerOpp == me;

    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Erfassung anfragen',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Der Haupt-Ticker muss freigeben. Die Uhr bleibt beim '
                  'Haupt-Ticker; bis zur Freigabe kannst du nur kommentieren.',
                  style: TextStyle(fontSize: 12.5, color: Colors.grey),
                ),
              ),
            ),
            const Divider(height: 1),
            ListTile(
              enabled: !iOwn,
              leading: const Icon(Icons.sports),
              title: const Text('Eigene Mannschaft'),
              subtitle: Text(iOwn ? 'Darfst du schon' : 'Tore/Karten/Wechsel'),
              onTap: () => Navigator.pop(ctx, 'own'),
            ),
            ListTile(
              enabled: !iOpp,
              leading: const Icon(Icons.flag_outlined),
              title: const Text('Gegner'),
              subtitle: Text(iOpp ? 'Darfst du schon' : 'Gegner-Ereignisse'),
              onTap: () => Navigator.pop(ctx, 'opp'),
            ),
            ListTile(
              enabled: !(iOwn && iOpp),
              leading: const Icon(Icons.groups),
              title: const Text('Beide Seiten'),
              onTap: () => Navigator.pop(ctx, 'both'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    await _state.requestLiveControl(widget.matchId, choice);
    await _refreshEvents();
    if (mounted && (match.liveController ?? '').isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Anfrage gesendet – warte auf Genehmigung.')),
      );
    }
  }

  Future<void> _approveRequest() async {
    await _state.approveLiveRequest(widget.matchId);
    await _refreshEvents();
  }

  Future<void> _declineRequest() async {
    await _state.declineLiveRequest(widget.matchId);
    await _refreshEvents();
  }

  /// Steuerungs-Banner: Haupt-Ticker (volle Kontrolle) genehmigt Anfragen;
  /// Delegierte erfassen eine Seite zusätzlich; alle anderen kommentieren nur.
  Widget _controlBanner(
    BuildContext context,
    GameMatch match,
    bool iAmMain,
    bool iControlOwn,
    bool iControlOpp,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final me = CloudService.userId;
    final reqBy = match.liveRequestBy;
    final hasRequest = reqBy != null && reqBy.isNotEmpty;
    final reqScope = match.liveRequestScope ?? 'both';
    final reqName = match.liveRequestByName?.trim();
    final oppDeleg = match.liveControllerOppName?.trim();
    final ownDeleg = match.liveDelegateOwnName?.trim();

    // 1) Haupt-Ticker + offene fremde Anfrage → genehmigen/ablehnen.
    if (hasRequest && reqBy != me && iAmMain) {
      return Container(
        width: double.infinity,
        color: scheme.tertiaryContainer,
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        child: Row(
          children: [
            const Icon(Icons.pan_tool, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${(reqName != null && reqName.isNotEmpty) ? reqName : 'Ein Trainer'} '
                'möchte erfassen: ${_scopeLabel(reqScope)}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            TextButton(
              onPressed: _declineRequest,
              child: const Text('Ablehnen'),
            ),
            FilledButton(
              onPressed: _approveRequest,
              child: const Text('Freigeben'),
            ),
          ],
        ),
      );
    }

    // 2) Meine eigene Anfrage läuft noch.
    if (hasRequest && reqBy == me) {
      return Container(
        width: double.infinity,
        color: scheme.secondaryContainer,
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        child: Row(
          children: [
            const Icon(Icons.hourglass_top, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Anfrage läuft (${_scopeLabel(reqScope)}) – warte auf Freigabe.',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            TextButton(
              onPressed: () => _state.cancelMyLiveRequest(widget.matchId),
              child: const Text('Abbrechen'),
            ),
          ],
        ),
      );
    }

    // 3) Haupt-Ticker → volle Kontrolle, grüner Hinweis (ggf. Delegierte nennen).
    if (iAmMain) {
      final deleg = [
        if (oppDeleg != null && oppDeleg.isNotEmpty) 'Gegner: $oppDeleg',
        if (ownDeleg != null && ownDeleg.isNotEmpty) 'eigene: $ownDeleg',
      ].join(', ');
      return _banner(
        context,
        scheme.primaryContainer,
        Icons.sports,
        deleg.isEmpty
            ? 'Du bist Haupt-Ticker – volle Kontrolle (beide Seiten + Uhr).'
            : 'Du bist Haupt-Ticker – volle Kontrolle. Zusätzlich erfasst: $deleg.',
      );
    }

    // 4) Delegierter → erfasst eine Seite (freigegeben); kann mehr anfragen.
    final mainWho = match.liveControllerName?.trim();
    String text;
    if (iControlOwn || iControlOpp) {
      final side = (iControlOwn && iControlOpp)
          ? 'beide Seiten'
          : (iControlOpp ? 'den Gegner' : 'die eigene Mannschaft');
      text =
          'Du erfasst $side (freigegeben). Haupt-Ticker: '
          '${(mainWho != null && mainWho.isNotEmpty) ? mainWho : 'unbekannt'}.';
    } else {
      text = 'Nur Kommentare möglich – Erfassung beim Haupt-Ticker anfragen.';
    }
    return Container(
      width: double.infinity,
      color: scheme.errorContainer,
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
      child: Row(
        children: [
          const Icon(Icons.lock_outline, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          TextButton(
            onPressed: _requestControl,
            child: const Text('Anfragen'),
          ),
        ],
      ),
    );
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
    // HAUPT-TICKER (live_controller = Starter) hat IMMER die volle Kontrolle
    // (beide Seiten + Uhr). Delegierte (live_delegate_own / live_controller_opp)
    // dürfen eine Seite ZUSÄTZLICH erfassen; sie nehmen dem Haupt-Ticker nichts
    // weg. Ohne Rolle darf man nur kommentieren.
    final me = CloudService.userId;
    final mainTicker = match.liveController;
    final mainSet = mainTicker != null && mainTicker.isNotEmpty;
    // Vor dem Anpfiff ist niemand gesetzt → jeder Berechtigte darf starten.
    final iAmMain = !mainSet || mainTicker == me;
    final delOwn = match.liveDelegateOwn;
    final delOpp = match.liveControllerOpp;
    final iControlOwn = iAmMain || (delOwn != null && delOwn == me);
    final iControlOpp = iAmMain || (delOpp != null && delOpp == me);
    // Uhr/Phasen (Anpfiff/Halbzeit/Abpfiff …) nur der Haupt-Ticker.
    final editing = canEdit && iAmMain && !_watchMode;
    final canRecord = canEdit && !_watchMode;
    final canRecordOwn = canRecord && iControlOwn;
    final canRecordOpp = canRecord && iControlOpp;
    final canRecordAny = canRecordOwn || canRecordOpp;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Live-Spiel'),
        actions: [
          IconButton(
            tooltip: 'Dashboard (Statistik)',
            icon: const Icon(Icons.leaderboard),
            onPressed: _openDashboard,
          ),
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
                  value: 'reset',
                  child: Text('Spiel zurücksetzen'),
                ),
              ],
            ),
        ],
      ),
      body: Column(
        children: [
          if (!canEdit || _watchMode)
            _banner(
              context,
              Theme.of(context).colorScheme.secondaryContainer,
              Icons.visibility,
              'Du schaust zu – du siehst nur den Ticker.',
            )
          else
            _controlBanner(context, match, iAmMain, iControlOwn, iControlOpp),
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
            showShootout:
                _phase == _Phase.shootout ||
                _events.any(
                  (e) =>
                      e.type == MatchEventType.soGoal ||
                      e.type == MatchEventType.soMiss,
                ),
          ),
          // Phasen-Leiste nur für den Steuerer der eigenen Mannschaft/Uhr –
          // andere sehen sie gar nicht (nicht ausgegraut).
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
                if (canEdit && !_watchMode && _phase == _Phase.shootout &&
                    iAmMain)
                  _shootoutPanel(context, match),
                if (_phase != _Phase.shootout &&
                    _events.any(
                      (e) =>
                          e.type == MatchEventType.soGoal ||
                          e.type == MatchEventType.soMiss,
                    ))
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
                // Erfass-Menü nur rendern, wenn man mind. eine Seite steuert –
                // sonst GAR NICHT (nicht ausgegraut); nur Kommentare bleiben.
                if (canEdit &&
                    !_watchMode &&
                    _phase != _Phase.shootout &&
                    (iControlOwn || iControlOpp))
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Nachtragen-Schalter: bei beendetem/pausiertem Spiel
                      // Aktionen mit abgefragter Minute erfassen.
                      if (!_actionsEnabled && _phase != _Phase.notStarted)
                        SwitchListTile(
                          dense: true,
                          secondary: const Icon(Icons.edit_calendar),
                          title: const Text('Aktionen nachtragen'),
                          subtitle: const Text(
                            'Minute wird beim Hinzufügen abgefragt',
                          ),
                          value: _addLater,
                          onChanged: (v) => setState(() => _addLater = v),
                        ),
                      // Eigene Mannschaft – nur wenn eigene Seite übernommen.
                      if (iControlOwn)
                        _TeamActionBar(
                          label: _ownTeam?.name ?? 'Eigenes Team',
                          color: Theme.of(context).colorScheme.primary,
                          isOwn: true,
                          // Während einer HZ, oder im Nachtragen-Modus.
                          enabled: _actionsEnabled || _nachtragen,
                          onGoal: () => _act(() => _addGoal(ownSide: true)),
                          onCard: () => _act(() => _addCard(ownSide: true)),
                          onSub: () => _act(() => _addSub(ownSide: true)),
                          onSave: () => _act(() => _addSave(ownSide: true)),
                          onEvent: () =>
                              _act(() => _addOtherEvent(ownSide: true)),
                        ),
                      // Gegner – nur wenn Gegner-Seite übernommen.
                      if (iControlOpp)
                        _TeamActionBar(
                          label: match.opponentName,
                          color: const Color(0xFFB26A00),
                          isOwn: false,
                          enabled: _actionsEnabled || _nachtragen,
                          onGoal: () => _act(() => _addGoal(ownSide: false)),
                          // Gegner-Karten erfassen (Spieler optional „Unbekannt").
                          onCard: () => _act(() => _addCard(ownSide: false)),
                          // Gegner-Wechsel ohne Spielerauswahl (kein Gegner-Kader).
                          onSub: () => _act(() => _addSub(ownSide: false)),
                          onSave: () => _act(() => _addSave(ownSide: false)),
                          onEvent: () =>
                              _act(() => _addOtherEvent(ownSide: false)),
                        ),
                    ],
                  ),
                const SizedBox(height: 8),
                _EventLog(
                  events: _events,
                  ownTeamId: match.ownTeamId,
                  resolveName: _playerName,
                  resolvePlayer: _playerById,
                  onDelete: canRecordAny ? _deleteEvent : null,
                  onEdit: canRecordAny ? _editEvent : null,
                ),
              ],
            ),
          ),
          // Kommentar fest an der Fußleiste (nicht mitscrollend).
          if (canEdit && !_watchMode && _phase != _Phase.shootout)
            _commentFooter(context),
        ],
      ),
    );
  }

  /// Fest an der Fußleiste angedockter Kommentar-Button.
  Widget _commentFooter(BuildContext context) {
    final enabled = _actionsEnabled || _nachtragen;
    return Material(
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: enabled ? () => _act(_addComment) : null,
              icon: const Icon(Icons.chat_bubble_outline, size: 18),
              label: const Text('Kommentar'),
            ),
          ),
        ),
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

  /// Führt eine Erfassungs-Aktion aus. Im Nachtragen-Modus wird zuerst die
  /// Minute abgefragt und für die Dauer der Aktion als Spielminute überlagert.
  Future<void> _act(Future<void> Function() add) async {
    if (!_nachtragen) {
      await add();
      return;
    }
    final at = await _askMinute();
    if (at == null || !mounted) return;
    _ovMinute = at.$1;
    _ovExtra = at.$2;
    try {
      await add();
    } finally {
      _ovMinute = null;
      _ovExtra = 0;
    }
  }

  /// Fragt die Spielminute (+ optionale Nachspielzeit) fürs Nachtragen ab.
  /// Vorbelegt mit 90'. Gibt (Minute, Nachspielzeit) zurück oder null.
  Future<(int, int)?> _askMinute() async {
    final minCtrl = TextEditingController(text: '90');
    final extraCtrl = TextEditingController();
    int half = 2; // Vorbelegung: 2. Halbzeit (90')
    final result = await showDialog<(int, int)>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setD) => AlertDialog(
          title: const Text('Minute der Aktion'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SegmentedButton<int>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 1, label: Text('1. HZ')),
                  ButtonSegment(value: 2, label: Text('2. HZ')),
                ],
                selected: {half},
                onSelectionChanged: (s) {
                  final was = half;
                  final def = was == 1 ? '45' : '90';
                  setD(() {
                    half = s.first;
                    // Standard-Minute mitschalten, wenn noch unverändert.
                    if (minCtrl.text.trim() == def) {
                      minCtrl.text = half == 1 ? '45' : '90';
                    }
                  });
                },
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 90,
                    child: TextField(
                      controller: minCtrl,
                      keyboardType: TextInputType.number,
                      autofocus: true,
                      decoration: const InputDecoration(labelText: 'Minute'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 90,
                    child: TextField(
                      controller: extraCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '+ (optional)',
                      ),
                    ),
                  ),
                ],
              ),
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Über 45 (1. HZ) bzw. 90 (2. HZ) wird automatisch zur '
                  'Nachspielzeit (z.B. 47 → 45+2).',
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () {
                final m = int.tryParse(minCtrl.text.trim());
                if (m == null) return;
                final ex = int.tryParse(extraCtrl.text.trim()) ?? 0;
                Navigator.pop(
                  context,
                  _normStoppage(m, ex < 0 ? 0 : ex, half == 1 ? 45 : 90),
                );
              },
              child: const Text('Weiter'),
            ),
          ],
        ),
      ),
    );
    return result;
  }

  /// Eigene Spieler, die aktuell auf dem Feld stehen (für Tor/Karte).
  List<Player> _onFieldPlayers(bool ownSide) {
    if (!ownSide) return _opponentPlayers;
    final ids = _onFieldIds;
    return _ownPlayers.where((p) => ids.contains(p.id)).toList();
  }

  /// Auswahl-Pool für Tor/Karte: im Nachtragen-Modus alle nominierten Spieler
  /// (jemand kann früher getroffen/verwarnt und später ausgewechselt worden
  /// sein), sonst nur die aktuell auf dem Feld stehenden.
  List<Player> _pickPool(bool ownSide) =>
      _nachtragen ? _playersFor(ownSide) : _onFieldPlayers(ownSide);

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
      // Wechsel UND „Verletzt raus" verschieben das Feld: geht runter, (falls
      // vorhanden) Ersatz kommt rauf.
      if (e.type != MatchEventType.substitution &&
          e.type != MatchEventType.injuredOff) {
        continue;
      }
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
            hintText: 'z.B. Traumtor aus 20 m',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, '\u0000cancel'),
            child: const Text('Abbrechen'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ''),
            child: const Text('Ohne'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Speichern'),
          ),
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

    // Nur Spieler, die aktuell auf dem Feld sind (Bank kann nicht treffen) –
    // beim Nachtragen alle Nominierten.
    final players = _pickPool(ownSide);
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
    // Karte für Spieler auf dem Feld – beim Nachtragen alle Nominierten.
    final players = _pickPool(ownSide);
    final player = await _pickPlayer(
      title: 'Spieler',
      players: players,
      allowUnknown: true,
    );
    if (player == _pickCancelled || !mounted) return;
    final pid = player == _pickUnknown ? null : player;
    // Hat der Spieler in diesem Spiel schon Gelb? Dann kein zweites Gelb.
    final hasYellow =
        pid != null &&
        _events.any(
          (e) => e.type == MatchEventType.yellowCard && e.playerId == pid,
        );
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
    // Gegner-Wechsel: kein Gegner-Kader → ohne Spielerauswahl, nur als Eintrag
    // (optional mit Notiz, wie beim Gegner-Tor).
    if (!ownSide) {
      final n = await _askNote();
      if (!n.proceed || !mounted) return;
      await state.addEvent(
        matchId: widget.matchId,
        teamId: _teamIdFor(false),
        minute: _currentMinute,
        minuteExtra: _currentExtra,
        type: MatchEventType.substitution,
        note: n.note,
      );
      await _refreshEvents();
      return;
    }
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

  /// Ist der Spieler ein Torwart? (Positionsliste „TW" oder Freitext „Tor…").
  bool _isGoalkeeper(Player p) {
    if (p.positions.any((x) => x.toUpperCase() == 'TW')) return true;
    final pos = (p.position ?? '').toLowerCase();
    return pos.contains('tor') || pos == 'tw' || pos.contains('keeper');
  }

  /// Torwart-Parade (TW): wählt automatisch den aktuellen Torwart (sonst
  /// Spielerauswahl) und fragt danach die Schussart ab.
  Future<void> _addSave({required bool ownSide}) async {
    final state = context.read<AppState>();
    final players = ownSide ? _onFieldPlayers(true) : _opponentPlayers;
    final keepers = players.where(_isGoalkeeper).toList();
    String? playerId;
    if (keepers.length == 1) {
      playerId = keepers.first.id; // genau ein Torwart → automatisch
    } else {
      final res = await _pickPlayer(
        title: 'Torwart',
        players: keepers.isNotEmpty ? keepers : players,
        allowUnknown: true,
      );
      if (res == _pickCancelled) return;
      playerId = res == _pickUnknown ? null : res;
    }
    if (!mounted) return;
    final shot = await _askSaveType();
    if (shot == null) return; // abgebrochen
    await state.addEvent(
      matchId: widget.matchId,
      teamId: _teamIdFor(ownSide),
      minute: _currentMinute,
      minuteExtra: _currentExtra,
      type: MatchEventType.save,
      playerId: playerId,
      note: shot.isEmpty ? null : shot,
    );
    await _refreshEvents();
  }

  /// Schussart einer Parade. Rückgabe: Schussart, '' für „Ohne Angabe", null
  /// bei Abbruch.
  Future<String?> _askSaveType() {
    const types = ['Distanzschuss', 'Schuss', '1-gegen-1', 'Kopfball'];
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Parade – Schussart',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final t in types)
                    ListTile(
                      leading: const Text('🧤', style: TextStyle(fontSize: 20)),
                      title: Text(t),
                      onTap: () => Navigator.pop(context, t),
                    ),
                  ListTile(
                    leading: const Icon(Icons.block, size: 20),
                    title: const Text('Ohne Angabe'),
                    onTap: () => Navigator.pop(context, ''),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Weitere Ereignisse: Typ wählen, optional Spieler + Notiz.
  Future<void> _addOtherEvent({required bool ownSide}) async {
    const types = [
      MatchEventType.shot,
      MatchEventType.longShot,
      MatchEventType.header,
      MatchEventType.corner,
      MatchEventType.freeKick,
      MatchEventType.penalty,
      MatchEventType.foul,
      MatchEventType.bigChance,
      MatchEventType.meckern,
      MatchEventType.injury,
      MatchEventType.injuredOff,
    ];
    final type = await showModalBottomSheet<MatchEventType>(
      context: context,
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Ereignis',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final t in types)
                    ListTile(
                      leading: Text(
                        t.symbol,
                        style: const TextStyle(fontSize: 20),
                      ),
                      title: Text(t.label),
                      onTap: () => Navigator.pop(context, t),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (type == null || !mounted) return;
    // „Verletzt raus": eigener Flow (verletzter Spieler runter, optional Ersatz).
    if (type == MatchEventType.injuredOff) {
      await _addInjuredOff(ownSide: ownSide);
      return;
    }
    // Elfmeter: erst den Ausgang abfragen (Tor / verschossen / gehalten).
    var resolved = type;
    if (type == MatchEventType.penalty) {
      final outcome = await _askPenaltyOutcome();
      if (outcome == null || !mounted) return;
      resolved = outcome;
    }
    final detail = await _eventDetail(resolved, _pickPool(ownSide));
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

  /// „Verletzt raus": verletzter Spieler geht vom Feld; optional kommt ein
  /// Ersatz von der Bank (sonst Unterzahl). Wird wie ein Wechsel geführt
  /// (Feld-Tracking), aber als eigene Aktion. Gegner: nur protokollieren.
  Future<void> _addInjuredOff({required bool ownSide}) async {
    final state = context.read<AppState>();
    if (!ownSide) {
      // Gegner hat keinen Kader/Bank → nur protokollieren (Spieler optional).
      final offRes = await _pickPlayer(
        title: 'Verletzt raus (Gegner)',
        players: _opponentPlayers,
        allowUnknown: true,
      );
      if (offRes == _pickCancelled) return;
      final offId = offRes == _pickUnknown ? null : offRes;
      if (!mounted) return;
      await state.addEvent(
        matchId: widget.matchId,
        teamId: _teamIdFor(false),
        minute: _currentMinute,
        minuteExtra: _currentExtra,
        type: MatchEventType.injuredOff,
        assistPlayerId: offId, // Verletzter (geht)
      );
      await _refreshEvents();
      return;
    }

    final players = _playersFor(true);
    final onIds = _onFieldIds;
    final sentOff = _sentOffIds;
    final onField = players.where((p) => onIds.contains(p.id)).toList();
    if (onField.isEmpty) {
      _snack('Niemand auf dem Feld – bitte zuerst aufstellen.');
      return;
    }
    // Verletzten Spieler (geht) wählen.
    final offRes = await _pickPlayer(
      title: 'Verletzt raus',
      players: onField,
      allowUnknown: true,
    );
    if (offRes == _pickCancelled) return;
    final offId = offRes == _pickUnknown ? null : offRes;
    if (!mounted) return;
    // Ersatz von der Bank (optional: „Ohne Einwechslung").
    final bench = players
        .where(
          (p) =>
              !onIds.contains(p.id) && !sentOff.contains(p.id) && p.id != offId,
        )
        .toList();
    String? onId;
    if (bench.isNotEmpty) {
      final onRes = await _pickPlayer(
        title: 'Ersatzspieler',
        players: bench,
        allowNone: true,
        noneLabel: 'Ohne Einwechslung',
      );
      if (onRes == _pickCancelled) return;
      onId = onRes == _pickNone ? null : onRes;
    }
    if (!mounted) return;
    await state.addEvent(
      matchId: widget.matchId,
      teamId: _teamIdFor(true),
      minute: _currentMinute,
      minuteExtra: _currentExtra,
      type: MatchEventType.injuredOff,
      playerId: onId, // Ersatz (kommt); null = ohne Einwechslung
      assistPlayerId: offId, // Verletzter (geht)
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
                child: Text(
                  'Elfmeter – Ausgang',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
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
    return Navigator.of(
      context,
    ).push<({String? playerId, String? note, List<String> mentions})>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _EventDetailPage(type: type, players: players),
      ),
    );
  }

  /// Neutraler Freitext-Kommentar (ebenfalls als Vollbild-Seite). Erwähnte
  /// Spieler werden verknüpft und erscheinen im jeweiligen Profil.
  Future<void> _addComment() async {
    final detail = await _eventDetail(
      MatchEventType.comment,
      _playersFor(true),
    );
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
              title: Text(
                e.type == MatchEventType.comment
                    ? 'Text ändern'
                    : 'Text/Spieler ändern',
              ),
              onTap: () => Navigator.pop(context, 'edit'),
            ),
            // Aktion (Typ) ändern – nicht für Phasen-Marken / Elfmeterschießen.
            if (!e.type.isPhaseMarker &&
                e.type != MatchEventType.soGoal &&
                e.type != MatchEventType.soMiss)
              ListTile(
                leading: const Icon(Icons.swap_horizontal_circle_outlined),
                title: const Text('Aktion ändern'),
                onTap: () => Navigator.pop(context, 'action'),
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
    } else if (action == 'action') {
      await _changeEventType(e);
    } else if (action == 'minute') {
      final minCtrl = TextEditingController(text: '${e.minute}');
      final extraCtrl = TextEditingController(
        text: e.minuteExtra > 0 ? '${e.minuteExtra}' : '',
      );
      final res = await showDialog<(int, int)>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Minute'),
          content: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 90,
                child: TextField(
                  controller: minCtrl,
                  keyboardType: TextInputType.number,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Minute'),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 90,
                child: TextField(
                  controller: extraCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '+ (optional)'),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () {
                final m = int.tryParse(minCtrl.text.trim());
                if (m == null) return;
                final ex = int.tryParse(extraCtrl.text.trim()) ?? 0;
                Navigator.pop(context, (m, ex < 0 ? 0 : ex));
              },
              child: const Text('Speichern'),
            ),
          ],
        ),
      );
      if (res != null && mounted) {
        // Grenze aus der bisherigen Minute ableiten (1. HZ ≤ 45, sonst 90);
        // Verlängerung (> 90) bleibt unverändert.
        final boundary = e.minute <= 45 ? 45 : (e.minute <= 90 ? 90 : null);
        final (nm, nx) = boundary == null
            ? res
            : _normStoppage(res.$1, res.$2, boundary);
        await context.read<AppState>().updateEvent(
          e.copyWith(minute: nm, minuteExtra: nx),
        );
        await _refreshEvents();
      }
    }
  }

  /// Ändert die Aktion (Typ) eines Ereignisses nachträglich – inkl. Team
  /// (Eigenes/Gegner) und optional direkter Spielerauswahl. Spielstand und
  /// Cloud-Sync aktualisieren sich automatisch über updateEvent.
  Future<void> _changeEventType(MatchEvent e) async {
    final newType = await _pickEventType();
    if (newType == null || !mounted) return;

    final isComment = newType == MatchEventType.comment;
    var teamId = e.teamId;
    var ownSide = e.teamId == _match!.ownTeamId;
    var playerId = e.playerId;

    if (isComment) {
      // Kommentar ist team-neutral (eigenes Team), ohne Spieler.
      teamId = _teamIdFor(true);
    } else {
      final side = await _pickSide(defaultOwn: ownSide);
      if (side == null || !mounted) return;
      final teamChanged = side != ownSide;
      ownSide = side;
      teamId = _teamIdFor(ownSide);

      const needsPlayer = {
        MatchEventType.goal,
        MatchEventType.ownGoal,
        MatchEventType.yellowCard,
        MatchEventType.secondYellow,
        MatchEventType.redCard,
        MatchEventType.penalty,
        MatchEventType.penaltyMissed,
        MatchEventType.penaltySaved,
        MatchEventType.save,
        MatchEventType.shot,
        MatchEventType.longShot,
        MatchEventType.header,
        MatchEventType.injury,
      };
      if (needsPlayer.contains(newType)) {
        final players = ownSide ? _onFieldPlayers(true) : _opponentPlayers;
        final res = await _pickPlayer(
          title: 'Spieler',
          players: players,
          allowUnknown: true,
        );
        if (res != _pickCancelled) {
          playerId = res == _pickUnknown ? null : res;
        } else if (teamChanged) {
          playerId =
              null; // Abbruch + Team gewechselt → alter Spieler passt nicht
        }
      } else if (teamChanged) {
        playerId = null;
      }
    }
    if (!mounted) return;

    final updated = MatchEvent(
      id: e.id,
      matchId: e.matchId,
      teamId: teamId,
      minute: e.minute,
      minuteExtra: e.minuteExtra,
      type: newType,
      playerId: playerId,
      assistPlayerId: e.assistPlayerId,
      note: e.note,
      createdAt: e.createdAt,
    );
    await context.read<AppState>().updateEvent(updated);
    await _refreshEvents();
  }

  /// Auswahl des neuen Ereignistyps (ohne Wechsel/Phasen/Elfmeterschießen).
  Future<MatchEventType?> _pickEventType() {
    const entries = <(String, MatchEventType)>[
      ('Tor', MatchEventType.goal),
      ('Eigentor', MatchEventType.ownGoal),
      ('Gelbe Karte', MatchEventType.yellowCard),
      ('Gelb-Rote Karte', MatchEventType.secondYellow),
      ('Rote Karte', MatchEventType.redCard),
      ('Elfmeter (Tor)', MatchEventType.penalty),
      ('Elfmeter verschossen', MatchEventType.penaltyMissed),
      ('Elfmeter gehalten', MatchEventType.penaltySaved),
      ('Schuss', MatchEventType.shot),
      ('Distanzschuss', MatchEventType.longShot),
      ('Kopfball', MatchEventType.header),
      ('Ecke', MatchEventType.corner),
      ('Freistoß', MatchEventType.freeKick),
      ('Foul', MatchEventType.foul),
      ('Großchance', MatchEventType.bigChance),
      ('Meckern', MatchEventType.meckern),
      ('Parade', MatchEventType.save),
      ('Behandlung', MatchEventType.injury),
      ('Kommentar', MatchEventType.comment),
    ];
    return showModalBottomSheet<MatchEventType>(
      context: context,
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Aktion wählen',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ),
            ),
            const Divider(height: 1),
            for (final en in entries)
              ListTile(
                leading: Text(
                  en.$2.symbol,
                  style: const TextStyle(fontSize: 20),
                ),
                title: Text(en.$1),
                onTap: () => Navigator.pop(context, en.$2),
              ),
          ],
        ),
      ),
    );
  }

  /// Team-Auswahl (Eigenes Team / Gegner). Rückgabe: true = eigenes Team.
  Future<bool?> _pickSide({required bool defaultOwn}) {
    final ownName = _ownTeam?.shortName ?? _ownTeam?.name ?? 'Eigenes Team';
    final oppName = _opponentTeam?.name ?? _match?.opponentName ?? 'Gegner';
    return showModalBottomSheet<bool>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Team',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.home),
              title: Text(ownName),
              trailing: defaultOwn ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(context, true),
            ),
            ListTile(
              leading: const Icon(Icons.flag_outlined),
              title: Text(oppName),
              trailing: !defaultOwn ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(context, false),
            ),
          ],
        ),
      ),
    );
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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
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
    // Über das System-Teilen-Menü (Handy) – kein Längenlimit, der komplette
    // Ticker kommt an; Desktop nutzt den wa.me-Link.
    final ok = await shareText(text);
    if (!ok) _snack('Teilen nicht möglich.');
  }

  // ------------------------------------------------------------- Dashboard
  /// Halbzeit eines Ereignisses: 1 = 1. HZ, 2 = 2. HZ (inkl. Verlängerung).
  /// Ermittelt über die Phasen-Marken (Anpfiff 2. HZ bzw. Halbzeit), sonst
  /// als Rückfall über die Spielminute (≤ 45 → 1. HZ).
  int _halfOf(MatchEvent e) {
    final secondStart = _events
        .where((x) => x.type == MatchEventType.secondHalfStart)
        .map((x) => x.createdAt)
        .firstOrNull;
    if (secondStart != null) {
      return e.createdAt.isBefore(secondStart) ? 1 : 2;
    }
    final halftime = _events
        .where((x) => x.type == MatchEventType.halftime)
        .map((x) => x.createdAt)
        .firstOrNull;
    if (halftime != null) {
      return e.createdAt.isAfter(halftime) ? 2 : 1;
    }
    return e.minute <= 45 ? 1 : 2;
  }

  /// Statistik-Übersicht (Wir vs. Gegner) als Bottom-Sheet. Zählt die
  /// erfassten Aktionen je Seite aus den aktuellen Ereignissen (Snapshot),
  /// wahlweise gesamt oder je Halbzeit.
  Future<void> _openDashboard() async {
    final match = _match;
    if (match == null) return;
    final scheme = Theme.of(context).colorScheme;
    const oppColor = Color(0xFFB26A00);
    final ownName = _ownTeam?.shortName ?? _ownTeam?.name ?? 'Wir';
    final oppName = _opponentTeam?.name ?? match.opponentName;

    const rows = <(String, Set<MatchEventType>)>[
      ('Tore', {MatchEventType.goal, MatchEventType.penalty}),
      ('Eigentore', {MatchEventType.ownGoal}),
      ('Schüsse', {MatchEventType.shot}),
      ('Distanzschüsse', {MatchEventType.longShot}),
      ('Kopfbälle', {MatchEventType.header}),
      ('Großchancen', {MatchEventType.bigChance}),
      (
        'Elfmeter',
        {
          MatchEventType.penalty,
          MatchEventType.penaltyMissed,
          MatchEventType.penaltySaved,
        },
      ),
      ('Ecken', {MatchEventType.corner}),
      ('Freistöße', {MatchEventType.freeKick}),
      ('Fouls', {MatchEventType.foul}),
      ('Gelbe Karten', {MatchEventType.yellowCard}),
      ('Gelb-Rote Karten', {MatchEventType.secondYellow}),
      ('Rote Karten', {MatchEventType.redCard}),
      ('Paraden', {MatchEventType.save}),
      ('Meckern', {MatchEventType.meckern}),
      ('Behandlungen', {MatchEventType.injury}),
      ('Verletzt raus', {MatchEventType.injuredOff}),
      ('Wechsel', {MatchEventType.substitution}),
    ];

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.8,
        maxChildSize: 0.95,
        minChildSize: 0.4,
        builder: (ctx, scroll) {
          final boundaryKey = GlobalKey();
          int half = 0; // 0 = gesamt, 1 = 1. HZ, 2 = 2. HZ
          return StatefulBuilder(
            builder: (ctx, setSheet) {
              final halfLabel = half == 1
                  ? '1. Halbzeit'
                  : half == 2
                  ? '2. Halbzeit'
                  : 'Gesamt';
              int count(bool own, Set<MatchEventType> types) => _events
                  .where(
                    (e) =>
                        types.contains(e.type) &&
                        (own
                            ? e.teamId == match.ownTeamId
                            : e.teamId != match.ownTeamId) &&
                        (half == 0 || _halfOf(e) == half),
                  )
                  .length;
              // Statistik als Bild teilen (RepaintBoundary → PNG → WhatsApp).
              Future<void> shareStats() async {
                final nav = Navigator.of(ctx);
                try {
                  final b =
                      boundaryKey.currentContext?.findRenderObject()
                          as RenderRepaintBoundary?;
                  if (b == null) return;
                  final image = await b.toImage(pixelRatio: 2.5);
                  final data = await image.toByteData(
                    format: ui.ImageByteFormat.png,
                  );
                  if (data == null) return;
                  nav.pop();
                  final suffix = half == 0 ? '' : '_${half}HZ';
                  final path = await shareOrSaveImage(
                    data.buffer.asUint8List(),
                    'Statistik_$ownName$suffix',
                    text: 'Statistik ($halfLabel) – $ownName',
                  );
                  if (path != null && mounted) {
                    _snack('Als Bild gespeichert:\n$path');
                  }
                } catch (e) {
                  if (mounted) _snack('Teilen fehlgeschlagen: $e');
                }
              }

              final content = Container(
                color: scheme.surface,
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                child: Column(
                  children: [
                    const Text(
                      'Statistik',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    if (half != 0)
                      Text(
                        halfLabel,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                          color: scheme.primary,
                        ),
                      ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(child: _dashTeam(_ownTeam?.logoPath, ownName)),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Text(
                            '${match.ownScore} : ${match.opponentScore}',
                            style: const TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        Expanded(
                          child: _dashTeam(
                            _opponentTeam?.logoPath ?? match.opponentLogoPath,
                            oppName,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _dashLegend('Wir', scheme.primary),
                        _dashLegend('Gegner', oppColor),
                      ],
                    ),
                    const Divider(height: 20),
                    for (final r in rows)
                      _dashStatRow(
                        r.$1,
                        count(true, r.$2),
                        count(false, r.$2),
                        scheme.primary,
                        oppColor,
                      ),
                  ],
                ),
              );

              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: SegmentedButton<int>(
                            showSelectedIcon: false,
                            style: const ButtonStyle(
                              visualDensity: VisualDensity.compact,
                            ),
                            segments: const [
                              ButtonSegment(value: 0, label: Text('Gesamt')),
                              ButtonSegment(value: 1, label: Text('1. HZ')),
                              ButtonSegment(value: 2, label: Text('2. HZ')),
                            ],
                            selected: {half},
                            onSelectionChanged: (s) =>
                                setSheet(() => half = s.first),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Als Bild teilen (WhatsApp)',
                          icon: const Icon(Icons.share),
                          onPressed: shareStats,
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      controller: scroll,
                      child: RepaintBoundary(key: boundaryKey, child: content),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _dashTeam(String? logo, String name) => Column(
    children: [
      if (logo != null) ...[
        TeamLogo(logoPath: logo, size: 36),
        const SizedBox(height: 4),
      ],
      Text(
        name,
        textAlign: TextAlign.center,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
    ],
  );

  Widget _dashLegend(String label, Color c) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          color: c,
          borderRadius: BorderRadius.circular(3),
        ),
      ),
      const SizedBox(width: 6),
      Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
    ],
  );

  Widget _dashStatRow(String label, int own, int opp, Color ownC, Color oppC) {
    final total = own + opp;
    const numStyle = TextStyle(fontWeight: FontWeight.bold, fontSize: 16);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        children: [
          Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              SizedBox(
                width: 34,
                child: Text(
                  '$own',
                  textAlign: TextAlign.right,
                  style: numStyle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Row(
                    children: [
                      Expanded(
                        flex: total == 0 ? 1 : own,
                        child: Container(
                          height: 10,
                          color: total == 0
                              ? ownC.withValues(alpha: 0.2)
                              : ownC,
                        ),
                      ),
                      Expanded(
                        flex: total == 0 ? 1 : opp,
                        child: Container(
                          height: 10,
                          color: total == 0
                              ? oppC.withValues(alpha: 0.2)
                              : oppC,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 34,
                child: Text('$opp', textAlign: TextAlign.left, style: numStyle),
              ),
            ],
          ),
        ],
      ),
    );
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
    String noneLabel = 'Keine (ohne Vorlage)',
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
        noneLabel: noneLabel,
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
                    color: Colors.red,
                    shape: BoxShape.circle,
                  ),
                ),
              Text(
                phase == _Phase.finished ? 'Beendet' : clockText,
                style: TextStyle(
                  color: scheme.onPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.onPrimary.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  _minuteLabel,
                  style: TextStyle(
                    color: scheme.onPrimary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(child: _side(scheme, ownLogo, ownName)),
              Text(
                '${match.ownScore} : ${match.opponentScore}',
                style: TextStyle(
                  color: scheme.onPrimary,
                  fontSize: 34,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Expanded(child: _side(scheme, oppLogo, oppName)),
            ],
          ),
          // Elfmeterschießen oben mitzählen.
          if (showShootout) ...[
            const SizedBox(height: 4),
            Text(
              'Elfmeterschießen  $shootoutOwn : $shootoutOpp',
              style: TextStyle(
                color: scheme.onPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
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
        Text(
          name,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: scheme.onPrimary,
            fontWeight: FontWeight.bold,
          ),
        ),
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
      child: Row(
        children: [
          Expanded(child: a),
          const SizedBox(width: 8),
          Expanded(child: b),
        ],
      ),
    );

    final finishBtn = FilledButton.icon(
      style: FilledButton.styleFrom(backgroundColor: Colors.red),
      onPressed: onFinish,
      icon: const Icon(Icons.stop),
      label: const Text('Abpfiff'),
    );

    switch (phase) {
      case _Phase.notStarted:
        return full(
          FilledButton.icon(
            onPressed: onKickoff,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Anpfiff'),
          ),
        );
      case _Phase.firstHalf:
        return full(
          FilledButton.icon(
            onPressed: onHalftime,
            icon: const Icon(Icons.timer),
            label: const Text('Halbzeit'),
          ),
        );
      case _Phase.halftime:
        return full(
          FilledButton.icon(
            onPressed: onSecondHalf,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Anpfiff 2. Halbzeit'),
          ),
        );
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
        return full(
          FilledButton.icon(
            onPressed: onExtraHalftime,
            icon: const Icon(Icons.timer),
            label: const Text('Halbzeit Verlängerung'),
          ),
        );
      case _Phase.extraHalftime:
        return full(
          FilledButton.icon(
            onPressed: onExtraSecond,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Anpfiff 2. Verlängerung'),
          ),
        );
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
        return full(
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: onFinish,
            icon: const Icon(Icons.emoji_events),
            label: const Text('Spiel beenden'),
          ),
        );
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
    this.onSave,
    this.onEvent,
    this.enabled = true,
    this.isOwn = true,
  });

  final String label;
  final Color color;
  final VoidCallback onGoal;
  final VoidCallback? onCard;
  final VoidCallback? onSub;

  /// Torwart-Parade (TW-Button).
  final VoidCallback? onSave;

  /// Weitere Ereignisse (Ecke/Freistoß/Elfmeter/Foul/Großchance).
  final VoidCallback? onEvent;

  /// Nur nach Anpfiff aktiv.
  final bool enabled;

  /// Eigenes Team (true) vs. Gegner (false) – für die Unterscheidung.
  final bool isOwn;

  // Icon über Label – Text bleibt auch auf schmalen Handys lesbar.
  static final _actionStyle = ButtonStyle(
    padding: WidgetStateProperty.all(
      const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
    ),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );

  Widget _actionChild(Widget icon, String text) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      icon,
      const SizedBox(height: 2),
      Text(
        text,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.visible,
        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
      ),
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
                Icon(
                  isOwn ? Icons.home : Icons.flag_outlined,
                  size: 16,
                  color: color,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.bold, color: color),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    isOwn ? 'MEIN TEAM' : 'GEGNER',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
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
                      const Text('⚽', style: TextStyle(fontSize: 18)),
                      'Tor',
                    ),
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
                            const Icon(Icons.style, size: 20),
                            'Karte',
                          ),
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
                            const Icon(Icons.swap_horiz, size: 20),
                            'Wechsel',
                          ),
                        ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: onSave == null
                      ? const SizedBox.shrink()
                      : OutlinedButton(
                          onPressed: enabled ? onSave : null,
                          style: outStyle,
                          child: _actionChild(
                            const Icon(Icons.sports_handball, size: 20),
                            'TW',
                          ),
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
          child: Text(
            'Noch keine Ereignisse erfasst.',
            style: TextStyle(color: Colors.grey),
          ),
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
            child: Text(
              'Ticker',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ),
        ...reversed.map((e) {
          if (e.type.isPhaseMarker) return _phaseRow(context, e);
          final own = e.teamId == ownTeamId;
          // Zeigt der Avatar links ein Foto (Spieler/Wechsel), gehört das
          // Typ-Symbol wieder in den Titel. Nur ohne Spieler (Symbol-Kreis
          // links) würde es sonst doppelt erscheinen.
          final leadingIsPhoto =
              e.type == MatchEventType.substitution ||
              (e.type == MatchEventType.injuredOff &&
                  (resolvePlayer(e.playerId) != null ||
                      resolvePlayer(e.assistPlayerId) != null)) ||
              resolvePlayer(e.playerId) != null;
          // Chat-Stil: eigene Aktionen links, Gegner rechts gespiegelt. So sind
          // beide Seiten auf einen Blick unterscheidbar. Neutral (Kommentar)
          // bleibt links.
          final rightSide = !e.type.isNeutral && !own;
          const titleStyle = TextStyle(
            fontWeight: FontWeight.w500,
            height: 1.2,
          );
          final describe = _describe(e);
          // „Verletzt raus": rotes Kreuz im Text (statt 🚑). Behandlung bleibt.
          final Widget title = e.type == MatchEventType.injuredOff
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: rightSide
                      ? [
                          Flexible(
                            child: Text(
                              describe,
                              textAlign: TextAlign.right,
                              style: titleStyle,
                            ),
                          ),
                          const SizedBox(width: 5),
                          const InjuryCross(size: 15),
                        ]
                      : [
                          const InjuryCross(size: 15),
                          const SizedBox(width: 5),
                          Flexible(child: Text(describe, style: titleStyle)),
                        ],
                )
              : Text(
                  leadingIsPhoto ? '${e.type.symbol} $describe' : describe,
                  textAlign: rightSide ? TextAlign.right : TextAlign.left,
                  style: titleStyle,
                );
          final textCol = Expanded(
            child: Column(
              crossAxisAlignment: rightSide
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [title, ..._subtitleLine(context, e, rightSide)],
            ),
          );
          final editIcon = _readOnly
              ? null
              : IconButton(
                  tooltip: 'Korrigieren',
                  icon: const Icon(Icons.more_vert),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => onEdit!(e),
                );
          final minute = _MinuteBadge(label: _minuteLabel(e), own: own);
          final avatar = _eventAvatar(context, e, own);
          final content = Padding(
            padding: EdgeInsets.fromLTRB(
              rightSide ? 4 : 16,
              8,
              rightSide ? 16 : 4,
              8,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: rightSide
                  ? [
                      ?editIcon,
                      textCol,
                      const SizedBox(width: 10),
                      avatar,
                      const SizedBox(width: 10),
                      minute,
                    ]
                  : [
                      minute,
                      const SizedBox(width: 10),
                      avatar,
                      const SizedBox(width: 10),
                      textCol,
                      ?editIcon,
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
            child: InkWell(onTap: () => onEdit!(e), child: content),
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
              child: Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
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
        if (e.playerId == null && e.assistPlayerId == null) return 'Wechsel';
        return 'Wechsel – ${resolveName(e.playerId)} für ${resolveName(e.assistPlayerId)}';
      case MatchEventType.injuredOff:
        final off = e.assistPlayerId == null
            ? ''
            : ' – ${resolveName(e.assistPlayerId)}';
        if (e.playerId != null) {
          return 'Verletzt raus$off (Ersatz: ${resolveName(e.playerId)})';
        }
        return 'Verletzt raus$off (ohne Einwechslung)';
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
      case MatchEventType.save:
      case MatchEventType.shot:
      case MatchEventType.longShot:
      case MatchEventType.header:
      case MatchEventType.injury:
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
  List<Widget> _subtitleLine(
    BuildContext context,
    MatchEvent e,
    bool rightSide,
  ) {
    // Die Seite (links/rechts) zeigt bereits das Team – nur noch die Notiz.
    final note = e.note?.trim();
    if (e.type == MatchEventType.comment || note == null || note.isEmpty) {
      return const [];
    }
    return [
      Text(
        note,
        textAlign: rightSide ? TextAlign.right : TextAlign.left,
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.outline,
        ),
      ),
    ];
  }

  /// Spielerfoto(s) für die Ticker-Zeile. Beim Wechsel beide Spieler mit
  /// Pfeil (rein/raus) wie im FuPa-Ticker; sonst das Foto des Spielers.
  Widget _eventAvatar(BuildContext context, MatchEvent e, bool own) {
    const r = 18.0;
    final inP = resolvePlayer(e.playerId);
    final outP = resolvePlayer(e.assistPlayerId);
    if (e.type == MatchEventType.substitution) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _avatarWithArrow(outP, Icons.arrow_downward, Colors.red),
          const SizedBox(width: 3),
          _avatarWithArrow(inP, Icons.arrow_upward, Colors.green),
        ],
      );
    }
    // „Verletzt raus": Verletzter runter (rot), Ersatz rauf (grün, falls da).
    if (e.type == MatchEventType.injuredOff && (outP != null || inP != null)) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (outP != null)
            _avatarWithArrow(outP, Icons.arrow_downward, Colors.red),
          if (inP != null) ...[
            const SizedBox(width: 3),
            _avatarWithArrow(inP, Icons.arrow_upward, Colors.green),
          ],
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
      children: [
        avatar,
        Icon(arrow, size: 13, color: color),
      ],
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
    final res = await showPlayerPickSheet(
      context,
      widget.players,
      selected: _selPlayer,
    );
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
                  Text(
                    'Spieler:',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
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
                              onDeleted: () =>
                                  setState(() => _selPlayer = null),
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
                  hintText: isComment
                      ? 'Was passiert gerade?'
                      : 'Notiz zum Ereignis …',
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
Future<String?> showPlayerPickSheet(
  BuildContext context,
  List<Player> players, {
  String? selected,
}) {
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
              child: Text(
                'Spieler wählen',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
              ),
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
                      radius: 20,
                      child: Icon(Icons.block),
                    ),
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
                      subtitle: Text(
                        [
                          if (p.number != null) 'Nr. ${p.number}',
                          if (p.position != null) p.position!,
                        ].join('  ·  '),
                      ),
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
    this.noneLabel = 'Keine (ohne Vorlage)',
  });

  final String title;
  final List<Player> players;
  final bool allowUnknown;
  final bool allowNone;
  final String unknownValue;
  final String noneValue;
  final String noneLabel;

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
              child: Text(
                title,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
              ),
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
                      subtitle: Text(
                        [
                          if (p.number != null) 'Nr. ${p.number}',
                          if (p.position != null) p.position!,
                        ].join('  ·  '),
                      ),
                      onTap: () => Navigator.pop(context, p.id),
                    ),
                  if (allowUnknown)
                    ListTile(
                      leading: const CircleAvatar(
                        child: Icon(Icons.help_outline),
                      ),
                      title: const Text('Unbekannt'),
                      onTap: () => Navigator.pop(context, unknownValue),
                    ),
                  if (allowNone)
                    ListTile(
                      leading: const CircleAvatar(child: Icon(Icons.block)),
                      title: Text(noneLabel),
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
    final availOff = widget.onField
        .where((p) => !usedOff.contains(p.id))
        .toList();
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
                  Text(
                    'Wechsel',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  if (_pairs.isNotEmpty)
                    Text(
                      '${_pairs.length} geplant',
                      style: TextStyle(
                        color: scheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
            ),
            // Geplante Paare
            if (_pairs.isNotEmpty) ...[
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
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
                          onPressed: () => setState(() => _pendingOff = null),
                          child: const Text('Zurück'),
                        ),
                      ],
                    )
                  : const Text(
                      'Wer geht raus? (Feldspieler antippen)',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
            ),
            // Auswahlliste
            Flexible(
              child: candidates.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        selectingIn
                            ? 'Keine Spieler mehr auf der Bank.'
                            : 'Keine Feldspieler mehr verfügbar.',
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.only(bottom: 8),
                      children: [
                        for (final p in candidates)
                          ListTile(
                            leading: PlayerAvatar(player: p),
                            title: Text(p.fullName),
                            subtitle: Text(
                              [
                                if (p.number != null) 'Nr. ${p.number}',
                                if (p.position != null) p.position!,
                              ].join('  ·  '),
                            ),
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
                  label: Text(
                    _pairs.length <= 1
                        ? 'Wechsel bestätigen'
                        : '${_pairs.length} Wechsel bestätigen',
                  ),
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
            child: Text(off.displayName, overflow: TextOverflow.ellipsis),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4),
            child: Icon(Icons.arrow_forward, size: 16),
          ),
          const Icon(Icons.login, size: 16, color: Colors.green),
          const SizedBox(width: 4),
          Expanded(
            child: Text(on.displayName, overflow: TextOverflow.ellipsis),
          ),
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
