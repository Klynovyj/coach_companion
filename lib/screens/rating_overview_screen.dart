import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/enums.dart';
import '../models/match.dart';
import '../state/app_state.dart';
import 'rating_summary_screen.dart';

/// Übersicht aller Spiele mit Bewertungs-Schnitt → antippen öffnet die
/// Auswertung (Trainer-Noten, Berichte, Spieler-Schnitt).
class RatingOverviewScreen extends StatefulWidget {
  const RatingOverviewScreen({super.key});

  @override
  State<RatingOverviewScreen> createState() => _RatingOverviewScreenState();
}

class _RatingOverviewScreenState extends State<RatingOverviewScreen> {
  final _df = DateFormat('EEE, dd.MM.yyyy', 'de_DE');
  List<GameMatch> _matches = [];
  final Map<String, (double?, int, int)> _summaries = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final s = context.read<AppState>();
    final matches = [...s.matches]
      ..sort(
        (a, b) =>
            (b.kickoff ?? b.createdAt).compareTo(a.kickoff ?? a.createdAt),
      );
    _summaries.clear();
    for (final m in matches) {
      _summaries[m.id] = await s.matchRatingSummary(m.id);
    }
    if (!mounted) return;
    setState(() {
      _matches = matches;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Auswertung')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _matches.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('Noch keine Spiele.', textAlign: TextAlign.center),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 6),
              itemCount: _matches.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) => _matchTile(context, _matches[i]),
            ),
    );
  }

  Widget _matchTile(BuildContext context, GameMatch m) {
    final (avg, rated, _) = _summaries[m.id] ?? (null, 0, 0);
    final finished = m.status == MatchStatus.finished;
    final score = finished ? '${m.ownScore}:${m.opponentScore}' : null;
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Icon(
          finished ? Icons.scoreboard : Icons.event,
          size: 20,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
      title: Text(
        '${m.venue == Venue.home ? 'H' : 'A'} · vs ${m.opponentName}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        [
          if (m.kickoff != null) _df.format(m.kickoff!.toLocal()),
          ?score,
        ].join('  ·  '),
      ),
      trailing: avg == null
          ? Text('–', style: TextStyle(color: Theme.of(context).hintColor))
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.star, size: 16, color: Colors.amber.shade700),
                const SizedBox(width: 3),
                Text(
                  '${avg.toStringAsFixed(1)} ($rated)',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ],
            ),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => RatingSummaryScreen(matchId: m.id)),
      ),
    );
  }
}
