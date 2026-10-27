import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/activity.dart';
import '../models/enums.dart';
import '../models/match.dart';
import '../state/app_state.dart';
import '../widgets/team_logo.dart';
import 'cards_suspensions_screen.dart';
import 'home_screen.dart';
import 'inbox_screen.dart';
import 'live_match_screen.dart';
import 'match_center_screen.dart';
import 'material_duty_screen.dart';
import 'nachholen_screen.dart';
import 'statistics_hub_screen.dart';
import 'todos_screen.dart';

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
        actions: [_inboxBell(context, state)],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          if (live != null) _liveCard(context, live),
          if (next != null)
            _nextCard(context, next, team?.logoPath)
          else if (live == null)
            _emptyCard(context),
          _offenePunkte(context, state),
          const SizedBox(height: 8),
          _shortcuts(context, state),
          const SizedBox(height: 8),
          const _ActivityFeed(),
        ],
      ),
    );
  }

  /// Glocke mit Zähler ungelesener Posteingang-Einträge.
  Widget _inboxBell(BuildContext context, AppState state) {
    return FutureBuilder<int>(
      future: state.inboxUnreadCount(),
      builder: (context, snap) {
        final n = snap.data ?? 0;
        final icon = IconButton(
          tooltip: 'Posteingang',
          icon: const Icon(Icons.notifications_outlined),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const InboxScreen()),
          ),
        );
        if (n <= 0) return icon;
        return Badge.count(count: n, child: icon);
      },
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

  Widget _teamLogo(String? path, ColorScheme scheme) => path != null
      ? TeamLogo(logoPath: path, size: 36)
      : Icon(Icons.shield_outlined, size: 32, color: scheme.outline);

  Widget _nextCard(BuildContext context, GameMatch m, String? ownLogo) {
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
              const SizedBox(height: 12),
              Row(
                children: [
                  _teamLogo(ownLogo, scheme),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10),
                    child: Text(
                      'vs',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  _teamLogo(m.opponentLogoPath, scheme),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          m.opponentName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(
                          [
                            m.venue == Venue.home ? 'Heim' : 'Auswärts',
                            if (m.kickoff != null)
                              df.format(m.kickoff!.toLocal()),
                          ].join(' · '),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
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

  Widget _offenePunkte(BuildContext context, AppState state) {
    final isTrainer = state.isTrainerHere;
    final scheme = Theme.of(context).colorScheme;
    Widget line({
      required IconData icon,
      required String label,
      required Future<int> count,
      required Widget screen,
    }) {
      return FutureBuilder<int>(
        future: count,
        builder: (context, snap) {
          final n = snap.data ?? 0;
          return ListTile(
            leading: Icon(icon, color: scheme.primary),
            title: Text(label),
            trailing: n <= 0
                ? Text(
                    'erledigt',
                    style: TextStyle(color: Theme.of(context).hintColor),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Badge(label: Text('$n')),
                      const SizedBox(width: 8),
                      const Icon(Icons.chevron_right),
                    ],
                  ),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => screen),
            ),
          );
        },
      );
    }

    return Card(
      child: Column(
        children: [
          if (isTrainer)
            line(
              icon: Icons.playlist_add_check_circle,
              label: 'Nachholen',
              count: state.nachholenCount(),
              screen: const NachholenScreen(),
            ),
          line(
            icon: Icons.checklist,
            label: 'Offene Aufgaben',
            count: state.openTodoCount(),
            screen: const TodosScreen(),
          ),
        ],
      ),
    );
  }

  /// Schnellzugriff auf häufig genutzte Neben-Funktionen (nicht die Haupt-Tabs
  /// aus der unteren Leiste doppeln).
  Widget _shortcuts(BuildContext context, AppState state) {
    final team = state.ownTeam;
    void push(Widget s) =>
        Navigator.push(context, MaterialPageRoute(builder: (_) => s));
    Widget tile(IconData icon, String label, VoidCallback onTap) => Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
          child: Column(
            children: [
              Icon(icon, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 6),
              Text(
                label,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
    return Card(
      child: Row(
        children: [
          tile(
            Icons.insights,
            'Statistik',
            () => push(const StatisticsHubScreen()),
          ),
          if (team != null)
            tile(
              Icons.sports_soccer,
              'Materialdienst',
              () => push(
                MaterialDutyScreen(teamId: team.id, teamName: team.name),
              ),
            ),
          tile(
            Icons.style_outlined,
            'Karten &\nSperren',
            () => push(const CardsSuspensionsScreen()),
          ),
        ],
      ),
    );
  }
}

/// Aktivitäten-Feed: die letzten Team-Aktionen (cloud-synchron). Zeigt 3
/// Einträge; der Rest (bis 10) ist einklappbar.
class _ActivityFeed extends StatefulWidget {
  const _ActivityFeed();

  @override
  State<_ActivityFeed> createState() => _ActivityFeedState();
}

class _ActivityFeedState extends State<_ActivityFeed> {
  static const _collapsed = 3;
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<List<Activity>>(
      future: state.recentActivities(limit: 10),
      builder: (context, snap) {
        final items = snap.data ?? const <Activity>[];
        final visible = _expanded ? items : items.take(_collapsed).toList();
        final hidden = items.length - _collapsed;
        return Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                child: Row(
                  children: [
                    Icon(Icons.bolt, size: 18, color: scheme.primary),
                    const SizedBox(width: 8),
                    const Text(
                      'Aktivitäten',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
              if (items.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Text(
                    'Noch keine Aktivitäten. Sie erscheinen hier, sobald im '
                    'Team etwas erfasst wird (Bewertungen, Tore, Zu-/Absagen …).',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                )
              else ...[
                for (final a in visible) _activityTile(context, a),
                if (hidden > 0)
                  Center(
                    child: TextButton.icon(
                      onPressed: () => setState(() => _expanded = !_expanded),
                      icon: Icon(
                        _expanded ? Icons.expand_less : Icons.expand_more,
                        size: 18,
                      ),
                      label: Text(
                        _expanded
                            ? 'Weniger anzeigen'
                            : 'Mehr anzeigen ($hidden)',
                      ),
                    ),
                  ),
              ],
              const SizedBox(height: 6),
            ],
          ),
        );
      },
    );
  }
}

Widget _activityTile(BuildContext context, Activity a) {
  final scheme = Theme.of(context).colorScheme;
  final main = a.subtitle == null ? a.title : '${a.title} · ${a.subtitle}';
  return ListTile(
    dense: true,
    visualDensity: VisualDensity.compact,
    leading: Icon(_activityIcon(a.type), color: scheme.primary, size: 20),
    title: Text(main, maxLines: 1, overflow: TextOverflow.ellipsis),
    subtitle: Text(
      '${a.actorName} · ${_relativeTime(a.createdAt)}',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
  );
}

IconData _activityIcon(ActivityType t) => switch (t) {
  ActivityType.rating => Icons.star_rounded,
  ActivityType.goal => Icons.sports_soccer,
  ActivityType.card => Icons.style,
  ActivityType.nomination => Icons.how_to_reg,
  ActivityType.status => Icons.event_busy,
  ActivityType.lineup => Icons.grid_view,
  ActivityType.result => Icons.scoreboard_outlined,
  ActivityType.todo => Icons.check_circle_outline,
  ActivityType.playerOfMonth => Icons.emoji_events_outlined,
  ActivityType.other => Icons.bolt,
};

String _relativeTime(DateTime dt) {
  final d = DateTime.now().difference(dt);
  if (d.inMinutes < 1) return 'gerade eben';
  if (d.inMinutes < 60) return 'vor ${d.inMinutes} Min';
  if (d.inHours < 24) return 'vor ${d.inHours} Std';
  if (d.inDays < 7) return 'vor ${d.inDays} Tg';
  return DateFormat('dd.MM.', 'de_DE').format(dt);
}
