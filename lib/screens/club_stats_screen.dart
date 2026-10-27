import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/fupa/fupa_dtos.dart';
import '../state/app_state.dart';
import '../widgets/player_avatar.dart';

enum _Mode { all, pflicht }

enum _ClubSort { games, goals, assists, scorer, minutes, name }

/// Vereins-Bilanz aller Spieler aus der FuPa-Laufbahn: Spiele/Tore/Vorlagen/
/// Scorer beim aktuellen Verein (umschaltbar gesamt / nur Pflichtspiele) plus
/// Saison-Minuten. Pro Spieler ein FuPa-Abruf beim Öffnen.
class ClubStatsScreen extends StatefulWidget {
  const ClubStatsScreen({super.key});

  @override
  State<ClubStatsScreen> createState() => _ClubStatsScreenState();
}

class _ClubStatsScreenState extends State<ClubStatsScreen> {
  _Mode _mode = _Mode.all;
  _ClubSort _sort = _ClubSort.scorer;
  List<PlayerClubStats> _rows = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    final team = state.ownTeam;
    if (team == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final rows = await state.squadFupaClubStats(team.id);
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _loading = false;
    });
  }

  FupaClubTotal _t(PlayerClubStats r) => _mode == _Mode.all ? r.all : r.pflicht;

  List<PlayerClubStats> _sorted() {
    final list = [..._rows];
    int cmp(PlayerClubStats a, PlayerClubStats b) {
      switch (_sort) {
        case _ClubSort.games:
          return _t(b).matches.compareTo(_t(a).matches);
        case _ClubSort.goals:
          return _t(b).goals.compareTo(_t(a).goals);
        case _ClubSort.assists:
          return _t(b).assists.compareTo(_t(a).assists);
        case _ClubSort.scorer:
          return _t(b).scorerPoints.compareTo(_t(a).scorerPoints);
        case _ClubSort.minutes:
          return b.seasonMinutes.compareTo(a.seasonMinutes);
        case _ClubSort.name:
          return a.player.fullName.toLowerCase().compareTo(
            b.player.fullName.toLowerCase(),
          );
      }
    }

    list.sort(cmp);
    return list;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Vereins-Bilanz (FuPa)')),
      body: _loading
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 12),
                  Text('FuPa-Laufbahn aller Spieler wird geladen …'),
                ],
              ),
            )
          : _rows.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('Keine Spieler.', textAlign: TextAlign.center),
              ),
            )
          : Column(
              children: [
                _controls(),
                const Divider(height: 1),
                _headerRow(),
                const Divider(height: 1),
                Expanded(
                  child: ListView.separated(
                    itemCount: _sorted().length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) => _row(_sorted()[i], i),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _controls() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: SegmentedButton<_Mode>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                  segments: const [
                    ButtonSegment(value: _Mode.all, label: Text('Gesamt')),
                    ButtonSegment(
                      value: _Mode.pflicht,
                      label: Text('Nur Pflicht'),
                    ),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (s) => setState(() => _mode = s.first),
                ),
              ),
              const SizedBox(width: 8),
              DropdownButton<_ClubSort>(
                value: _sort,
                onChanged: (v) => setState(() => _sort = v ?? _sort),
                items: const [
                  DropdownMenuItem(
                    value: _ClubSort.scorer,
                    child: Text('Scorer'),
                  ),
                  DropdownMenuItem(
                    value: _ClubSort.games,
                    child: Text('Spiele'),
                  ),
                  DropdownMenuItem(value: _ClubSort.goals, child: Text('Tore')),
                  DropdownMenuItem(
                    value: _ClubSort.assists,
                    child: Text('Vorlagen'),
                  ),
                  DropdownMenuItem(
                    value: _ClubSort.minutes,
                    child: Text('Minuten'),
                  ),
                  DropdownMenuItem(value: _ClubSort.name, child: Text('Name')),
                ],
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '${_mode == _Mode.all ? 'Alle Spiele (inkl. Freundschaft/Test)' : 'Nur Pflichtspiele (Liga + Pokal)'} '
              '· Min = nur laufende Saison',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  static const _w = 34.0;

  Widget _num(String t, {bool header = false, Color? color}) => SizedBox(
    width: _w,
    child: Text(
      t,
      textAlign: TextAlign.center,
      maxLines: 1,
      style: TextStyle(
        fontSize: header ? 12 : 13,
        fontWeight: header ? FontWeight.bold : FontWeight.w600,
        color: color,
      ),
    ),
  );

  Widget _headerRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Row(
        children: [
          const SizedBox(width: 26),
          const Expanded(
            child: Text(
              'Spieler',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
            ),
          ),
          _num('Sp', header: true),
          _num('⚽', header: true),
          _num('🅰', header: true),
          _num('Scr', header: true),
          _num('Min', header: true),
        ],
      ),
    );
  }

  Widget _row(PlayerClubStats r, int index) {
    final t = _t(r);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        children: [
          SizedBox(
            width: 26,
            child: PlayerAvatar(player: r.player, radius: 13),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  r.player.fullName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if (!r.hasFupa)
                  Text(
                    'keine FuPa-Daten',
                    style: TextStyle(fontSize: 10, color: scheme.error),
                  ),
              ],
            ),
          ),
          _num('${t.matches}'),
          _num('${t.goals}'),
          _num('${t.assists}'),
          _num('${t.scorerPoints}', color: scheme.primary),
          _num(r.seasonMinutes > 0 ? '${r.seasonMinutes}' : '–'),
        ],
      ),
    );
  }
}
