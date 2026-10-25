import 'package:flutter/material.dart';
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

  List<MatchEvent> _events = [];
  // Nur wirklich live getrackte Spiele: solche mit mindestens einer Phasen-
  // Marke (Anpfiff/Halbzeit/Abpfiff …). Spiele mit nur vereinzelten Rest-/
  // Altdaten (z.B. ein paar Tore ohne Anpfiff) zählen nicht mit.
  Set<String> _trackedMatchIds = {};
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
    setState(() {
      _events = events;
      _trackedMatchIds = events
          .where((e) => e.type.isPhaseMarker)
          .map((e) => e.matchId)
          .toSet();
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

  Future<void> _share() async {
    final name = _team?.shortName ?? _team?.name ?? 'Wir';
    final b = StringBuffer();
    b.writeln('📊 Saison-Statistik');
    b.writeln('$name – $_matchCount Spiele');
    b.writeln('(Wir : Gegner)');
    b.writeln();
    for (final r in _rows) {
      final o = _count(true, r.$2), g = _count(false, r.$2);
      if (o == 0 && g == 0) continue;
      b.writeln('${r.$1}: $o : $g');
    }
    final ok = await shareText(b.toString().trim());
    if (!ok && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Teilen nicht möglich.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = _team?.name ?? 'Eigenes Team';
    final ownGoals = _count(true, {MatchEventType.goal, MatchEventType.penalty});
    final oppGoals =
        _count(false, {MatchEventType.goal, MatchEventType.penalty});
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
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
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
                      own: _count(true, r.$2),
                      opp: _count(false, r.$2),
                      ownColor: scheme.primary,
                      oppColor: _oppColor,
                    ),
              ],
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
