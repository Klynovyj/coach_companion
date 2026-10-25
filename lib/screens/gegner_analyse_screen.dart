import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/enums.dart';
import '../models/match.dart';
import '../models/player.dart';
import '../models/player_stat.dart';
import '../models/scout_marker.dart';
import '../services/fupa/fupa_dtos.dart';
import '../state/app_state.dart';
import '../widgets/player_avatar.dart';
import '../widgets/team_logo.dart';

/// Gegner-Analyse als durchklickbare Vollbild-Karten: die wichtigsten Infos
/// für den Trainer (Torjäger, Vorlagen, Neuzugänge, Disziplin, Schlüssel-
/// spieler, bisherige Duelle und das eigene Scouting).
class GegnerAnalyseScreen extends StatefulWidget {
  const GegnerAnalyseScreen({
    super.key,
    required this.ownTeamId,
    required this.opponentTeamId,
    required this.opponentName,
    this.opponentLogoPath,
  });

  final String ownTeamId;
  final String opponentTeamId;
  final String opponentName;
  final String? opponentLogoPath;

  @override
  State<GegnerAnalyseScreen> createState() => _GegnerAnalyseScreenState();
}

class _GegnerAnalyseScreenState extends State<GegnerAnalyseScreen> {
  final _controller = PageController();
  int _page = 0;

  List<Player> _players = [];
  List<PlayerStat> _stats = [];
  Map<String, Set<ScoutMarker>> _markers = {};
  Map<String, String> _comments = {};
  List<GameMatch> _duelle = [];
  StandingRow? _standing;
  List<FormMatch> _form = [];
  List<StandingRow> _table = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final s = context.read<AppState>();
    // Statistik bei Bedarf automatisch nachladen (fixt „Noch keine Statistik").
    await s.ensureOpponentStats(widget.opponentTeamId);
    // Gegnerkader kann über Cloud/mehrere Geräte doppelte Zeilen je Spieler
    // haben (eine mit, eine ohne FuPa-ID) – fürs Anzeigen zusammenführen.
    final players = dedupePlayersByName(await s.playersOf(widget.opponentTeamId));
    final stats = await s.statsOf(widget.opponentTeamId);
    final markers = await s.scoutMarkersForTeam(widget.opponentTeamId);
    final comments = await s.scoutCommentsForTeam(widget.opponentTeamId);
    final mm = await s.matchMap(widget.ownTeamId);
    final name = widget.opponentName.trim().toLowerCase();
    final duelle = mm.values.where((m) {
      return m.opponentTeamId == widget.opponentTeamId ||
          m.opponentName.trim().toLowerCase() == name;
    }).toList()
      ..sort((a, b) =>
          (b.kickoff ?? b.createdAt).compareTo(a.kickoff ?? a.createdAt));
    // Tabelle (komplett) + Platz + Form aus der FuPa-Liga (bestmöglich).
    final (standing, form, table) =
        await s.opponentAnalysis(widget.ownTeamId, widget.opponentTeamId);
    if (!mounted) return;
    setState(() {
      _players = players;
      _stats = stats;
      _markers = markers;
      _comments = comments;
      _duelle = duelle;
      _standing = standing;
      _form = form;
      _table = table;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cards = _loading ? <_CardData>[] : _buildCards();
    return Scaffold(
      appBar: AppBar(
        title: Text('Analyse · ${widget.opponentName}'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : cards.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('Noch keine Analyse-Daten.',
                        textAlign: TextAlign.center),
                  ),
                )
              : Column(
                  children: [
                    Expanded(
                      child: PageView.builder(
                        controller: _controller,
                        itemCount: cards.length,
                        onPageChanged: (i) => setState(() => _page = i),
                        itemBuilder: (context, i) => _AnalysisCardView(
                          data: cards[i],
                          index: i + 1,
                          total: cards.length,
                        ),
                      ),
                    ),
                    _bottomBar(context, cards.length),
                  ],
                ),
    );
  }

  Widget _bottomBar(BuildContext context, int total) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
        child: Row(
          children: [
            IconButton.filledTonal(
              onPressed: _page > 0
                  ? () => _controller.previousPage(
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOut)
                  : null,
              icon: const Icon(Icons.chevron_left),
            ),
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < total; i++)
                    Container(
                      width: i == _page ? 18 : 7,
                      height: 7,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        color: i == _page
                            ? scheme.primary
                            : scheme.outlineVariant,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                ],
              ),
            ),
            IconButton.filled(
              onPressed: _page < total - 1
                  ? () => _controller.nextPage(
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOut)
                  : null,
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------ Karten bauen
  List<_CardData> _buildCards() {
    final cards = <_CardData>[];
    final st = _standing;
    // Übersicht
    cards.add(_CardData(
      icon: Icons.insights,
      color: const Color(0xFF2E7D4F),
      title: widget.opponentName,
      subtitle: 'Gegner-Analyse',
      logoPath: widget.opponentLogoPath,
      rows: [
        _Row.kpis([
          if (st != null) ('${st.rank}.', 'Platz'),
          if (st != null) ('${st.points}', 'Punkte'),
          ('${_players.length}', 'Kader'),
          ('${_duelle.length}', 'Duelle'),
        ]),
        if (_form.isNotEmpty)
          _Row.text('Form: ${_form.map((f) => f.result).join(' ')}'),
      ],
    ));

    // Tabelle
    if (st != null) {
      cards.add(_CardData(
        icon: Icons.format_list_numbered,
        color: const Color(0xFF37474F),
        title: 'Tabelle',
        subtitle: 'Platz ${st.rank} von ${st.totalTeams}',
        rows: [_Row.standing(st)],
      ));
    }
    // Komplette Tabelle
    if (_table.isNotEmpty) {
      cards.add(_CardData(
        icon: Icons.table_chart,
        color: const Color(0xFF263238),
        title: 'Komplette Tabelle',
        subtitle: '${_table.length} Mannschaften',
        rows: [_Row.table(_table, st?.teamSlug)],
      ));
    }

    // Form (letzte 5 Spiele)
    if (_form.isNotEmpty) {
      final df = DateFormat('dd.MM.', 'de_DE');
      final last5 = _form.take(5).toList();
      cards.add(_CardData(
        icon: Icons.timeline,
        color: const Color(0xFF00695C),
        title: 'Form – letzte 5 Spiele',
        subtitle: last5.map((f) => f.result).join(' '),
        rows: [
          for (final f in last5)
            _Row.form(
              date: f.date != null ? df.format(f.date!.toLocal()) : '—',
              venue: f.home ? 'H' : 'A',
              opponent: f.opponentName,
              result: '${f.ownGoals}:${f.oppGoals}',
              outcome:
                  f.result == 'S' ? 1 : (f.result == 'N' ? -1 : 0),
            ),
        ],
      ));

      // Niederlagen (gegen wen + Ergebnis) – aus allen gespielten Spielen.
      final losses = _form.where((f) => f.result == 'N').toList();
      cards.add(_CardData(
        icon: Icons.trending_down,
        color: const Color(0xFFC62828),
        title: 'Niederlagen',
        subtitle: losses.isEmpty
            ? 'Diese Saison noch ungeschlagen'
            : '${losses.length} Niederlage${losses.length == 1 ? '' : 'n'}',
        rows: losses.isEmpty
            ? [_Row.text('Diese Saison noch ungeschlagen.')]
            : [
                for (final f in losses)
                  _Row.form(
                    date: f.date != null ? df.format(f.date!.toLocal()) : '—',
                    venue: f.home ? 'H' : 'A',
                    opponent: f.opponentName,
                    result: '${f.ownGoals}:${f.oppGoals}',
                    outcome: -1,
                  ),
              ],
      ));
    }

    final playerByKey = {for (final p in _players) p.dedupKey: p};

    if (_stats.isNotEmpty) {
      // Torjäger
      final scorers = _stats.where((s) => s.goals > 0).toList()
        ..sort((a, b) => b.goals.compareTo(a.goals));
      if (scorers.isNotEmpty) {
        cards.add(_statCard(
          icon: Icons.sports_soccer,
          color: const Color(0xFFC62828),
          title: 'Beste Schützen',
          subtitle: 'Aufpassen bei diesen Spielern',
          stats: scorers.take(6).toList(),
          playerByKey: playerByKey,
          value: (s) => '${s.goals} Tore',
          highlightFirst: true,
        ));
      }
      // Vorlagen
      final assists = _stats.where((s) => s.assists > 0).toList()
        ..sort((a, b) => b.assists.compareTo(a.assists));
      if (assists.isNotEmpty) {
        cards.add(_statCard(
          icon: Icons.handshake,
          color: const Color(0xFF1565C0),
          title: 'Beste Vorlagen',
          subtitle: 'Die Vorbereiter',
          stats: assists.take(6).toList(),
          playerByKey: playerByKey,
          value: (s) => '${s.assists} Vorlagen',
        ));
      }
      // Neuzugänge / ohne Saisoneinsatz
      final statKeys = {
        for (final s in _stats)
          '${s.firstName.trim().toLowerCase()}|${s.lastName.trim().toLowerCase()}':
              s
      };
      final newcomers = _players.where((p) {
        final st = statKeys[p.dedupKey];
        return st == null || st.matches == 0;
      }).toList();
      if (newcomers.isNotEmpty) {
        cards.add(_CardData(
          icon: Icons.fiber_new,
          color: const Color(0xFF6A1B9A),
          title: 'Neu / ohne Einsatz',
          subtitle: 'Vermutlich neu im Kader (noch kein Saisonspiel)',
          rows: [
            for (final p in newcomers.take(12))
              _Row.player(p, p.position ?? '',
                  fupaUrl: _fupaPlayerUrl(p.externalId)),
          ],
        ));
      }
      // Disziplin
      int cardsOf(PlayerStat s) =>
          s.yellowCards + s.yellowRedCards + s.redCards;
      final disz = _stats.where((s) => cardsOf(s) > 0).toList()
        ..sort((a, b) => cardsOf(b).compareTo(cardsOf(a)));
      if (disz.isNotEmpty) {
        cards.add(_statCard(
          icon: Icons.style,
          color: const Color(0xFFEF6C00),
          title: 'Disziplin',
          subtitle: 'Meiste Karten',
          stats: disz.take(6).toList(),
          playerByKey: playerByKey,
          value: (s) => [
            if (s.yellowCards > 0) '🟨 ${s.yellowCards}',
            if (s.yellowRedCards > 0) '🟨🟥 ${s.yellowRedCards}',
            if (s.redCards > 0) '🟥 ${s.redCards}',
          ].join('  '),
        ));
      }
      // Schlüsselspieler (meiste Einsätze/Minuten)
      final key = _stats.where((s) => s.matches > 0).toList()
        ..sort((a, b) {
          final byMatches = b.matches.compareTo(a.matches);
          return byMatches != 0 ? byMatches : b.minutes.compareTo(a.minutes);
        });
      if (key.isNotEmpty) {
        cards.add(_statCard(
          icon: Icons.star,
          color: const Color(0xFF00838F),
          title: 'Schlüsselspieler',
          subtitle: 'Meiste Einsätze',
          stats: key.take(6).toList(),
          playerByKey: playerByKey,
          value: (s) => '${s.matches} Sp. · ${s.minutes} Min',
        ));
      }
    }

    // Unsere Duelle
    cards.add(_duelleCard());

    // Dein Scouting
    cards.add(_scoutingCard());

    return cards;
  }

  _CardData _statCard({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required List<PlayerStat> stats,
    required Map<String, Player> playerByKey,
    required String Function(PlayerStat) value,
    bool highlightFirst = false,
  }) {
    return _CardData(
      icon: icon,
      color: color,
      title: title,
      subtitle: subtitle,
      rows: [
        for (var i = 0; i < stats.length; i++)
          _Row.stat(
            rank: i + 1,
            player: playerByKey[
                '${stats[i].firstName.trim().toLowerCase()}|${stats[i].lastName.trim().toLowerCase()}'],
            name: stats[i].fullName,
            value: value(stats[i]),
            highlight: highlightFirst && i == 0,
            fupaUrl: _fupaPlayerUrl(stats[i].externalId),
          ),
      ],
    );
  }

  _CardData _duelleCard() {
    final df = DateFormat('dd.MM.yyyy', 'de_DE');
    final finished =
        _duelle.where((m) => m.status == MatchStatus.finished).toList();
    return _CardData(
      icon: Icons.history,
      color: const Color(0xFF455A64),
      title: 'Unsere Duelle',
      subtitle: finished.isEmpty
          ? 'Noch kein beendetes Spiel gegen diesen Gegner'
          : '${finished.length} bisherige Begegnungen',
      rows: [
        if (_duelle.isEmpty)
          _Row.text('Keine Spiele gegen diesen Gegner gefunden.')
        else
          for (final m in _duelle)
            _Row.duel(
              date: m.kickoff != null ? df.format(m.kickoff!.toLocal()) : '—',
              venue: m.venue == Venue.home ? 'H' : 'A',
              result: m.status == MatchStatus.finished
                  ? '${m.ownScore} : ${m.opponentScore}'
                  : 'geplant',
              outcome: m.status == MatchStatus.finished
                  ? (m.ownScore > m.opponentScore
                      ? 1
                      : (m.ownScore < m.opponentScore ? -1 : 0))
                  : null,
            ),
      ],
    );
  }

  _CardData _scoutingCard() {
    final flagged = _players.where((p) {
      final hasMarker = (_markers[p.id] ?? const {}).isNotEmpty;
      final hasComment = (_comments[p.id] ?? '').trim().isNotEmpty;
      return hasMarker || hasComment;
    }).toList();
    return _CardData(
      icon: Icons.visibility,
      color: const Color(0xFF5D4037),
      title: 'Dein Scouting',
      subtitle: flagged.isEmpty
          ? 'Noch nichts markiert – im Gegner-Tab einen Spieler antippen'
          : '${flagged.length} markierte Spieler',
      rows: [
        if (flagged.isEmpty)
          _Row.text('Tippe im Gegner-Tab einen Spieler an, um Marker und '
              'Kommentare zu hinterlegen.')
        else
          for (final p in flagged)
            _Row.scouting(
              player: p,
              markers: (_markers[p.id] ?? const <ScoutMarker>{}).toList(),
              comment: _comments[p.id] ?? '',
            ),
      ],
    );
  }
}

// ---------------------------------------------------------------- Datenmodell
class _CardData {
  final IconData icon;
  final Color color;
  final String title;
  final String? subtitle;
  final String? logoPath;
  final List<_Row> rows;
  const _CardData({
    required this.icon,
    required this.color,
    required this.title,
    this.subtitle,
    this.logoPath,
    required this.rows,
  });
}

/// FuPa-Profil-URL aus der externen Spieler-ID (FuPa leitet `/player/ID`
/// per 301 aufs Profil weiter). Null, wenn keine FuPa-ID vorhanden.
String? _fupaPlayerUrl(String? externalId) {
  final id = externalId?.trim();
  if (id == null || id.isEmpty) return null;
  return 'https://www.fupa.net/player/$id';
}

Future<void> _openFupa(String url) async {
  try {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } catch (_) {}
}

enum _RowKind { text, stat, player, duel, form, scouting, standing, table, kpis }

class _Row {
  final _RowKind kind;
  final String? text;
  final int? rank;
  final Player? player;
  final String? name;
  final String? value;
  final bool highlight;
  /// FuPa-Profil-URL des Spielers (Zeile wird dann anklickbar).
  final String? fupaUrl;
  // Duell
  final String? date;
  final String? venue;
  final String? result;
  final int? outcome; // 1 Sieg, 0 Remis, -1 Niederlage
  // Scouting
  final List<ScoutMarker>? markers;
  final String? comment;
  // Tabelle
  final StandingRow? standing;
  final List<StandingRow>? tableRows;
  final String? highlightSlug;
  final List<(String, String)>? kpis;

  const _Row._({
    required this.kind,
    this.text,
    this.rank,
    this.player,
    this.name,
    this.value,
    this.highlight = false,
    this.fupaUrl,
    this.date,
    this.venue,
    this.result,
    this.outcome,
    this.markers,
    this.comment,
    this.standing,
    this.tableRows,
    this.highlightSlug,
    this.kpis,
  });

  factory _Row.text(String text) => _Row._(kind: _RowKind.text, text: text);
  factory _Row.kpis(List<(String, String)> kpis) =>
      _Row._(kind: _RowKind.kpis, kpis: kpis);
  factory _Row.standing(StandingRow s) =>
      _Row._(kind: _RowKind.standing, standing: s);
  factory _Row.table(List<StandingRow> rows, String? highlightSlug) =>
      _Row._(kind: _RowKind.table, tableRows: rows, highlightSlug: highlightSlug);
  factory _Row.stat({
    required int rank,
    Player? player,
    required String name,
    required String value,
    bool highlight = false,
    String? fupaUrl,
  }) =>
      _Row._(
        kind: _RowKind.stat,
        rank: rank,
        player: player,
        name: name,
        value: value,
        highlight: highlight,
        fupaUrl: fupaUrl,
      );
  factory _Row.player(Player player, String value, {String? fupaUrl}) =>
      _Row._(
          kind: _RowKind.player,
          player: player,
          value: value,
          fupaUrl: fupaUrl);
  factory _Row.duel({
    required String date,
    required String venue,
    required String result,
    int? outcome,
  }) =>
      _Row._(
        kind: _RowKind.duel,
        date: date,
        venue: venue,
        result: result,
        outcome: outcome,
      );
  factory _Row.form({
    required String date,
    required String venue,
    required String opponent,
    required String result,
    int? outcome,
  }) =>
      _Row._(
        kind: _RowKind.form,
        date: date,
        venue: venue,
        name: opponent,
        result: result,
        outcome: outcome,
      );
  factory _Row.scouting({
    required Player player,
    required List<ScoutMarker> markers,
    required String comment,
  }) =>
      _Row._(
        kind: _RowKind.scouting,
        player: player,
        markers: markers,
        comment: comment,
      );
}

// --------------------------------------------------------------- Karten-View
class _AnalysisCardView extends StatelessWidget {
  const _AnalysisCardView({
    required this.data,
    required this.index,
    required this.total,
  });
  final _CardData data;
  final int index;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
      child: Card(
        clipBehavior: Clip.antiAlias,
        elevation: 3,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              color: data.color,
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
              child: Row(
                children: [
                  if (data.logoPath != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: TeamLogo(logoPath: data.logoPath, size: 40),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Icon(data.icon, color: Colors.white, size: 30),
                    ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(data.title,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.bold),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis),
                        if (data.subtitle != null)
                          Text(data.subtitle!,
                              style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.9))),
                      ],
                    ),
                  ),
                  Text('$index/$total',
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.9))),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                children: [for (final r in data.rows) _row(context, r)],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, _Row r) {
    switch (r.kind) {
      case _RowKind.text:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(r.text!,
              style: Theme.of(context).textTheme.bodyLarge),
        );
      case _RowKind.stat:
        return InkWell(
          onTap: r.fupaUrl != null ? () => _openFupa(r.fupaUrl!) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 13,
                  backgroundColor: r.highlight
                      ? Colors.amber.shade700
                      : Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: Text('${r.rank}',
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: r.highlight ? Colors.white : null)),
                ),
                const SizedBox(width: 10),
                if (r.player != null) ...[
                  PlayerAvatar(player: r.player!, radius: 16),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(r.name ?? r.player?.fullName ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontWeight:
                              r.highlight ? FontWeight.bold : FontWeight.w500)),
                ),
                Text(r.value ?? '',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                if (r.fupaUrl != null) ...[
                  const SizedBox(width: 6),
                  Icon(Icons.open_in_new,
                      size: 15, color: Theme.of(context).hintColor),
                ],
              ],
            ),
          ),
        );
      case _RowKind.player:
        return InkWell(
          onTap: r.fupaUrl != null ? () => _openFupa(r.fupaUrl!) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                PlayerAvatar(player: r.player!, radius: 16),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(r.player!.fullName,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                if ((r.value ?? '').isNotEmpty)
                  Text(r.value!, style: Theme.of(context).textTheme.bodySmall),
                if (r.fupaUrl != null) ...[
                  const SizedBox(width: 6),
                  Icon(Icons.open_in_new,
                      size: 15, color: Theme.of(context).hintColor),
                ],
              ],
            ),
          ),
        );
      case _RowKind.duel:
        final c = r.outcome == null
            ? Colors.grey
            : (r.outcome! > 0
                ? Colors.green.shade700
                : (r.outcome! < 0 ? Colors.red.shade700 : Colors.orange));
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Container(
                width: 26,
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(vertical: 2),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(r.venue!,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(r.date!)),
              Text(r.result!,
                  style: TextStyle(fontWeight: FontWeight.bold, color: c)),
            ],
          ),
        );
      case _RowKind.kpis:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              for (final k in r.kpis!)
                Column(
                  children: [
                    Text(k.$1,
                        style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: Theme.of(context).colorScheme.primary)),
                    Text(k.$2, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
            ],
          ),
        );
      case _RowKind.table:
        final rows = r.tableRows!;
        Widget cell(String t, double w,
                {bool header = false, Color? color}) =>
            SizedBox(
              width: w,
              child: Text(t,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  style: TextStyle(
                      fontWeight:
                          header ? FontWeight.bold : FontWeight.w600,
                      color: color)),
            );
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 4, right: 4),
              child: Row(
                children: [
                  cell('#', 28, header: true),
                  const Expanded(
                      child: Text('Team',
                          style: TextStyle(fontWeight: FontWeight.bold))),
                  cell('Sp', 30, header: true),
                  cell('Diff', 40, header: true),
                  cell('Pkt', 34, header: true),
                ],
              ),
            ),
            const Divider(height: 1),
            for (final t in rows)
              Container(
                color: t.teamSlug == r.highlightSlug
                    ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.12)
                    : null,
                padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 0),
                child: Row(
                  children: [
                    cell('${t.rank}', 28,
                        color: t.rank <= 2
                            ? Colors.green.shade700
                            : (t.rank >= rows.length - 2
                                ? Colors.red.shade700
                                : null),
                        header: true),
                    Expanded(
                      child: Text(t.teamName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontWeight: t.teamSlug == r.highlightSlug
                                  ? FontWeight.bold
                                  : FontWeight.normal)),
                    ),
                    cell('${t.matches}', 30),
                    cell('${t.goalDiff >= 0 ? '+' : ''}${t.goalDiff}', 40),
                    cell('${t.points}', 34, header: true),
                  ],
                ),
              ),
          ],
        );
      case _RowKind.standing:
        final s = r.standing!;
        final scheme = Theme.of(context).colorScheme;
        Widget seg(int n, Color col, String label) => Expanded(
              flex: n == 0 ? 1 : n,
              child: Container(
                height: 26,
                alignment: Alignment.center,
                color: col,
                child: n == 0
                    ? null
                    : Text('$label $n',
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 12)),
              ),
            );
        Widget kpi(String value, String label) => Column(
              children: [
                Text(value,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
                Text(label, style: Theme.of(context).textTheme.bodySmall),
              ],
            );
        return Column(
          children: [
            const SizedBox(height: 4),
            Row(
              children: [
                Container(
                  width: 64,
                  height: 64,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    shape: BoxShape.circle,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('${s.rank}.',
                          style: TextStyle(
                              color: scheme.onPrimary,
                              fontSize: 24,
                              fontWeight: FontWeight.bold)),
                      Text('von ${s.totalTeams}',
                          style: TextStyle(
                              color: scheme.onPrimary.withValues(alpha: 0.85),
                              fontSize: 10)),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      kpi('${s.points}', 'Punkte'),
                      kpi('${s.matches}', 'Spiele'),
                      kpi('${s.goalDiff >= 0 ? '+' : ''}${s.goalDiff}', 'Diff'),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // Sieg/Unentschieden/Niederlage als farbiger Balken.
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Row(
                children: [
                  seg(s.wins, Colors.green.shade600, 'S'),
                  seg(s.draws, Colors.orange.shade600, 'U'),
                  seg(s.defeats, Colors.red.shade600, 'N'),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.sports_soccer, size: 16),
                const SizedBox(width: 6),
                Text('Tore ${s.goalsFor} : ${s.goalsAgainst}',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ],
            ),
          ],
        );
      case _RowKind.form:
        final c = r.outcome == null
            ? Colors.grey
            : (r.outcome! > 0
                ? Colors.green.shade700
                : (r.outcome! < 0 ? Colors.red.shade700 : Colors.orange));
        final letter = r.outcome == null
            ? '–'
            : (r.outcome! > 0 ? 'S' : (r.outcome! < 0 ? 'N' : 'U'));
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: c, shape: BoxShape.circle),
                child: Text(letter,
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${r.venue} · ${r.name}',
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(r.date!,
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              Text(r.result!,
                  style: TextStyle(fontWeight: FontWeight.bold, color: c)),
            ],
          ),
        );
      case _RowKind.scouting:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PlayerAvatar(player: r.player!, radius: 16),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(r.player!.fullName,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    if (r.markers!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 2,
                          children: [
                            for (final m in r.markers!)
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(m.icon,
                                      size: 14,
                                      color:
                                          Theme.of(context).colorScheme.primary),
                                  const SizedBox(width: 2),
                                  Text(m.label,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall),
                                ],
                              ),
                          ],
                        ),
                      ),
                    if ((r.comment ?? '').trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(r.comment!,
                            style: Theme.of(context).textTheme.bodySmall),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
    }
  }
}
