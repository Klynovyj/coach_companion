import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/enums.dart';
import '../models/match.dart';
import '../state/app_state.dart';
import '../widgets/team_logo.dart';
import 'home_screen.dart';
import 'live_match_screen.dart';
import 'match_center_screen.dart';

/// Start-/Heute-Bildschirm: das Wichtigste auf einen Blick (laufendes/nächstes
/// Spiel + Schnellzugriff). Wird in weiteren Schritten ausgebaut.
class StartScreen extends StatelessWidget {
  const StartScreen({super.key});

  GameMatch? _liveMatch(List<GameMatch> matches) =>
      matches.where((m) => m.status == MatchStatus.live).firstOrNull;

  GameMatch? _nextMatch(List<GameMatch> matches) {
    final upcoming =
        matches
            .where((m) => m.status != MatchStatus.finished && m.kickoff != null)
            .toList()
          ..sort((a, b) => a.kickoff!.compareTo(b.kickoff!));
    return upcoming.firstOrNull;
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final team = state.ownTeam;
    final matches = state.matches;
    final live = _liveMatch(matches);
    final next = _nextMatch(matches);

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            if (team?.logoPath != null) ...[
              TeamLogo(logoPath: team!.logoPath, size: 26),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Text(
                team?.name ?? 'myCoach',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          if (live != null) _liveCard(context, live),
          if (next != null)
            _nextCard(context, next)
          else if (live == null)
            _emptyCard(context),
          const SizedBox(height: 8),
          _quickAccess(context),
        ],
      ),
    );
  }

  Widget _liveCard(BuildContext context, GameMatch m) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      child: ListTile(
        leading: Icon(Icons.sports_soccer, color: scheme.error),
        title: const Text(
          'Live-Spiel läuft',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          'vs ${m.opponentName}  ·  '
          '${m.ownScore}:${m.opponentScore}',
        ),
        trailing: FilledButton(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => LiveMatchScreen(matchId: m.id)),
          ),
          child: const Text('Öffnen'),
        ),
      ),
    );
  }

  Widget _nextCard(BuildContext context, GameMatch m) {
    final df = DateFormat('EEE, dd.MM.yyyy · HH:mm', 'de_DE');
    final scheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => MatchCenterScreen(matchId: m.id)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.event, color: scheme.primary),
                  const SizedBox(width: 8),
                  const Text(
                    'Nächstes Spiel',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '${m.venue == Venue.home ? 'Heim' : 'Auswärts'} · '
                'vs ${m.opponentName}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (m.kickoff != null)
                Text(
                  df.format(m.kickoff!.toLocal()),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(Icons.how_to_reg, size: 16, color: scheme.primary),
                  const SizedBox(width: 6),
                  const Expanded(
                    child: Text(
                      'Nominieren · Aufstellen · Live',
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),
                  const Icon(Icons.chevron_right),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _emptyCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            const Icon(Icons.event_available, size: 40, color: Colors.grey),
            const SizedBox(height: 10),
            const Text('Kein anstehendes Spiel.', textAlign: TextAlign.center),
            const SizedBox(height: 10),
            FilledButton.tonalIcon(
              onPressed: () => homeTabNotifier.value = 1,
              icon: const Icon(Icons.event_note),
              label: const Text('Zum Spielplan'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _quickAccess(BuildContext context) {
    Widget tile(IconData icon, String label, int tab) => Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => homeTabNotifier.value = tab,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(
            children: [
              Icon(icon, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 6),
              Text(label, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
    return Card(
      child: Row(
        children: [
          tile(Icons.event_note, 'Spielplan', 1),
          tile(Icons.groups, 'Kader', 2),
          tile(Icons.apps, 'Mehr', 3),
        ],
      ),
    );
  }
}
