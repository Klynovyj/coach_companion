import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';

import '../models/enums.dart';
import '../models/match_event.dart';
import '../models/team.dart';
import '../services/share_service.dart';
import '../state/app_state.dart';
import '../widgets/stat_compare_row.dart';
import '../widgets/team_logo.dart';

/// Saison-Gesamtstatistik des eigenen Teams: alle live erfassten Aktionen über
/// alle Spiele als Summen, im Vergleich Wir vs. Gegner. Teilbar per WhatsApp.
class SeasonStatsScreen extends StatefulWidget {
  const SeasonStatsScreen({super.key, this.embedded = false});

  /// Eingebettet (Statistik-Hub): ohne eigenes Scaffold/AppBar; Teilen-Button
  /// erscheint dann in der Kopfzeile des Inhalts.
  final bool embedded;

  @override
  State<SeasonStatsScreen> createState() => _SeasonStatsScreenState();
}

class _SeasonStatsScreenState extends State<SeasonStatsScreen> {
  static const _oppColor = Color(0xFFB26A00);

  // Aktionen (Label → Ereignistypen) – wie im Spiel-Dashboard.
  static const _rows = <(String, Set<MatchEventType>)>[
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

  final GlobalKey _statsKey = GlobalKey();
  List<MatchEvent> _events = [];
  // Nur wirklich live getrackte Spiele: solche mit mindestens einer Phasen-
  // Marke (Anpfiff/Halbzeit/Abpfiff …). Spiele mit nur vereinzelten Rest-/
  // Altdaten (z.B. ein paar Tore ohne Anpfiff) zählen nicht mit.
  Set<String> _trackedMatchIds = {};
  // Tore aus dem gecachten (kanonischen) Spielstand der getrackten Spiele –
  // identisch zum Match-Center. Nicht aus Ereignissen neu gezählt, damit die
  // Gesamtstatistik nicht durch verwaiste/doppelte Tor-Ereignisse abweicht.
  int _goalsOwn = 0;
  int _goalsOpp = 0;
  Team? _team;
  bool _loading = true;

  int _half = 0; // 0 = gesamt, 1 = 1. HZ, 2 = 2. HZ
  // Je Spiel: (Anpfiff 2. HZ, Halbzeit) als Zeitmarken für die HZ-Zuordnung.
  final Map<String, (DateTime?, DateTime?)> _halfMarks = {};

  String get _halfLabel => _half == 1
      ? '1. Halbzeit'
      : _half == 2
      ? '2. Halbzeit'
      : 'Gesamt';

  static const _goalTypes = {MatchEventType.goal, MatchEventType.penalty};

  /// Halbzeit eines Ereignisses (je Spiel): 1 = 1. HZ, 2 = 2. HZ. Über die
  /// Phasen-Marken des Spiels, sonst Rückfall über die Spielminute.
  int _halfOf(MatchEvent e) {
    final mk = _halfMarks[e.matchId];
    final secondStart = mk?.$1;
    if (secondStart != null) return e.createdAt.isBefore(secondStart) ? 1 : 2;
    final halftime = mk?.$2;
    if (halftime != null) return e.createdAt.isAfter(halftime) ? 2 : 1;
    return e.minute <= 45 ? 1 : 2;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    final events = await state.allEvents();
    if (!mounted) return;
    final tracked = events
        .where((e) => e.type.isPhaseMarker)
        .map((e) => e.matchId)
        .toSet();
    // Je Spiel die (frühesten) HZ-Marken merken.
    _halfMarks.clear();
    for (final e in events) {
      if (e.type == MatchEventType.secondHalfStart) {
        final cur = _halfMarks[e.matchId];
        if (cur?.$1 == null || e.createdAt.isBefore(cur!.$1!)) {
          _halfMarks[e.matchId] = (e.createdAt, cur?.$2);
        }
      } else if (e.type == MatchEventType.halftime) {
        final cur = _halfMarks[e.matchId];
        if (cur?.$2 == null || e.createdAt.isBefore(cur!.$2!)) {
          _halfMarks[e.matchId] = (cur?.$1, e.createdAt);
        }
      }
    }
    var gOwn = 0;
    var gOpp = 0;
    for (final m in state.matches) {
      if (tracked.contains(m.id)) {
        gOwn += m.ownScore;
        gOpp += m.opponentScore;
      }
    }
    setState(() {
      _events = events;
      _trackedMatchIds = tracked;
      _goalsOwn = gOwn;
      _goalsOpp = gOpp;
      _team = state.ownTeam;
      _loading = false;
    });
  }

  String? get _ownTeamId => _team?.id;

  int _count(bool own, Set<MatchEventType> types) => _events
      .where(
        (e) =>
            _trackedMatchIds.contains(e.matchId) &&
            types.contains(e.type) &&
            (own ? e.teamId == _ownTeamId : e.teamId != _ownTeamId) &&
            (_half == 0 || _halfOf(e) == _half),
      )
      .length;

  int get _matchCount => _trackedMatchIds.length;

  void _snack(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  /// Teilt die Gesamtstatistik als Bild (RepaintBoundary → PNG → WhatsApp).
  Future<void> _share() async {
    final name = _team?.shortName ?? _team?.name ?? 'Team';
    try {
      final b =
          _statsKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (b == null) return;
      final image = await b.toImage(pixelRatio: 2.5);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return;
      final suffix = _half == 0 ? '' : '_${_half}HZ';
      final path = await shareOrSaveImage(
        data.buffer.asUint8List(),
        'Gesamtstatistik_$name$suffix',
        text: 'Gesamtstatistik ($_halfLabel) – $name',
      );
      if (path != null) _snack('Als Bild gespeichert:\n$path');
    } catch (e) {
      _snack('Teilen fehlgeschlagen: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = _team?.name ?? 'Eigenes Team';
    // Tore: gesamt aus dem kanonischen Spielstand, je Halbzeit aus Ereignissen.
    final ownGoals = _half == 0 ? _goalsOwn : _count(true, _goalTypes);
    final oppGoals = _half == 0 ? _goalsOpp : _count(false, _goalTypes);
    final body = _loading
        ? const Center(child: CircularProgressIndicator())
        : Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
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
                        selected: {_half},
                        onSelectionChanged: (s) =>
                            setState(() => _half = s.first),
                      ),
                    ),
                    if (widget.embedded)
                      IconButton(
                        tooltip: 'Teilen (WhatsApp)',
                        icon: const Icon(Icons.share),
                        onPressed: _loading ? null : _share,
                      ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  child: RepaintBoundary(
                    key: _statsKey,
                    child: Container(
                      color: scheme.surface,
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Column(
                            children: [
                              if (_team?.logoPath != null) ...[
                                TeamLogo(logoPath: _team!.logoPath, size: 48),
                                const SizedBox(height: 6),
                              ],
                              Text(
                                name,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 18,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '$_matchCount Spiele erfasst',
                                style: TextStyle(
                                  color: Theme.of(context).hintColor,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Tore  $ownGoals : $oppGoals',
                                style: const TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              if (_half != 0)
                                Text(
                                  _halfLabel,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    color: scheme.primary,
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              _legend('Wir', scheme.primary),
                              _legend('Gegner', _oppColor),
                            ],
                          ),
                          const Divider(height: 20),
                          if (_matchCount == 0)
                            Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(
                                'Noch keine live erfassten Aktionen. Starte ein Spiel im '
                                'Live-Modus – die Summen erscheinen hier automatisch.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Theme.of(context).hintColor,
                                ),
                              ),
                            )
                          else
                            for (final r in _rows)
                              StatCompareRow(
                                label: r.$1,
                                // „Tore" aus dem (ggf. HZ-gefilterten) Stand, Rest aus Ereignissen.
                                own: r.$1 == 'Tore'
                                    ? ownGoals
                                    : _count(true, r.$2),
                                opp: r.$1 == 'Tore'
                                    ? oppGoals
                                    : _count(false, r.$2),
                                ownColor: scheme.primary,
                                oppColor: _oppColor,
                              ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Gesamtstatistik'),
        actions: [
          IconButton(
            tooltip: 'Teilen (WhatsApp)',
            icon: const Icon(Icons.share),
            onPressed: _loading ? null : _share,
          ),
        ],
      ),
      body: body,
    );
  }

  Widget _legend(String label, Color c) => Row(
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
}
