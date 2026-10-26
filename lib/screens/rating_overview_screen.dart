import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/enums.dart';
import '../models/match.dart';
import '../state/app_state.dart';
import '../widgets/team_logo.dart';
import 'rating_summary_screen.dart';

enum _SortBy { date, rating, result }

/// Übersicht aller Spiele mit Logos, Ergebnis und Bewertungs-Schnitt. Sortierbar
/// (Datum/Note/Ergebnis); gespielte Spiele zuerst, kommende unten angehängt.
/// Antippen öffnet die Auswertung (Trainer-Noten, Berichte, Spieler-Schnitt).
class RatingOverviewScreen extends StatefulWidget {
  const RatingOverviewScreen({super.key});

  @override
  State<RatingOverviewScreen> createState() => _RatingOverviewScreenState();
}

class _RatingOverviewScreenState extends State<RatingOverviewScreen> {
  final _df = DateFormat('EEE, dd.MM.yyyy', 'de_DE');
  List<GameMatch> _matches = [];
  final Map<String, (double?, int, int)> _summaries = {};
  String? _ownLogo;
  bool _loading = true;

  _SortBy _sortBy = _SortBy.date;
  bool _desc = true; // true = absteigend (neueste/beste/höchste zuerst)

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final s = context.read<AppState>();
    final matches = [...s.matches];
    _summaries.clear();
    for (final m in matches) {
      _summaries[m.id] = await s.matchRatingSummary(m.id);
    }
    if (!mounted) return;
    setState(() {
      _matches = matches;
      _ownLogo = s.ownTeam?.logoPath;
      _loading = false;
    });
  }

  /// Sortierte Reihenfolge: gespielte Spiele nach Kriterium, kommende unten
  /// (nach Anstoß, nächstes zuerst).
  List<GameMatch> _ordered() {
    final finished = _matches
        .where((m) => m.status == MatchStatus.finished)
        .toList();
    final upcoming =
        _matches.where((m) => m.status != MatchStatus.finished).toList()..sort(
          (a, b) =>
              (a.kickoff ?? a.createdAt).compareTo(b.kickoff ?? b.createdAt),
        );

    int byDate(GameMatch a, GameMatch b) =>
        (a.kickoff ?? a.createdAt).compareTo(b.kickoff ?? b.createdAt);
    int byRating(GameMatch a, GameMatch b) {
      final ra = _summaries[a.id]?.$1 ?? -1.0;
      final rb = _summaries[b.id]?.$1 ?? -1.0;
      return ra.compareTo(rb);
    }

    int byResult(GameMatch a, GameMatch b) =>
        (a.ownScore - a.opponentScore).compareTo(b.ownScore - b.opponentScore);

    final cmp = switch (_sortBy) {
      _SortBy.date => byDate,
      _SortBy.rating => byRating,
      _SortBy.result => byResult,
    };
    finished.sort(cmp);
    final sorted = _desc ? finished.reversed.toList() : finished;
    return [...sorted, ...upcoming];
  }

  @override
  Widget build(BuildContext context) {
    final list = _loading ? const <GameMatch>[] : _ordered();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Auswertung'),
        actions: [
          IconButton(
            tooltip: _desc ? 'Absteigend' : 'Aufsteigend',
            icon: Icon(_desc ? Icons.arrow_downward : Icons.arrow_upward),
            onPressed: () => setState(() => _desc = !_desc),
          ),
          PopupMenuButton<_SortBy>(
            tooltip: 'Sortieren',
            icon: const Icon(Icons.sort),
            initialValue: _sortBy,
            onSelected: (v) => setState(() => _sortBy = v),
            itemBuilder: (_) => const [
              PopupMenuItem(value: _SortBy.date, child: Text('Nach Datum')),
              PopupMenuItem(value: _SortBy.rating, child: Text('Nach Note')),
              PopupMenuItem(
                value: _SortBy.result,
                child: Text('Nach Ergebnis'),
              ),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : list.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('Noch keine Spiele.', textAlign: TextAlign.center),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 6),
              itemCount: list.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) => _matchRow(context, list[i]),
            ),
    );
  }

  Widget _logo(String? path) => path != null
      ? TeamLogo(logoPath: path, size: 30)
      : Icon(
          Icons.shield_outlined,
          size: 26,
          color: Theme.of(context).colorScheme.outline,
        );

  Color _outcomeColor(GameMatch m) {
    if (m.ownScore > m.opponentScore) return Colors.green.shade700;
    if (m.ownScore < m.opponentScore) return Colors.red.shade700;
    return Colors.orange.shade800;
  }

  String _outcomeLetter(GameMatch m) {
    if (m.ownScore > m.opponentScore) return 'S';
    if (m.ownScore < m.opponentScore) return 'N';
    return 'U';
  }

  Widget _matchRow(BuildContext context, GameMatch m) {
    final (avg, rated, _) = _summaries[m.id] ?? (null, 0, 0);
    final finished = m.status == MatchStatus.finished;
    final c = finished ? _outcomeColor(m) : Theme.of(context).hintColor;
    return InkWell(
      onTap: () =>
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => RatingSummaryScreen(matchId: m.id),
            ),
          ).then((_) {
            // Beim Zurückkehren Noten-Schnitt der Liste aktualisieren.
            if (mounted) _load();
          }),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            _logo(_ownLogo),
            const SizedBox(width: 6),
            // Spielstand (farbig) bzw. „vs" bei kommenden Spielen.
            Container(
              width: 56,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(vertical: 4),
              decoration: BoxDecoration(
                color: finished
                    ? c.withValues(alpha: 0.12)
                    : Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                finished ? '${m.ownScore}:${m.opponentScore}' : 'vs',
                style: TextStyle(fontWeight: FontWeight.w800, color: c),
              ),
            ),
            const SizedBox(width: 6),
            _logo(m.opponentLogoPath),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${m.venue == Venue.home ? 'H' : 'A'} · ${m.opponentName}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Row(
                    children: [
                      if (finished) ...[
                        Text(
                          _outcomeLetter(m),
                          style: TextStyle(
                            color: c,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const Text(
                          '  ·  ',
                          style: TextStyle(color: Colors.grey),
                        ),
                      ],
                      Flexible(
                        child: Text(
                          m.kickoff != null
                              ? _df.format(m.kickoff!.toLocal())
                              : '—',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (avg != null)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.star, size: 16, color: Colors.amber.shade700),
                  const SizedBox(width: 3),
                  Text(
                    '${avg.toStringAsFixed(1)} ($rated)',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ],
              )
            else
              Text('–', style: TextStyle(color: Theme.of(context).hintColor)),
          ],
        ),
      ),
    );
  }
}
