import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/enums.dart';
import '../models/match_event.dart';
import '../models/player.dart';
import '../services/on_pitch_stats.dart';
import '../services/share_service.dart';
import '../state/app_state.dart';
import '../widgets/player_avatar.dart';
import '../widgets/team_logo.dart';

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
  bool _sharing = false;
  String? _teamId;
  String _teamName = '';
  String? _teamLogo;
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
      _teamName = team.name;
      _teamLogo = team.logoPath;
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
              if (_selected.isNotEmpty && _matches.isNotEmpty)
                OutlinedButton.icon(
                  onPressed: _sharing ? null : _share,
                  icon: _sharing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.ios_share, size: 18),
                  label: const Text('Als Bild teilen'),
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

  /// Kopf (Foto, Name, Minuten) + Gegenüberstellung mit/ohne – für die
  /// Karte im Reiter und fürs Teilen-Bild.
  Widget _summaryBlock(Player p, OnPitchSummary s) {
    final hint = Theme.of(context).hintColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            PlayerAvatar(player: p, radius: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    p.displayName,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text(
                    s.games == 0
                        ? 'In keinem ausgewerteten Spiel eingesetzt'
                        : '${s.games} ${s.games == 1 ? 'Spiel' : 'Spiele'}'
                              ' · ${s.minutes} Min. mit ihm · '
                              '${s.withoutMinutes} Min. ohne ihn',
                    style: TextStyle(fontSize: 12, color: hint),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        _compareTable(s),
      ],
    );
  }

  Widget _playerCard(Player p) {
    final s = summarizeOnPitch(p.id, _matches);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: _summaryBlock(p, s),
          ),
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: const EdgeInsets.symmetric(horizontal: 12),
              childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              title: Text(
                'Alle Tore',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              children: [for (final m in _matches) _matchBlock(m, p.id)],
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ Teilen
  /// Zeitraum der ausgewerteten Spiele, z. B. „25.10.–15.11.2026".
  String _rangeLabel() {
    final dates = [
      for (final m in _matches)
        if (m.match.kickoff != null) m.match.kickoff!,
    ]..sort();
    if (dates.isEmpty) return '';
    final a = DateFormat('dd.MM.').format(dates.first);
    final b = DateFormat('dd.MM.yyyy').format(dates.last);
    return dates.length == 1 ? b : '$a–$b';
  }

  /// Bild aller gewählten Spieler (Kopf + Gegenüberstellung) zum Teilen.
  Widget _shareImage() {
    final scheme = Theme.of(context).colorScheme;
    final hint = Theme.of(context).hintColor;
    final range = _rangeLabel();
    return Container(
      width: 420,
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
                      const Text(
                        'Auf dem Feld',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        'Tore & Gegentore mit und ohne Spieler · $_teamName',
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
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final id in _selected)
                  if (_byId[id] != null)
                    Card(
                      margin: const EdgeInsets.only(bottom: 10),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                        child: _summaryBlock(
                          _byId[id]!,
                          summarizeOnPitch(id, _matches),
                        ),
                      ),
                    ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              'Ausgewertet: ${_matches.length} '
              '${_matches.length == 1 ? 'Spiel' : 'Spiele'}'
              '${range.isEmpty ? '' : ' ($range)'} · '
              'Startelf + erfasste Wechsel und Tore',
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
      final bytes = await _captureOffscreen(_shareImage());
      if (bytes == null) return;
      final names = [
        for (final id in _selected)
          if (_byId[id] != null) _byId[id]!.lastName,
      ];
      final path = await shareOrSaveImage(
        bytes,
        'Auf_dem_Feld_${names.take(3).join('_')}',
        text: 'Auf dem Feld – ${names.join(', ')}',
      );
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

  /// Rendert [child] unsichtbar (off-screen) und gibt ein PNG davon zurück.
  Future<Uint8List?> _captureOffscreen(Widget child) async {
    final key = GlobalKey();
    final overlay = Overlay.of(context);
    final entry = OverlayEntry(
      builder: (_) => Positioned(
        left: -4000,
        top: 0,
        child: Material(
          type: MaterialType.transparency,
          child: RepaintBoundary(key: key, child: child),
        ),
      ),
    );
    overlay.insert(entry);
    try {
      await WidgetsBinding.instance.endOfFrame;
      // Kurz warten, damit Fotos/Logo (Image.memory) dekodiert und gemalt sind.
      await Future.delayed(const Duration(milliseconds: 250));
      final boundary =
          key.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return null;
      final image = await boundary.toImage(pixelRatio: 3);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } finally {
      entry.remove();
    }
  }

  /// Gegenüberstellung: Tore/Gegentore mit ihm auf dem Feld und ohne ihn
  /// (absolut und je 90 Minuten).
  Widget _compareTable(OnPitchSummary s) {
    final hint = Theme.of(context).hintColor;
    final head = TextStyle(fontSize: 11, color: hint);
    Color diffC(int d) => d > 0
        ? _green
        : d < 0
        ? _red
        : hint;
    Widget cell(String t, {Color? c, bool bold = false, bool right = true}) =>
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Text(
            t,
            textAlign: right ? TextAlign.right : TextAlign.left,
            style: TextStyle(
              color: c,
              fontWeight: bold ? FontWeight.w800 : FontWeight.w500,
              fontSize: bold ? 17 : 13,
            ),
          ),
        );
    Widget h(String t) => Text(t, textAlign: TextAlign.right, style: head);
    TableRow row(String label, int f, int a, double? f90, double? a90) =>
        TableRow(
          children: [
            cell(label, right: false),
            cell('$f', c: _green, bold: true),
            cell('$a', c: _red, bold: true),
            cell(
              '${f - a > 0 ? '+' : ''}${f - a}',
              c: diffC(f - a),
              bold: true,
            ),
            cell('${_num(f90)} : ${_num(a90)}', c: hint),
          ],
        );
    return Table(
      columnWidths: const {
        0: FlexColumnWidth(1.25),
        1: FlexColumnWidth(0.8),
        2: FlexColumnWidth(1.1),
        3: FlexColumnWidth(0.9),
        4: FlexColumnWidth(1.4),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        TableRow(
          children: [
            const SizedBox(),
            h('Tore'),
            h('Gegentore'),
            h('Bilanz'),
            h('je 90 Min.'),
          ],
        ),
        row('Mit ihm', s.goalsFor, s.goalsAgainst, s.forPer90, s.againstPer90),
        row(
          'Ohne ihn',
          s.withoutFor,
          s.withoutAgainst,
          s.withoutForPer90,
          s.withoutAgainstPer90,
        ),
      ],
    );
  }

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
          if (m.goals.isNotEmpty)
            Builder(
              builder: (_) {
                final (wf, wa, of, oa) = m.split(playerId);
                return Text(
                  'Mit ihm $wf:$wa · ohne ihn $of:$oa',
                  style: TextStyle(fontSize: 12, color: hint),
                );
              },
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
