import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/player_stat.dart';
import '../services/fupa/fupa_dtos.dart';
import '../state/app_state.dart';

enum _SortKey { goals, assists, matches, minutes, name }

class StatsScreen extends StatefulWidget {
  const StatsScreen({
    super.key,
    required this.teamId,
    required this.teamName,
    this.fupaUrl,
  });

  final String teamId;
  final String teamName;
  final String? fupaUrl;

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  _SortKey _sort = _SortKey.goals;
  bool _showTable = false; // false = Spieler-Statistik, true = Liga-Tabelle

  List<PlayerStat> _sorted(List<PlayerStat> stats) {
    final list = [...stats];
    switch (_sort) {
      case _SortKey.goals:
        list.sort((a, b) => b.goals != a.goals
            ? b.goals.compareTo(a.goals)
            : b.assists.compareTo(a.assists));
      case _SortKey.assists:
        list.sort((a, b) => b.assists.compareTo(a.assists));
      case _SortKey.matches:
        list.sort((a, b) => b.matches.compareTo(a.matches));
      case _SortKey.minutes:
        list.sort((a, b) => b.minutes.compareTo(a.minutes));
      case _SortKey.name:
        list.sort((a, b) => a.lastName
            .toLowerCase()
            .compareTo(b.lastName.toLowerCase()));
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: Text('Statistik · ${widget.teamName}'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                    value: false,
                    label: Text('Spieler'),
                    icon: Icon(Icons.groups)),
                ButtonSegment(
                    value: true,
                    label: Text('Tabelle'),
                    icon: Icon(Icons.table_chart)),
              ],
              selected: {_showTable},
              onSelectionChanged: (s) => setState(() => _showTable = s.first),
            ),
          ),
          Expanded(
            child: _showTable ? _standingsView(state) : _playersView(state),
          ),
        ],
      ),
    );
  }

  Widget _playersView(AppState state) {
    return FutureBuilder<List<PlayerStat>>(
      future: state.statsOf(widget.teamId),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final stats = snap.data!;
        if (stats.isEmpty) {
          return _empty();
        }
        return Column(
          children: [
            _sortBar(),
            Expanded(child: _table(_sorted(stats))),
          ],
        );
      },
    );
  }

  Widget _standingsView(AppState state) {
    return FutureBuilder<(StandingRow?, List<StandingRow>)>(
      future: state.leagueTable(widget.teamId),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final (ours, table) = snap.data!;
        if (table.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.table_chart, size: 48, color: Colors.grey),
                  SizedBox(height: 12),
                  Text(
                    'Keine Liga-Tabelle verfügbar.\n'
                    'Prüfe den FuPa-Teamlink in den Einstellungen und '
                    'synchronisiere den Spielplan.',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          );
        }
        return _standingsTable(table, ours);
      },
    );
  }

  Widget _sortBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          const Text('Sortieren: '),
          const SizedBox(width: 8),
          DropdownButton<_SortKey>(
            value: _sort,
            onChanged: (v) => setState(() => _sort = v ?? _sort),
            items: const [
              DropdownMenuItem(value: _SortKey.goals, child: Text('Tore')),
              DropdownMenuItem(value: _SortKey.assists, child: Text('Vorlagen')),
              DropdownMenuItem(value: _SortKey.matches, child: Text('Spiele')),
              DropdownMenuItem(value: _SortKey.minutes, child: Text('Minuten')),
              DropdownMenuItem(value: _SortKey.name, child: Text('Name')),
            ],
          ),
        ],
      ),
    );
  }

  // Kompakte, bildschirmfüllende Tabelle (passt auch auf dem Handy, ohne
  // horizontales Scrollen). Spalten: Sp · Tore · Vorlagen · Gelb · Rot · Top11.
  static const _numW = 30.0;

  Widget _num(String t, {bool header = false, Color? color}) => SizedBox(
        width: _numW,
        child: Text(t,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.clip,
            style: TextStyle(
                fontWeight: header ? FontWeight.bold : FontWeight.w600,
                color: color)),
      );

  Widget _table(List<PlayerStat> stats) {
    return Column(
      children: [
        // Kopfzeile
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 12, 6),
          child: Row(
            children: [
              const Expanded(
                  child: Text('Spieler',
                      style: TextStyle(fontWeight: FontWeight.bold))),
              _num('Sp', header: true),
              _num('⚽', header: true),
              _num('🅰', header: true),
              _num('🟨', header: true),
              _num('🟥', header: true),
              _num('⭐', header: true),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.separated(
            itemCount: stats.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final s = stats[i];
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('${i + 1}. ${s.fullName}',
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                    _num('${s.matches}'),
                    _num('${s.goals}'),
                    _num('${s.assists}'),
                    _num('${s.yellowCards}'),
                    _num('${s.yellowRedCards + s.redCards}'),
                    _num('${s.topEleven}'),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  static Widget _sCell(String t, double w,
          {bool header = false, Color? color, FontWeight? weight}) =>
      SizedBox(
        width: w,
        child: Text(t,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.clip,
            style: TextStyle(
                fontWeight: weight ?? (header ? FontWeight.bold : FontWeight.w600),
                color: color)),
      );

  // Liga-Tabelle: Platz · Team · Spiele · Tore · Differenz · Punkte.
  // Unsere Zeile ist hervorgehoben.
  Widget _standingsTable(List<StandingRow> table, StandingRow? ours) {
    final scheme = Theme.of(context).colorScheme;
    final ourSlug = ours?.teamSlug ?? '';
    return Column(
      children: [
        if (ours != null)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              'Platz ${ours.rank} von ${ours.totalTeams}  ·  ${ours.points} Punkte  ·  ${ours.goalDiff > 0 ? '+' : ''}${ours.goalDiff} Tore',
              style: TextStyle(
                  fontWeight: FontWeight.bold, color: scheme.primary),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
          child: Row(
            children: [
              _sCell('#', 26, header: true),
              const Expanded(
                  child: Text('Team',
                      style: TextStyle(fontWeight: FontWeight.bold))),
              _sCell('Sp', 26, header: true),
              _sCell('Tore', 46, header: true),
              _sCell('Diff', 36, header: true),
              _sCell('Pkt', 32, header: true),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.separated(
            itemCount: table.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final r = table[i];
              final isOurs = ourSlug.isNotEmpty && r.teamSlug == ourSlug;
              return Container(
                color: isOurs ? scheme.primary.withValues(alpha: 0.12) : null,
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: Row(
                  children: [
                    _sCell('${r.rank}', 26,
                        weight: isOurs ? FontWeight.bold : null),
                    Expanded(
                      child: Text(r.teamName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontWeight:
                                  isOurs ? FontWeight.bold : FontWeight.w500)),
                    ),
                    _sCell('${r.matches}', 26),
                    _sCell('${r.goalsFor}:${r.goalsAgainst}', 46),
                    _sCell(r.goalDiff > 0 ? '+${r.goalDiff}' : '${r.goalDiff}', 36),
                    _sCell('${r.points}', 32,
                        weight: isOurs ? FontWeight.bold : FontWeight.w700),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _empty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.bar_chart, size: 48, color: Colors.grey),
            const SizedBox(height: 12),
            const Text(
              'Noch keine Statistik.\nSie wird automatisch aus FuPa aktualisiert.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
