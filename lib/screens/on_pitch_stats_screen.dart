import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/enums.dart';
import '../models/match_event.dart';
import '../models/player.dart';
import '../services/on_pitch_stats.dart';
import '../state/app_state.dart';
import '../widgets/player_avatar.dart';

/// Statistik „Auf dem Feld": Spieler auswählen und sehen, ob sie bei unseren
/// Toren bzw. Gegentoren auf dem Platz standen. Grundlage: Startelf der
/// Aufstellung + live erfasste Wechsel, Platzverweise und Tore.
class OnPitchStatsScreen extends StatefulWidget {
  const OnPitchStatsScreen({super.key});

  @override
  State<OnPitchStatsScreen> createState() => _OnPitchStatsScreenState();
}

class _OnPitchStatsScreenState extends State<OnPitchStatsScreen> {
  static const _green = Color(0xFF2E7D32);
  static const _red = Color(0xFFC62828);

  bool _loading = true;
  String? _teamId;
  List<Player> _squad = [];
  Map<String, Player> _byId = {};
  List<OnPitchMatch> _matches = [];
  List<String> _selected = [];

  String get _prefKey => 'on_pitch_selected_${_teamId ?? ''}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final app = context.read<AppState>();
    final team = app.ownTeam;
    if (team == null) {
      setState(() => _loading = false);
      return;
    }
    final players = await app.playersOf(team.id);
    final events = await app.allEvents();
    final byMatch = <String, List<MatchEvent>>{};
    for (final e in events) {
      (byMatch[e.matchId] ??= []).add(e);
    }
    final candidates =
        app.matches
            .where(
              (m) => m.ownTeamId == team.id && m.status == MatchStatus.finished,
            )
            .toList()
          ..sort(
            (a, b) =>
                (b.kickoff ?? b.createdAt).compareTo(a.kickoff ?? a.createdAt),
          );
    final analyzed = <OnPitchMatch>[];
    for (final m in candidates) {
      final lineup = await app.repository.getReleasedLineup(m.id, team.id);
      if (lineup == null) continue;
      final entries = await app.lineupEntries(lineup.id);
      final starters = {
        for (final e in entries)
          if (e.role == LineupRole.starter) e.playerId,
      };
      if (starters.isEmpty) continue;
      analyzed.add(analyzeOnPitch(m, byMatch[m.id] ?? const [], starters));
    }
    List<String> saved = [];
    try {
      final prefs = await SharedPreferences.getInstance();
      saved = prefs.getStringList('on_pitch_selected_${team.id}') ?? [];
    } catch (_) {}
    if (!mounted) return;
    final squad = players.where((p) => !p.isStaffOnly).toList()
      ..sort((a, b) {
        final na = a.number ?? 999, nb = b.number ?? 999;
        if (na != nb) return na.compareTo(nb);
        return a.fullName.compareTo(b.fullName);
      });
    setState(() {
      _teamId = team.id;
      _squad = squad;
      _byId = {for (final p in players) p.id: p};
      _matches = analyzed;
      _selected = saved.where(_byId.containsKey).toList();
      _loading = false;
    });
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_prefKey, _selected);
    } catch (_) {}
  }

  Future<void> _pick() async {
    final chosen = {..._selected};
    final games = {
      for (final p in _squad)
        p.id: _matches.where((m) => m.played(p.id)).length,
    };
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.8,
        maxChildSize: 0.95,
        builder: (ctx, scroll) => StatefulBuilder(
          builder: (ctx, setSheet) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Spieler auswählen',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => setSheet(chosen.clear),
                      child: const Text('Keine'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Fertig'),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  controller: scroll,
                  children: [
                    for (final p in _squad)
                      CheckboxListTile(
                        value: chosen.contains(p.id),
                        onChanged: (v) => setSheet(() {
                          if (v == true) {
                            chosen.add(p.id);
                          } else {
                            chosen.remove(p.id);
                          }
                        }),
                        secondary: PlayerAvatar(player: p, radius: 18),
                        title: Text(p.displayName),
                        subtitle: Text(
                          games[p.id] == 0
                              ? 'in keinem ausgewerteten Spiel'
                              : '${games[p.id]} '
                                    '${games[p.id] == 1 ? 'Spiel' : 'Spiele'}'
                                    '${p.position != null ? ' · ${p.position}' : ''}',
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      // Reihenfolge: bisher gewählte zuerst, neue nach Kader-Reihenfolge.
      _selected = [
        for (final id in _selected)
          if (chosen.contains(id)) id,
        for (final p in _squad)
          if (chosen.contains(p.id) && !_selected.contains(p.id)) p.id,
      ];
    });
    await _save();
  }

  void _remove(String id) {
    setState(() => _selected.remove(id));
    _save();
  }

  String _name(String? id) {
    if (id == null) return '';
    final p = _byId[id];
    return p == null ? '' : p.fullName;
  }

  String _num(double? v) =>
      v == null ? '–' : NumberFormat('0.0', 'de').format(v);

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_teamId == null) {
      return const Center(child: Text('Keine Mannschaft.'));
    }
    final hint = Theme.of(context).hintColor;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          Text(
            'Wer stand auf dem Feld, als wir Tore geschossen oder kassiert '
            'haben?',
            style: TextStyle(color: hint),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.tonalIcon(
                onPressed: _squad.isEmpty ? null : _pick,
                icon: const Icon(Icons.person_search, size: 18),
                label: const Text('Spieler auswählen'),
              ),
              for (final id in _selected)
                InputChip(
                  avatar: _byId[id] == null
                      ? null
                      : PlayerAvatar(player: _byId[id]!, radius: 12),
                  label: Text(_byId[id]?.pitchName ?? id),
                  onDeleted: () => _remove(id),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (_matches.isEmpty)
            _infoCard(
              'Noch keine auswertbaren Spiele. Nötig sind eine Aufstellung '
              '(Startelf) und die Live-Erfassung von Wechseln und Toren.',
            )
          else if (_selected.isEmpty)
            _infoCard(
              'Wähle oben einen oder mehrere Spieler aus. Für jeden siehst du, '
              'bei wie vielen Toren und Gegentoren er auf dem Feld stand.',
            )
          else
            for (final id in _selected)
              if (_byId[id] != null) _playerCard(_byId[id]!),
          const SizedBox(height: 8),
          _coverage(),
        ],
      ),
    );
  }

  Widget _infoCard(String text) => Card(
    child: Padding(padding: const EdgeInsets.all(16), child: Text(text)),
  );

  Widget _coverage() {
    final hint = Theme.of(context).hintColor;
    final small = TextStyle(color: hint, fontSize: 12);
    final gaps = [
      for (final m in _matches)
        if (m.missingFor > 0 || m.missingAgainst > 0) m,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Ausgewertet: ${_matches.length} '
          '${_matches.length == 1 ? 'Spiel' : 'Spiele'} '
          '(mit Aufstellung + Live-Erfassung)',
          style: small,
        ),
        for (final m in gaps)
          Text(
            '⚠ ${m.match.opponentName}: '
            '${[if (m.missingFor > 0) '${m.missingFor} ${m.missingFor == 1 ? 'Tor' : 'Tore'}', if (m.missingAgainst > 0) '${m.missingAgainst} ${m.missingAgainst == 1 ? 'Gegentor' : 'Gegentore'}'].join(' und ')} '
            'ohne Erfassung – nicht zugeordnet',
            style: small,
          ),
      ],
    );
  }

  Widget _playerCard(Player p) {
    final s = summarizeOnPitch(p.id, _matches);
    final hint = Theme.of(context).hintColor;
    final diffColor = s.diff > 0
        ? _green
        : s.diff < 0
        ? _red
        : hint;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          leading: PlayerAvatar(player: p, radius: 22),
          title: Text(
            p.displayName,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: s.games == 0
                ? const Text('In keinem ausgewerteten Spiel eingesetzt.')
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          _stat('${s.goalsFor}', 'Tore dabei', _green),
                          _stat('${s.goalsAgainst}', 'Gegentore', _red),
                          _stat(
                            '${s.diff > 0 ? '+' : ''}${s.diff}',
                            'Bilanz',
                            diffColor,
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${s.games} ${s.games == 1 ? 'Spiel' : 'Spiele'} · '
                        '${s.minutes} Min. · je 90 Min.: '
                        '${_num(s.forPer90)} Tore · '
                        '${_num(s.againstPer90)} Gegentore',
                        style: TextStyle(fontSize: 12, color: hint),
                      ),
                    ],
                  ),
          ),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Alle Tore',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
            for (final m in _matches) _matchBlock(m, p.id),
          ],
        ),
      ),
    );
  }

  Widget _stat(String value, String label, Color color) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w800,
            color: color,
          ),
        ),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    ),
  );

  Widget _matchBlock(OnPitchMatch m, String playerId) {
    final hint = Theme.of(context).hintColor;
    final played = m.played(playerId);
    final k = m.match.kickoff;
    final date = k == null ? '' : '${DateFormat('dd.MM.').format(k)} ';
    final head =
        '$date${m.match.opponentName}  '
        '${m.match.ownScore}:${m.match.opponentScore}';
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  head,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                played ? '${m.minutes[playerId]} Min.' : 'nicht eingesetzt',
                style: TextStyle(fontSize: 12, color: hint),
              ),
            ],
          ),
          if (m.goals.isEmpty)
            Text('Keine Tore erfasst.', style: TextStyle(color: hint)),
          for (final g in m.goals) _goalRow(g, playerId, played),
        ],
      ),
    );
  }

  Widget _goalRow(OnPitchGoal g, String playerId, bool played) {
    final hint = Theme.of(context).hintColor;
    final on = g.onPitch.contains(playerId);
    final e = g.event;
    final scorer = g.forUs
        ? (g.isOwnGoal ? 'Eigentor Gegner' : _name(e.playerId))
        : (g.isOwnGoal ? 'Eigentor ${_name(e.playerId)}'.trim() : 'Gegentor');
    final Color mark = !on ? hint : (g.forUs ? _green : _red);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 44,
            child: Text(
              e.minuteLabel,
              style: TextStyle(color: hint, fontSize: 13),
            ),
          ),
          Text(g.forUs ? '⚽' : '❌'),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              scorer.isEmpty ? (g.forUs ? 'Tor' : 'Gegentor') : scorer,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: on ? mark.withValues(alpha: 0.12) : null,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: mark.withValues(alpha: 0.5)),
            ),
            child: Text(
              on
                  ? '✓ auf dem Feld'
                  : (played ? '– nicht auf dem Feld' : '– nicht dabei'),
              style: TextStyle(
                fontSize: 12,
                color: mark,
                fontWeight: on ? FontWeight.w600 : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
