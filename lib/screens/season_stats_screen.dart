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
  const SeasonStatsScreen({super.key});

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
    ('Elfmeter', {
      MatchEventType.penalty,
      MatchEventType.penaltyMissed,
      MatchEventType.penaltySaved,
    }),
    ('Ecken', {MatchEventType.corner}),
    ('Freistöße', {MatchEventType.freeKick}),
    ('Fouls', {MatchEventType.foul}),
    ('Gelbe Karten', {MatchEventType.yellowCard}),
    ('Gelb-Rote Karten', {MatchEventType.secondYellow}),
    ('Rote Karten', {MatchEventType.redCard}),
    ('Paraden', {MatchEventType.save}),
    ('Meckern', {MatchEventType.meckern}),
    ('Verletzungen', {MatchEventType.injury}),
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
      .where((e) =>
          _trackedMatchIds.contains(e.matchId) &&
          types.contains(e.type) &&
          (own ? e.teamId == _ownTeamId : e.teamId != _ownTeamId))
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
          _statsKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (b == null) return;
      final image = await b.toImage(pixelRatio: 2.5);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return;
      final path = await shareOrSaveImage(
        data.buffer.asUint8List(),
        'Gesamtstatistik_$name',
        text: 'Gesamtstatistik – $name',
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
    final ownGoals = _goalsOwn;
    final oppGoals = _goalsOpp;
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
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
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
                    Text(name,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 18)),
                    const SizedBox(height: 2),
                    Text('$_matchCount Spiele erfasst',
                        style: TextStyle(color: Theme.of(context).hintColor)),
                    const SizedBox(height: 8),
                    Text('Tore  $ownGoals : $oppGoals',
                        style: const TextStyle(
                            fontSize: 24, fontWeight: FontWeight.bold)),
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
                      style: TextStyle(color: Theme.of(context).hintColor),
                    ),
                  )
                else
                  for (final r in _rows)
                    StatCompareRow(
                      label: r.$1,
                      // „Tore" aus dem kanonischen Spielstand, Rest aus Ereignissen.
                      own: r.$1 == 'Tore' ? _goalsOwn : _count(true, r.$2),
                      opp: r.$1 == 'Tore' ? _goalsOpp : _count(false, r.$2),
                      ownColor: scheme.primary,
                      oppColor: _oppColor,
                    ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  Widget _legend(String label, Color c) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 12,
            height: 12,
            decoration:
                BoxDecoration(color: c, borderRadius: BorderRadius.circular(3)),
          ),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      );
}
