import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

import '../models/enums.dart';
import '../models/match.dart';
import '../models/match_event.dart';
import '../models/player.dart';
import '../models/stat_group.dart';
import '../models/stat_template.dart';
import '../services/peer_rating_service.dart';
import '../services/share_service.dart';
import '../services/stats_engine.dart';
import '../state/app_state.dart';
import '../widgets/player_avatar.dart';
import '../widgets/stat_charts.dart';
import '../widgets/team_logo.dart';

/// Statistik-Baukasten: Spieler (einzeln/Gruppen) oder Spiele frei auswerten,
/// Spiele filtern, Kennzahlen wählen, als Tabelle/Balken/Karten/Verlauf
/// anzeigen, als Vorlage speichern und als Bild teilen.
class StatsBuilderScreen extends StatefulWidget {
  const StatsBuilderScreen({super.key});

  @override
  State<StatsBuilderScreen> createState() => _StatsBuilderScreenState();
}

/// Einstellung des Baukastens (= Inhalt einer Vorlage).
class _Config {
  StatTopic topic = StatTopic.players;
  List<String> players = [];

  /// 'pos:…' (Positionsgruppe) oder 'grp:ID' (eigene Gruppe).
  List<String> groups = [];
  GroupMode mode = GroupMode.sum;
  MatchFilter filter = MatchFilter();
  List<String> playerMetrics = ['p_games', 'p_minutes', 'p_goals', 'p_assists'];
  List<String> matchMetrics = ['m_points', 'm_for', 'm_against', 'm_rating'];
  bool per90 = false;

  /// 'table', 'bars', 'cards', 'line'.
  String view = 'table';

  /// null = Standard-Reihenfolge, 'name' oder Kennzahl-ID.
  String? sort;
  bool sortDesc = true;
  String? chartMetric;
  bool cumulative = false;

  List<String> get metrics =>
      topic == StatTopic.players ? playerMetrics : matchMetrics;
  set metrics(List<String> v) =>
      topic == StatTopic.players ? playerMetrics = v : matchMetrics = v;

  Map<String, dynamic> toJson() => {
    'topic': topic.name,
    'players': players,
    'groups': groups,
    'mode': mode.name,
    'filter': filter.toJson(),
    'playerMetrics': playerMetrics,
    'matchMetrics': matchMetrics,
    'per90': per90,
    'view': view,
    'sort': sort,
    'sortDesc': sortDesc,
    'chartMetric': chartMetric,
    'cumulative': cumulative,
  };

  static List<String> _list(Object? v, List<String> fallback) =>
      v is List ? [for (final e in v) e.toString()] : fallback;

  static _Config fromJson(Map<String, dynamic>? j) {
    final c = _Config();
    if (j == null) return c;
    c.topic =
        StatTopic.values.where((t) => t.name == j['topic']).firstOrNull ??
        StatTopic.players;
    c.players = _list(j['players'], []);
    c.groups = _list(j['groups'], []);
    c.mode =
        GroupMode.values.where((m) => m.name == j['mode']).firstOrNull ??
        GroupMode.sum;
    final f = j['filter'];
    c.filter = MatchFilter.fromJson(
      f is Map ? Map<String, dynamic>.from(f) : null,
    );
    c.playerMetrics = _list(
      j['playerMetrics'],
      c.playerMetrics,
    ).where(kStatMetricById.containsKey).toList();
    c.matchMetrics = _list(
      j['matchMetrics'],
      c.matchMetrics,
    ).where(kStatMetricById.containsKey).toList();
    c.per90 = j['per90'] == true;
    c.view = (j['view'] as String?) ?? 'table';
    c.sort = j['sort'] as String?;
    c.sortDesc = j['sortDesc'] != false;
    c.chartMetric = j['chartMetric'] as String?;
    c.cumulative = j['cumulative'] == true;
    return c;
  }
}

/// Eine Ergebniszeile (Spieler, Gruppe oder Spiel).
class _Row {
  _Row({
    required this.key,
    required this.label,
    required this.values,
    this.sub,
    this.player,
    this.isGroup = false,
    this.isSummary = false,
  });

  final String key;
  final String label;
  final String? sub;
  final Player? player;
  final bool isGroup;
  final bool isSummary;
  final Map<String, num?> values;
}

class _StatsBuilderScreenState extends State<StatsBuilderScreen> {
  static const _views = [
    ('table', Icons.table_chart_outlined, 'Tabelle'),
    ('bars', Icons.bar_chart, 'Balken'),
    ('cards', Icons.view_agenda_outlined, 'Karten'),
    ('line', Icons.show_chart, 'Verlauf'),
  ];

  bool _loading = true;
  bool _sharing = false;
  bool _peerLoaded = false;
  bool _peerLoading = false;
  AppState? _app;

  String? _teamId;
  String _teamName = '';
  String? _teamLogo;

  /// Alle beendeten Spiele (neueste zuerst).
  List<StatMatchData> _all = [];
  int _season = MatchFilter.seasonOf(DateTime.now());
  List<Player> _squad = [];
  Map<String, Player> _byId = {};
  List<StatGroup> _groups = [];
  List<StatTemplate> _templates = [];

  _Config _cfg = _Config();
  String? _templateId;

  String get _prefKey => 'stat_builder_${_teamId ?? ''}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _app?.removeListener(_onAppChanged);
    super.dispose();
  }

  // ------------------------------------------------------------- Laden
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
    final finished =
        app.matches
            .where(
              (m) => m.ownTeamId == team.id && m.status == MatchStatus.finished,
            )
            .toList()
          ..sort(
            (a, b) =>
                (b.kickoff ?? b.createdAt).compareTo(a.kickoff ?? a.createdAt),
          );
    final data = <StatMatchData>[];
    for (final m in finished) {
      var starters = <String>{};
      final lineup = await app.repository.getReleasedLineup(m.id, team.id);
      if (lineup != null) {
        final entries = await app.lineupEntries(lineup.id);
        starters = {
          for (final e in entries)
            if (e.role == LineupRole.starter) e.playerId,
        };
      }
      final sums = <String, (double, int)>{};
      for (final r in await app.ratingsOf(m.id)) {
        final s = sums[r.playerId] ?? (0.0, 0);
        sums[r.playerId] = (s.$1 + r.rating, s.$2 + 1);
      }
      final mr = [
        for (final r in await app.matchRatingsOf(m.id))
          if (!r.abstained && r.rating != null) r.rating!,
      ];
      data.add(
        StatMatchData(
          match: m,
          events: byMatch[m.id] ?? const [],
          starters: starters,
          trainerRatings: {
            for (final e in sums.entries) e.key: e.value.$1 / e.value.$2,
          },
          matchRatings: mr,
        ),
      );
    }
    final groups = await app.statGroups();
    final templates = await app.statTemplates();
    _Config cfg = _Config();
    String? templateId;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('stat_builder_${team.id}');
      if (raw != null) {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        cfg = _Config.fromJson(
          j['cfg'] is Map ? Map<String, dynamic>.from(j['cfg']) : null,
        );
        templateId = j['template'] as String?;
      }
    } catch (_) {}
    if (!mounted) return;
    final squad = players.where((p) => !p.isStaffOnly).toList()
      ..sort((a, b) {
        final na = a.number ?? 999, nb = b.number ?? 999;
        if (na != nb) return na.compareTo(nb);
        return a.fullName.compareTo(b.fullName);
      });
    final latest = data.where((d) => d.match.kickoff != null).firstOrNull;
    setState(() {
      _teamId = team.id;
      _teamName = team.name;
      _teamLogo = team.logoPath;
      _squad = squad;
      _byId = {for (final p in players) p.id: p};
      _all = data;
      if (latest != null) _season = MatchFilter.seasonOf(latest.match.kickoff!);
      _groups = groups;
      _templates = templates;
      _cfg = cfg;
      _templateId = templates.any((t) => t.id == templateId)
          ? templateId
          : null;
      _cfg.players = _cfg.players.where(_byId.containsKey).toList();
      _loading = false;
    });
    _app = app..addListener(_onAppChanged);
    _ensurePeer();
  }

  /// Gruppen/Vorlagen anderer Trainer (Realtime) übernehmen.
  Future<void> _onAppChanged() async {
    final app = _app;
    if (app == null) return;
    final groups = await app.statGroups();
    final templates = await app.statTemplates();
    if (!mounted) return;
    setState(() {
      _groups = groups;
      _templates = templates;
      if (!templates.any((t) => t.id == _templateId)) _templateId = null;
    });
  }

  Future<void> _savePrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefKey,
        jsonEncode({'cfg': _cfg.toJson(), 'template': _templateId}),
      );
    } catch (_) {}
  }

  void _changed(VoidCallback fn) {
    setState(fn);
    _savePrefs();
    _ensurePeer();
  }

  /// Spieler-Bewertungen per Link nachladen, sobald eine Kennzahl sie braucht.
  Future<void> _ensurePeer() async {
    if (_peerLoaded || _peerLoading) return;
    if (!_metrics.any((m) => m.needsPeer)) return;
    if (!PeerRatingService.available) return;
    setState(() => _peerLoading = true);
    for (var i = 0; i < _all.length; i += 6) {
      final chunk = _all.skip(i).take(6);
      await Future.wait([
        for (final d in chunk)
          PeerRatingService.summary(d.match.id).then((s) => d.peer = s),
      ]);
    }
    if (!mounted) return;
    setState(() {
      _peerLoaded = true;
      _peerLoading = false;
    });
  }

  // ------------------------------------------------------ Berechnungen
  List<StatMatchData> get _filtered => _cfg.filter.apply(_all, _season);

  List<StatMetric> get _metrics => [
    for (final id in _cfg.metrics)
      if (kStatMetricById[id]?.topic == _cfg.topic) kStatMetricById[id]!,
  ];

  String _groupLabel(String key) {
    for (final (k, label, _) in kPositionGroups) {
      if (k == key) return label;
    }
    if (key.startsWith('grp:')) {
      final g = _groups.where((g) => 'grp:${g.id}' == key).firstOrNull;
      if (g != null) return g.name;
    }
    return '?';
  }

  List<String> _members(String key) {
    if (key.startsWith('pos:')) {
      return [
        for (final p in _squad)
          if (positionGroupOf(p.positions, p.position) == key) p.id,
      ];
    }
    final g = _groups.where((g) => 'grp:${g.id}' == key).firstOrNull;
    return [
      for (final id in g?.playerIds ?? const <String>[])
        if (_byId.containsKey(id)) id,
    ];
  }

  bool _groupExists(String key) =>
      key.startsWith('pos:') || _groups.any((g) => 'grp:${g.id}' == key);

  List<StatSubject> _subjects() {
    final out = <StatSubject>[];
    final seen = <String>{};
    void addPlayer(String id) {
      final p = _byId[id];
      if (p == null || !seen.add(id)) return;
      out.add(StatSubject(key: id, label: p.displayName, playerIds: [id]));
    }

    for (final id in _cfg.players) {
      addPlayer(id);
    }
    for (final key in _cfg.groups) {
      if (!_groupExists(key)) continue;
      final members = _members(key);
      if (_cfg.mode == GroupMode.each) {
        members.forEach(addPlayer);
      } else {
        out.add(
          StatSubject(
            key: key,
            label: _groupLabel(key),
            playerIds: members,
            isGroup: true,
          ),
        );
      }
    }
    return out;
  }

  bool _usePer90(StatMetric m) =>
      _cfg.topic == StatTopic.players && _cfg.per90 && m.per90able;

  String _fmt(StatMetric m, num? v) =>
      formatStat(v, decimals: _usePer90(m) ? 2 : m.decimals);

  String _matchLabel(GameMatch m) {
    final k = m.kickoff;
    final date = k == null ? '' : '${DateFormat('dd.MM.').format(k)} ';
    return '$date${m.opponentName}';
  }

  String _matchSub(GameMatch m) => [
    '${m.ownScore}:${m.opponentScore}',
    m.venue.label,
    if ((m.competition ?? '').isNotEmpty) m.competition!,
  ].join(' · ');

  /// Ergebniszeilen + (bei Spielen) Summenzeilen.
  (List<_Row>, List<_Row>) _rows() {
    final ms = _filtered;
    final metrics = _metrics;
    if (_cfg.topic == StatTopic.players) {
      final rows = [
        for (final s in _subjects())
          _Row(
            key: s.key,
            label: s.label,
            sub: s.isGroup
                ? '${s.playerIds.length} Spieler · '
                      '${_cfg.mode == GroupMode.avg ? 'Schnitt' : 'Summe'}'
                : null,
            player: s.isGroup ? null : _byId[s.key],
            isGroup: s.isGroup,
            values: {
              for (final m in metrics)
                m.id: subjectValue(
                  m,
                  s,
                  ms,
                  mode: _cfg.mode,
                  per90: _usePer90(m),
                ),
            },
          ),
      ];
      return (_sorted(rows), const []);
    }
    final rows = [
      for (final d in ms)
        _Row(
          key: d.match.id,
          label: _matchLabel(d.match),
          sub: _matchSub(d.match),
          values: {for (final m in metrics) m.id: matchValue(m, d)},
        ),
    ];
    final sums = {for (final m in metrics) m.id: matchSummary(m, ms)};
    final footer = ms.isEmpty
        ? <_Row>[]
        : [
            _Row(
              key: '_sum',
              label: 'Gesamt',
              sub: '${ms.length} Spiele',
              isSummary: true,
              values: {for (final m in metrics) m.id: sums[m.id]!.$1},
            ),
            _Row(
              key: '_avg',
              label: 'Ø je Spiel',
              isSummary: true,
              values: {for (final m in metrics) m.id: sums[m.id]!.$2},
            ),
          ];
    return (_sorted(rows), footer);
  }

  List<_Row> _sorted(List<_Row> rows) {
    final key = _cfg.sort;
    if (key == null) return rows;
    final desc = _cfg.sortDesc;
    final out = [...rows];
    if (key == 'name') {
      out.sort(
        (a, b) => desc
            ? b.label.toLowerCase().compareTo(a.label.toLowerCase())
            : a.label.toLowerCase().compareTo(b.label.toLowerCase()),
      );
      return out;
    }
    if (!_metrics.any((m) => m.id == key)) return rows;
    out.sort((a, b) {
      final va = a.values[key], vb = b.values[key];
      if (va == null && vb == null) return 0;
      if (va == null) return 1;
      if (vb == null) return -1;
      return desc ? vb.compareTo(va) : va.compareTo(vb);
    });
    return out;
  }

  void _tapSort(String key) {
    _changed(() {
      if (_cfg.sort == key) {
        // Dritter Tipp: zurück zur Standard-Reihenfolge.
        if (_cfg.sortDesc == (key == 'name')) {
          _cfg.sort = null;
        } else {
          _cfg.sortDesc = !_cfg.sortDesc;
        }
      } else {
        _cfg.sort = key;
        _cfg.sortDesc = key != 'name';
      }
    });
  }

  StatMetric? _chartMetric() {
    final ms = _metrics;
    if (ms.isEmpty) return null;
    return ms.where((m) => m.id == _cfg.chartMetric).firstOrNull ?? ms.first;
  }

  String _rangeLabel(List<StatMatchData> ms) {
    final dates = [
      for (final d in ms)
        if (d.match.kickoff != null) d.match.kickoff!,
    ]..sort();
    if (dates.isEmpty) return '';
    final a = DateFormat('dd.MM.').format(dates.first);
    final b = DateFormat('dd.MM.yyyy').format(dates.last);
    return dates.length == 1 ? b : '$a–$b';
  }

  /// Kurzbeschreibung der Spiele-Auswahl (für Info-Zeile und Teilen-Bild).
  String _filterSummary(List<StatMatchData> ms) {
    final f = _cfg.filter;
    final parts = <String>[];
    if (f.period == 'custom') {
      final df = DateFormat('dd.MM.yy');
      parts.add(
        '${f.from == null ? '…' : df.format(f.from!)}–'
        '${f.to == null ? '…' : df.format(f.to!)}',
      );
    } else if (f.period != 'all') {
      parts.add(
        '${MatchFilter.periodLabels[f.period]} $_season/'
        '${(_season + 1) % 100}',
      );
    }
    if (f.venue != null) parts.add(f.venue!.label);
    if (f.competitions.isNotEmpty) parts.add(f.competitions.join(', '));
    if (f.results.isNotEmpty) {
      const names = {'W': 'Siege', 'D': 'Unentschieden', 'L': 'Niederlagen'};
      parts.add('nur ${f.results.map((r) => names[r]).join('/')}');
    }
    if (f.opponents.isNotEmpty) {
      parts.add(
        f.opponents.length <= 2
            ? 'gegen ${f.opponents.join(', ')}'
            : 'gegen ${f.opponents.length} Gegner',
      );
    }
    if (f.trackedOnly) parts.add('nur live erfasst');
    final range = _rangeLabel(ms);
    parts.add(
      '${ms.length} ${ms.length == 1 ? 'Spiel' : 'Spiele'}'
      '${range.isEmpty ? '' : ' ($range)'}',
    );
    return parts.join(' · ');
  }

  String get _title {
    final t = _templates.where((t) => t.id == _templateId).firstOrNull;
    if (t != null) return t.name;
    return _cfg.topic == StatTopic.players
        ? 'Spieler-Statistik'
        : 'Spiel-Statistik';
  }

  // ------------------------------------------------------------- Build
  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_teamId == null) {
      return const Center(child: Text('Keine Mannschaft.'));
    }
    final ms = _filtered;
    final metrics = _metrics;
    final (rows, footer) = _rows();
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        _templateBar(),
        const SizedBox(height: 8),
        _controls(ms),
        const SizedBox(height: 8),
        Text(
          _filterSummary(ms),
          style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
        ),
        if (_peerLoading)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: LinearProgressIndicator(),
          ),
        if (metrics.any((m) => m.needsPeer) && !PeerRatingService.available)
          _info(
            'Spieler-Bewertungen per Link gibt es nur mit Cloud-Anmeldung.',
          ),
        const SizedBox(height: 8),
        if (_all.isEmpty)
          _info('Noch keine beendeten Spiele.')
        else if (ms.isEmpty)
          _info('Keine Spiele passen zur Auswahl – oben unter „Spiele" ändern.')
        else if (metrics.isEmpty)
          _info('Keine Kennzahlen gewählt – oben unter „Kennzahlen" wählen.')
        else if (_cfg.topic == StatTopic.players && rows.isEmpty)
          _info(
            'Wähle oben unter „Wer" Spieler oder Gruppen aus – einzeln, nach '
            'Position oder als eigene Gruppe.',
          )
        else ...[
          _viewSwitch(),
          const SizedBox(height: 8),
          _result(rows, footer, metrics, ms),
          const SizedBox(height: 8),
          _coverage(ms),
        ],
      ],
    );
  }

  Widget _info(String text) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Text(text, style: TextStyle(color: Theme.of(context).hintColor)),
    ),
  );

  Widget _coverage(List<StatMatchData> ms) {
    final withLineup = ms.where((d) => d.onPitch != null).length;
    final tracked = ms.where((d) => d.tracked).length;
    return Text(
      'Grundlage: ${ms.length} Spiele · $withLineup mit Aufstellung '
      '(Einsätze, Minuten, Auf dem Feld) · $tracked live erfasst (Aktionen, '
      'Torzeitpunkte). Spiele ohne diese Daten zählen bei Schnitten nicht mit.',
      style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
    );
  }

  // ------------------------------------------------------- Vorlagen-Leiste
  Widget _templateBar() {
    final active = _templates.where((t) => t.id == _templateId).firstOrNull;
    return Row(
      children: [
        const Icon(Icons.bookmarks_outlined, size: 18),
        const SizedBox(width: 6),
        Expanded(
          child: SizedBox(
            height: 40,
            child: _templates.isEmpty
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Noch keine Vorlagen – rechts speichern',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).hintColor,
                      ),
                    ),
                  )
                : ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final t in _templates)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: GestureDetector(
                            onLongPress: () => _templateMenu(t),
                            child: ChoiceChip(
                              label: Text(t.name),
                              selected: t.id == _templateId,
                              onSelected: (_) => _applyTemplate(t),
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        ),
        PopupMenuButton<String>(
          tooltip: 'Vorlagen',
          icon: const Icon(Icons.bookmark_add_outlined),
          onSelected: (v) {
            switch (v) {
              case 'new':
                _saveTemplateAs();
              case 'update':
                if (active != null) _updateTemplate(active);
              case 'manage':
                if (active != null) _templateMenu(active);
              case 'reset':
                _changed(() {
                  _cfg = _Config();
                  _templateId = null;
                });
            }
          },
          itemBuilder: (_) => [
            const PopupMenuItem(
              value: 'new',
              child: Text('Als neue Vorlage speichern …'),
            ),
            if (active != null)
              PopupMenuItem(
                value: 'update',
                child: Text('„${active.name}" mit aktueller Einstellung'),
              ),
            if (active != null)
              PopupMenuItem(
                value: 'manage',
                child: Text('„${active.name}" umbenennen/löschen …'),
              ),
            const PopupMenuItem(
              value: 'reset',
              child: Text('Neu beginnen (alles zurücksetzen)'),
            ),
          ],
        ),
      ],
    );
  }

  void _applyTemplate(StatTemplate t) {
    _changed(() {
      _cfg = _Config.fromJson(t.config);
      _cfg.players = _cfg.players.where(_byId.containsKey).toList();
      _templateId = t.id;
    });
  }

  Future<String?> _askName(String title, {String initial = ''}) async {
    final ctrl = TextEditingController(text: initial);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
    final n = name?.trim();
    return (n == null || n.isEmpty) ? null : n;
  }

  Future<bool> _confirm(String text) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          content: Text(text),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Löschen'),
            ),
          ],
        ),
      ) ==
      true;

  Future<void> _saveTemplateAs() async {
    final app = context.read<AppState>();
    final name = await _askName('Vorlage speichern');
    if (name == null) return;
    final t = await app.saveStatTemplate(name: name, config: _cfg.toJson());
    if (!mounted) return;
    _templates = await app.statTemplates();
    _changed(() => _templateId = t.id);
  }

  Future<void> _updateTemplate(StatTemplate t) async {
    final app = context.read<AppState>();
    await app.saveStatTemplate(id: t.id, name: t.name, config: _cfg.toJson());
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Vorlage „${t.name}" gespeichert')));
  }

  Future<void> _templateMenu(StatTemplate t) async {
    final app = context.read<AppState>();
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                t.name,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.save_outlined),
              title: const Text('Mit aktueller Einstellung überschreiben'),
              onTap: () => Navigator.pop(ctx, 'update'),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Umbenennen'),
              onTap: () => Navigator.pop(ctx, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Löschen'),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'update':
        await _updateTemplate(t);
      case 'rename':
        final name = await _askName('Vorlage umbenennen', initial: t.name);
        if (name == null) return;
        await app.saveStatTemplate(id: t.id, name: name, config: t.config);
      case 'delete':
        if (!await _confirm('Vorlage „${t.name}" löschen?')) return;
        await app.deleteStatTemplate(t.id);
        if (_templateId == t.id) _changed(() => _templateId = null);
    }
    await _onAppChanged();
  }

  // ------------------------------------------------------- Bedienleiste
  Widget _controls(List<StatMatchData> ms) {
    final players = _cfg.topic == StatTopic.players;
    final anyPer90 = _metrics.any((m) => m.per90able);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SegmentedButton<StatTopic>(
          segments: const [
            ButtonSegment(
              value: StatTopic.players,
              icon: Icon(Icons.person_outline),
              label: Text('Spieler'),
            ),
            ButtonSegment(
              value: StatTopic.matches,
              icon: Icon(Icons.sports_soccer),
              label: Text('Spiele'),
            ),
          ],
          selected: {_cfg.topic},
          onSelectionChanged: (s) => _changed(() {
            _cfg.topic = s.first;
            _cfg.sort = null;
          }),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (players)
              FilledButton.tonalIcon(
                onPressed: _pickWho,
                icon: const Icon(Icons.group_add_outlined, size: 18),
                label: Text(
                  'Wer (${_cfg.players.length + _cfg.groups.length})',
                ),
              ),
            FilledButton.tonalIcon(
              onPressed: _pickFilter,
              icon: const Icon(Icons.event_note, size: 18),
              label: Text(
                _cfg.filter.isDefault
                    ? 'Alle ${_all.length} Spiele'
                    : 'Spiele ${ms.length}/${_all.length}',
              ),
            ),
            FilledButton.tonalIcon(
              onPressed: _pickMetrics,
              icon: const Icon(Icons.tune, size: 18),
              label: Text('Kennzahlen (${_metrics.length})'),
            ),
            OutlinedButton.icon(
              onPressed: _sharing || ms.isEmpty || _metrics.isEmpty
                  ? null
                  : _share,
              icon: _sharing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.ios_share, size: 18),
              label: const Text('Als Bild teilen'),
            ),
          ],
        ),
        if (players && (_cfg.groups.isNotEmpty || anyPer90)) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (_cfg.groups.isNotEmpty)
                SegmentedButton<GroupMode>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: GroupMode.sum, label: Text('Summe')),
                    ButtonSegment(value: GroupMode.avg, label: Text('Schnitt')),
                    ButtonSegment(
                      value: GroupMode.each,
                      label: Text('Einzeln'),
                    ),
                  ],
                  selected: {_cfg.mode},
                  onSelectionChanged: (s) =>
                      _changed(() => _cfg.mode = s.first),
                ),
              if (anyPer90)
                FilterChip(
                  label: const Text('je 90 Min.'),
                  selected: _cfg.per90,
                  onSelected: (v) => _changed(() => _cfg.per90 = v),
                ),
            ],
          ),
        ],
        if (players && (_cfg.players.isNotEmpty || _cfg.groups.isNotEmpty)) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final key in _cfg.groups)
                if (_groupExists(key))
                  InputChip(
                    avatar: const Icon(Icons.groups_outlined, size: 18),
                    label: Text(
                      '${_groupLabel(key)} (${_members(key).length})',
                    ),
                    onDeleted: () => _changed(() => _cfg.groups.remove(key)),
                  ),
              for (final id in _cfg.players)
                if (_byId[id] != null)
                  InputChip(
                    avatar: PlayerAvatar(player: _byId[id]!, radius: 12),
                    label: Text(_byId[id]!.displayName),
                    onDeleted: () => _changed(() => _cfg.players.remove(id)),
                  ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _viewSwitch() => Row(
    children: [
      SegmentedButton<String>(
        showSelectedIcon: false,
        segments: [
          for (final (v, icon, label) in _views)
            ButtonSegment(value: v, icon: Icon(icon, size: 20), tooltip: label),
        ],
        selected: {_cfg.view},
        onSelectionChanged: (s) => _changed(() => _cfg.view = s.first),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Text(
          _views.firstWhere((v) => v.$1 == _cfg.view).$3,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
    ],
  );

  // ------------------------------------------------------- Auswahl-Sheets
  Widget _sheetHeader(
    BuildContext ctx,
    String title, {
    List<Widget> actions = const [],
  }) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
          ),
        ),
        ...actions,
        FilledButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Fertig'),
        ),
      ],
    ),
  );

  Widget _sectionLabel(String text, {Widget? trailing}) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
    child: Row(
      children: [
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
        ?trailing,
      ],
    ),
  );

  Future<void> _sheet(
    Widget Function(BuildContext ctx, ScrollController scroll, StateSetter set)
    builder,
  ) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      maxChildSize: 0.95,
      builder: (ctx, scroll) =>
          StatefulBuilder(builder: (ctx, set) => builder(ctx, scroll, set)),
    ),
  );

  Future<void> _pickWho() async {
    final players = [..._cfg.players];
    final groups = [..._cfg.groups];
    await _sheet(
      (ctx, scroll, set) => Column(
        children: [
          _sheetHeader(
            ctx,
            'Wer wird ausgewertet?',
            actions: [
              TextButton(
                onPressed: () => set(() {
                  players.clear();
                  groups.clear();
                }),
                child: const Text('Keine'),
              ),
            ],
          ),
          Expanded(
            child: ListView(
              controller: scroll,
              children: [
                _sectionLabel('Nach Position'),
                for (final (key, label, _) in kPositionGroups)
                  CheckboxListTile(
                    value: groups.contains(key),
                    secondary: const Icon(Icons.groups_outlined),
                    title: Text(label),
                    subtitle: Text('${_members(key).length} Spieler'),
                    onChanged: (v) => set(
                      () => v == true ? groups.add(key) : groups.remove(key),
                    ),
                  ),
                _sectionLabel(
                  'Eigene Gruppen',
                  trailing: TextButton.icon(
                    onPressed: () async {
                      final g = await _editGroup(null);
                      if (g != null) groups.add('grp:${g.id}');
                      set(() {});
                    },
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Neue Gruppe'),
                  ),
                ),
                if (_groups.isEmpty)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Text(
                      'Z. B. „Abwehr", „U23" oder „Neuzugänge" – für alle '
                      'Trainer sichtbar.',
                    ),
                  ),
                for (final g in _groups)
                  CheckboxListTile(
                    value: groups.contains('grp:${g.id}'),
                    title: Text(g.name),
                    subtitle: Text('${_members('grp:${g.id}').length} Spieler'),
                    secondary: IconButton(
                      tooltip: 'Bearbeiten',
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () async {
                        await _editGroup(g);
                        groups.removeWhere((k) => !_groupExists(k));
                        set(() {});
                      },
                    ),
                    onChanged: (v) => set(
                      () => v == true
                          ? groups.add('grp:${g.id}')
                          : groups.remove('grp:${g.id}'),
                    ),
                  ),
                _sectionLabel(
                  'Einzelne Spieler',
                  trailing: TextButton(
                    onPressed: () => set(() {
                      players
                        ..clear()
                        ..addAll(_squad.map((p) => p.id));
                    }),
                    child: const Text('Alle'),
                  ),
                ),
                for (final p in _squad)
                  CheckboxListTile(
                    value: players.contains(p.id),
                    secondary: PlayerAvatar(player: p, radius: 16),
                    title: Text(p.displayName),
                    subtitle: p.position == null ? null : Text(p.position!),
                    onChanged: (v) => set(
                      () =>
                          v == true ? players.add(p.id) : players.remove(p.id),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (!mounted) return;
    _changed(() {
      _cfg.players = players;
      _cfg.groups = groups.where(_groupExists).toList();
    });
  }

  /// Eigene Gruppe anlegen/bearbeiten/löschen. Gibt die gespeicherte Gruppe
  /// zurück (null bei Abbruch/Löschen).
  Future<StatGroup?> _editGroup(StatGroup? g) async {
    final app = context.read<AppState>();
    final ctrl = TextEditingController(text: g?.name ?? '');
    final sel = <String>{...?g?.playerIds};
    final res = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(g == null ? 'Neue Gruppe' : 'Gruppe bearbeiten'),
          content: SizedBox(
            width: 420,
            height: 480,
            child: Column(
              children: [
                TextField(
                  controller: ctrl,
                  autofocus: g == null,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                const SizedBox(height: 8),
                Text('${sel.length} Spieler gewählt'),
                Expanded(
                  child: ListView(
                    children: [
                      for (final p in _squad)
                        CheckboxListTile(
                          dense: true,
                          value: sel.contains(p.id),
                          title: Text(p.displayName),
                          onChanged: (v) => set(
                            () => v == true ? sel.add(p.id) : sel.remove(p.id),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            if (g != null)
              TextButton(
                onPressed: () => Navigator.pop(ctx, 'delete'),
                child: const Text('Löschen'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, 'save'),
              child: const Text('Speichern'),
            ),
          ],
        ),
      ),
    );
    StatGroup? saved;
    if (res == 'save' && ctrl.text.trim().isNotEmpty) {
      saved = await app.saveStatGroup(
        id: g?.id,
        name: ctrl.text.trim(),
        playerIds: [
          for (final p in _squad)
            if (sel.contains(p.id)) p.id,
        ],
      );
    } else if (res == 'delete' && g != null) {
      if (!await _confirm('Gruppe „${g.name}" löschen?')) return null;
      await app.deleteStatGroup(g.id);
    }
    await _onAppChanged();
    return saved;
  }

  Future<void> _pickFilter() async {
    var f = _cfg.filter.copy();
    final comps = {
      for (final d in _all)
        if ((d.match.competition ?? '').isNotEmpty) d.match.competition!,
    }.toList()..sort();
    final opps = {for (final d in _all) d.match.opponentName}.toList()..sort();
    const resultLabels = {
      'W': '🟢 Siege',
      'D': '🟡 Unentschieden',
      'L': '🔴 Niederlagen',
    };
    await _sheet((ctx, scroll, set) {
      final fitting = [
        for (final d in _all)
          if (f.matchesCriteria(d, _season)) d,
      ];
      void toggle(Set<String> s, String v, bool on) =>
          set(() => on ? s.add(v) : s.remove(v));
      return Column(
        children: [
          _sheetHeader(
            ctx,
            'Spiele auswählen',
            actions: [
              TextButton(
                onPressed: () => set(() => f = MatchFilter()),
                child: const Text('Zurücksetzen'),
              ),
            ],
          ),
          Expanded(
            child: ListView(
              controller: scroll,
              children: [
                _sectionLabel('Zeitraum'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final e in MatchFilter.periodLabels.entries)
                        ChoiceChip(
                          label: Text(
                            e.key == 'custom' && f.period == 'custom'
                                ? '${f.from == null ? '…' : DateFormat('dd.MM.yy').format(f.from!)}'
                                      '–${f.to == null ? '…' : DateFormat('dd.MM.yy').format(f.to!)}'
                                : e.key == 'season' ||
                                      e.key == 'first' ||
                                      e.key == 'second'
                                ? '${e.value} $_season/${(_season + 1) % 100}'
                                : e.value,
                          ),
                          selected: f.period == e.key,
                          onSelected: (_) async {
                            if (e.key == 'custom') {
                              final r = await showDateRangePicker(
                                context: ctx,
                                firstDate: DateTime(2015),
                                lastDate: DateTime(2100),
                                initialDateRange: f.from != null && f.to != null
                                    ? DateTimeRange(start: f.from!, end: f.to!)
                                    : null,
                              );
                              if (r == null) return;
                              set(() {
                                f.period = 'custom';
                                f.from = r.start;
                                f.to = r.end;
                              });
                            } else {
                              set(() => f.period = e.key);
                            }
                          },
                        ),
                    ],
                  ),
                ),
                _sectionLabel('Ort'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Wrap(
                    spacing: 6,
                    children: [
                      ChoiceChip(
                        label: const Text('Heim + Auswärts'),
                        selected: f.venue == null,
                        onSelected: (_) => set(() => f.venue = null),
                      ),
                      for (final v in Venue.values)
                        ChoiceChip(
                          label: Text(v.label),
                          selected: f.venue == v,
                          onSelected: (_) => set(() => f.venue = v),
                        ),
                    ],
                  ),
                ),
                _sectionLabel('Ergebnis'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Wrap(
                    spacing: 6,
                    children: [
                      for (final e in resultLabels.entries)
                        FilterChip(
                          label: Text(e.value),
                          selected: f.results.contains(e.key),
                          onSelected: (v) => toggle(f.results, e.key, v),
                        ),
                    ],
                  ),
                ),
                if (comps.isNotEmpty) ...[
                  _sectionLabel('Wettbewerb'),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final c in comps)
                          FilterChip(
                            label: Text(c),
                            selected: f.competitions.contains(c),
                            onSelected: (v) => toggle(f.competitions, c, v),
                          ),
                      ],
                    ),
                  ),
                ],
                _sectionLabel('Gegner'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final o in opps)
                        FilterChip(
                          label: Text(o),
                          selected: f.opponents.contains(o),
                          onSelected: (v) => toggle(f.opponents, o, v),
                        ),
                    ],
                  ),
                ),
                SwitchListTile(
                  title: const Text('Nur live erfasste Spiele'),
                  subtitle: const Text(
                    'Mit Anpfiff/Abpfiff in der Live-Erfassung',
                  ),
                  value: f.trackedOnly,
                  onChanged: (v) => set(() => f.trackedOnly = v),
                ),
                _sectionLabel(
                  'Spiele einzeln (${fitting.where((d) => !f.excluded.contains(d.match.id)).length}/${fitting.length})',
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        onPressed: () => set(f.excluded.clear),
                        child: const Text('Alle'),
                      ),
                      TextButton(
                        onPressed: () => set(
                          () =>
                              f.excluded.addAll(fitting.map((d) => d.match.id)),
                        ),
                        child: const Text('Keine'),
                      ),
                    ],
                  ),
                ),
                for (final d in fitting)
                  CheckboxListTile(
                    value: !f.excluded.contains(d.match.id),
                    title: Text(_matchLabel(d.match)),
                    subtitle: Text(_matchSub(d.match)),
                    secondary: Text(
                      d.result == 'W'
                          ? '🟢'
                          : d.result == 'L'
                          ? '🔴'
                          : '🟡',
                      style: const TextStyle(fontSize: 18),
                    ),
                    onChanged: (v) => toggle(f.excluded, d.match.id, v != true),
                  ),
              ],
            ),
          ),
        ],
      );
    });
    if (!mounted) return;
    // Abwahl nur für existierende Spiele merken.
    f.excluded.removeWhere((id) => !_all.any((d) => d.match.id == id));
    _changed(() => _cfg.filter = f);
  }

  Future<void> _pickMetrics() async {
    final sel = [..._cfg.metrics];
    var per90 = _cfg.per90;
    final topic = _cfg.topic;
    final available = kStatMetrics.where((m) => m.topic == topic).toList();
    final sections = <String>[];
    for (final m in available) {
      if (!sections.contains(m.section)) sections.add(m.section);
    }
    await _sheet(
      (ctx, scroll, set) => Column(
        children: [
          _sheetHeader(
            ctx,
            'Kennzahlen (${sel.length})',
            actions: [
              TextButton(
                onPressed: () => set(sel.clear),
                child: const Text('Keine'),
              ),
            ],
          ),
          Expanded(
            child: ListView(
              controller: scroll,
              children: [
                if (topic == StatTopic.players)
                  SwitchListTile(
                    title: const Text('je 90 Minuten'),
                    subtitle: const Text(
                      'Zählwerte (Tore, Fouls …) auf 90 Spielminuten '
                      'umrechnen',
                    ),
                    value: per90,
                    onChanged: (v) => set(() => per90 = v),
                  ),
                for (final s in sections) ...[
                  _sectionLabel(s),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final m in available)
                          if (m.section == s)
                            FilterChip(
                              label: Text(m.label),
                              selected: sel.contains(m.id),
                              onSelected: (v) => set(
                                () => v ? sel.add(m.id) : sel.remove(m.id),
                              ),
                            ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 16),
              ],
            ),
          ),
        ],
      ),
    );
    if (!mounted) return;
    _changed(() {
      _cfg.metrics = sel;
      _cfg.per90 = per90;
    });
  }

  // ------------------------------------------------------------ Ergebnis
  Widget _result(
    List<_Row> rows,
    List<_Row> footer,
    List<StatMetric> metrics,
    List<StatMatchData> ms, {
    bool forShare = false,
  }) {
    switch (_cfg.view) {
      case 'bars':
        return _bars(rows, metrics, forShare: forShare);
      case 'cards':
        return _cards(rows, footer, metrics);
      case 'line':
        return _line(metrics, ms, forShare: forShare);
      default:
        return _table(rows, footer, metrics, forShare: forShare);
    }
  }

  Widget _leading(_Row r, double radius) {
    if (r.player != null) {
      return PlayerAvatar(player: r.player!, radius: radius);
    }
    if (r.isGroup) {
      return CircleAvatar(
        radius: radius,
        child: Icon(Icons.groups, size: radius * 1.2),
      );
    }
    return const SizedBox.shrink();
  }

  static const _rowH = 44.0;
  static const _nameW = 150.0;
  static const _colW = 74.0;

  Widget _table(
    List<_Row> rows,
    List<_Row> footer,
    List<StatMetric> metrics, {
    bool forShare = false,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // Bester Wert je Spalte hervorheben (nur bei mehreren Zeilen).
    final best = <String, num>{};
    if (rows.length > 1) {
      for (final m in metrics) {
        num? b;
        for (final r in rows) {
          final v = r.values[m.id];
          if (v != null && (b == null || v > b)) b = v;
        }
        if (b != null) best[m.id] = b;
      }
    }
    Widget headCell(String text, String sortKey, {double? width}) {
      final active = _cfg.sort == sortKey;
      final child = Container(
        width: width,
        height: _rowH,
        alignment: width == null ? Alignment.centerLeft : Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                text,
                textAlign: width == null ? TextAlign.left : TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: active ? scheme.primary : null,
                ),
              ),
            ),
            if (active && !forShare)
              Icon(
                _cfg.sortDesc ? Icons.arrow_downward : Icons.arrow_upward,
                size: 14,
                color: scheme.primary,
              ),
          ],
        ),
      );
      if (forShare) return child;
      return InkWell(onTap: () => _tapSort(sortKey), child: child);
    }

    Color? rowColor(int i, _Row r) => r.isSummary
        ? scheme.primaryContainer.withValues(alpha: 0.5)
        : i.isOdd
        ? scheme.surfaceContainerHighest.withValues(alpha: 0.4)
        : null;

    final all = [...rows, ...footer];
    final nameCol = Column(
      children: [
        headCell(
          _cfg.topic == StatTopic.players ? 'Spieler / Gruppe' : 'Spiel',
          'name',
          width: _nameW,
        ),
        for (var i = 0; i < all.length; i++)
          Container(
            width: _nameW,
            height: _rowH,
            color: rowColor(i, all[i]),
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: [
                if (all[i].player != null || all[i].isGroup) ...[
                  _leading(all[i], 13),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        all[i].label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: all[i].isSummary || all[i].isGroup
                              ? FontWeight.bold
                              : FontWeight.w500,
                        ),
                      ),
                      if (all[i].sub != null)
                        Text(
                          all[i].sub!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10.5,
                            color: theme.hintColor,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
    final dataCol = Column(
      children: [
        Row(
          children: [
            for (final m in metrics) headCell(m.short, m.id, width: _colW),
          ],
        ),
        for (var i = 0; i < all.length; i++)
          Container(
            height: _rowH,
            color: rowColor(i, all[i]),
            child: Row(
              children: [
                for (final m in metrics)
                  SizedBox(
                    width: _colW,
                    child: Text(
                      _fmt(m, all[i].values[m.id]),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight:
                            all[i].isSummary ||
                                (!all[i].isSummary &&
                                    best[m.id] != null &&
                                    all[i].values[m.id] == best[m.id])
                            ? FontWeight.bold
                            : FontWeight.normal,
                        color:
                            !all[i].isSummary &&
                                best[m.id] != null &&
                                all[i].values[m.id] == best[m.id]
                            ? scheme.primary
                            : null,
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          nameCol,
          if (forShare)
            dataCol
          else
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: dataCol,
              ),
            ),
        ],
      ),
    );
  }

  Widget _metricPicker(List<StatMetric> metrics, StatMetric current) =>
      DropdownButton<String>(
        value: current.id,
        isExpanded: true,
        items: [
          for (final m in metrics)
            DropdownMenuItem(value: m.id, child: Text(m.label)),
        ],
        onChanged: (v) => _changed(() => _cfg.chartMetric = v),
      );

  Widget _bars(
    List<_Row> rows,
    List<StatMetric> metrics, {
    bool forShare = false,
  }) {
    final m = _chartMetric()!;
    final sorted = [...rows]
      ..sort((a, b) {
        final va = a.values[m.id], vb = b.values[m.id];
        if (va == null && vb == null) return 0;
        if (va == null) return 1;
        if (vb == null) return -1;
        return vb.compareTo(va);
      });
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (forShare)
              Text(
                m.label + (_usePer90(m) ? ' (je 90 Min.)' : ''),
                style: const TextStyle(fontWeight: FontWeight.bold),
              )
            else
              _metricPicker(metrics, m),
            const SizedBox(height: 8),
            StatBarList(
              items: [
                for (final r in sorted)
                  StatBarItem(
                    label: r.label,
                    value: r.values[m.id],
                    text: _fmt(m, r.values[m.id]),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _valueTile(StatMetric m, num? v) => Container(
    width: 96,
    padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
    decoration: BoxDecoration(
      color: Theme.of(
        context,
      ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      children: [
        Text(
          _fmt(m, v),
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        Text(
          m.label,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 10.5, color: Theme.of(context).hintColor),
        ),
      ],
    ),
  );

  Widget _cardHead(_Row r) => Row(
    children: [
      if (r.player != null || r.isGroup) ...[
        _leading(r, 18),
        const SizedBox(width: 10),
      ],
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(r.label, style: const TextStyle(fontWeight: FontWeight.bold)),
            if (r.sub != null)
              Text(
                r.sub!,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).hintColor,
                ),
              ),
          ],
        ),
      ),
    ],
  );

  Widget _cards(List<_Row> rows, List<_Row> footer, List<StatMetric> metrics) {
    // Zwei Spieler/Gruppen: direkte Gegenüberstellung.
    if (_cfg.topic == StatTopic.players && rows.length == 2) {
      final a = rows[0], b = rows[1];
      return Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(child: _cardHead(a)),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      'vs.',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                  Expanded(child: _cardHead(b)),
                ],
              ),
              const Divider(height: 20),
              for (final m in metrics)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 64,
                        child: Text(
                          _fmt(m, a.values[m.id]),
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          m.label,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12.5,
                            color: Theme.of(context).hintColor,
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 64,
                        child: Text(
                          _fmt(m, b.values[m.id]),
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      );
    }
    final list = [...footer, ...rows];
    return Column(
      children: [
        for (final r in list)
          Card(
            margin: const EdgeInsets.only(bottom: 10),
            color: r.isSummary
                ? Theme.of(
                    context,
                  ).colorScheme.primaryContainer.withValues(alpha: 0.6)
                : null,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _cardHead(r),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final m in metrics) _valueTile(m, r.values[m.id]),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _line(
    List<StatMetric> metrics,
    List<StatMatchData> ms, {
    bool forShare = false,
  }) {
    final chrono = ms.reversed.toList();
    final labels = [
      for (final d in chrono)
        d.match.kickoff == null
            ? '?'
            : DateFormat('dd.MM.').format(d.match.kickoff!),
    ];
    List<num?> cum(List<num?> v) {
      if (!_cfg.cumulative) return v;
      num run = 0;
      return [
        for (final x in v)
          if (x == null) null else run += x,
      ];
    }

    final series = <StatLineSeries>[];
    var decimals = 0;
    StatMetric? m;
    if (_cfg.topic == StatTopic.players) {
      m = _chartMetric()!;
      decimals = _usePer90(m) ? 2 : m.decimals;
      final subjects = _subjects().take(6).toList();
      for (var i = 0; i < subjects.length; i++) {
        series.add(
          StatLineSeries(
            label: subjects[i].label,
            color: kStatSeriesColors[i],
            values: cum(
              subjectSeries(
                m,
                subjects[i],
                chrono,
                mode: _cfg.mode,
                per90: _usePer90(m),
              ),
            ),
          ),
        );
      }
    } else {
      final shown = metrics.take(6).toList();
      for (var i = 0; i < shown.length; i++) {
        decimals = math.max(decimals, shown[i].decimals);
        series.add(
          StatLineSeries(
            label: shown[i].label,
            color: kStatSeriesColors[i],
            values: cum([for (final d in chrono) matchValue(shown[i], d)]),
          ),
        );
      }
    }
    final canCum = m == null || m.agg == MetricAgg.sum;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!forShare)
              Row(
                children: [
                  if (m != null) Expanded(child: _metricPicker(metrics, m)),
                  if (m == null)
                    Expanded(
                      child: Text(
                        metrics.length > 6
                            ? 'Die ersten 6 Kennzahlen'
                            : 'Alle gewählten Kennzahlen',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).hintColor,
                        ),
                      ),
                    ),
                  if (canCum)
                    FilterChip(
                      label: const Text('aufsummiert'),
                      selected: _cfg.cumulative,
                      onSelected: (v) => _changed(() => _cfg.cumulative = v),
                    ),
                ],
              )
            else if (m != null)
              Text(
                m.label +
                    (_usePer90(m) ? ' (je 90 Min.)' : '') +
                    (_cfg.cumulative && canCum ? ' – aufsummiert' : ''),
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            if (_cfg.topic == StatTopic.players && _subjects().length > 6)
              Text(
                'Es werden die ersten 6 Spieler/Gruppen gezeigt.',
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).hintColor,
                ),
              ),
            const SizedBox(height: 8),
            StatLineChart(xLabels: labels, series: series, decimals: decimals),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------- Teilen
  Widget _shareImage() {
    final scheme = Theme.of(context).colorScheme;
    final hint = Theme.of(context).hintColor;
    final ms = _filtered;
    final metrics = _metrics;
    final (rows, footer) = _rows();
    final width = _cfg.view == 'table'
        ? math.max(440.0, _nameW + _colW * metrics.length + 26)
        : 460.0;
    return Container(
      width: width,
      color: scheme.surface,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: scheme.primary,
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Row(
              children: [
                if (_teamLogo != null) ...[
                  TeamLogo(logoPath: _teamLogo, size: 40),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        _teamName,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: _result(rows, footer, metrics, ms, forShare: true),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              _filterSummary(ms) +
                  (_cfg.topic == StatTopic.players &&
                          _cfg.groups.isNotEmpty &&
                          _cfg.mode != GroupMode.each
                      ? ' · Gruppen: ${_cfg.mode.label}'
                      : '') +
                  (_cfg.per90 && metrics.any(_usePer90)
                      ? ' · Zählwerte je 90 Min.'
                      : ''),
              style: TextStyle(fontSize: 11, color: hint),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _share() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _sharing = true);
    try {
      final bytes = await captureOffscreen(context, _shareImage());
      if (bytes == null) return;
      final name = _title.replaceAll(RegExp(r'[^A-Za-z0-9ÄÖÜäöüß]+'), '_');
      final path = await shareOrSaveImage(bytes, name, text: _title);
      if (path != null && mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Als Bild gespeichert:\n$path')),
        );
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Teilen fehlgeschlagen: $e')),
      );
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }
}
