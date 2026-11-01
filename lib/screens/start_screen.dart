import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/activity.dart';
import '../models/enums.dart';
import '../models/match.dart';
import '../state/app_state.dart';
import '../widgets/team_logo.dart';
import 'training/training_home_screen.dart';
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
          _seasonSection(context, matches),
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
                  if (m.kickoff != null) ...[
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.primaryContainer,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.timer_outlined,
                            size: 14,
                            color: scheme.onPrimaryContainer,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _countdown(m.kickoff!.toLocal()),
                            style: TextStyle(
                              color: scheme.onPrimaryContainer,
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
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

  /// Verbleibende Zeit bis zum Anstoß, grob gerundet.
  String _countdown(DateTime kickoff) {
    final diff = kickoff.difference(DateTime.now());
    if (diff.isNegative) return 'gleich';
    if (diff.inDays >= 1) return 'in ${diff.inDays} Tag${diff.inDays == 1 ? '' : 'en'}';
    if (diff.inHours >= 1) return 'in ${diff.inHours} Std';
    if (diff.inMinutes >= 1) return 'in ${diff.inMinutes} Min';
    return 'gleich';
  }

  /// Abschnitt „Form & Bilanz": Form-Streifen der letzten 5 + Kennzahl-Kacheln.
  /// Ganz aus den beendeten Spielen berechnet (keine Extra-Daten nötig).
  Widget _seasonSection(BuildContext context, List<GameMatch> matches) {
    final finished =
        matches.where((m) => m.status == MatchStatus.finished).toList()
          ..sort(
            (a, b) =>
                (a.kickoff ?? a.createdAt).compareTo(b.kickoff ?? b.createdAt),
          );
    if (finished.isEmpty) return const SizedBox.shrink();

    var w = 0, d = 0, l = 0, gf = 0, ga = 0;
    var hw = 0, hd = 0, hl = 0, aw = 0, ad = 0, al = 0;
    for (final m in finished) {
      gf += m.ownScore;
      ga += m.opponentScore;
      final r = m.ownScore.compareTo(m.opponentScore);
      final home = m.venue == Venue.home;
      if (r > 0) {
        w++;
        home ? hw++ : aw++;
      } else if (r == 0) {
        d++;
        home ? hd++ : ad++;
      } else {
        l++;
        home ? hl++ : al++;
      }
    }
    final diff = gf - ga;
    final last5 = finished.length <= 5
        ? finished
        : finished.sublist(finished.length - 5);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        _sectionTitle(context, Icons.trending_up, 'Form & Bilanz'),
        _formCard(context, last5),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _statTile(
                context,
                Icons.emoji_events_outlined,
                'Bilanz',
                '$w–$d–$l',
                sub: 'S · U · N',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _statTile(
                context,
                Icons.sports_soccer,
                'Tore',
                '$gf : $ga',
                sub: 'Differenz ${diff >= 0 ? '+' : ''}$diff',
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _statTile(
                context,
                Icons.home_outlined,
                'Heim',
                '$hw–$hd–$hl',
                sub: 'S · U · N',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _statTile(
                context,
                Icons.directions_bus_outlined,
                'Auswärts',
                '$aw–$ad–$al',
                sub: 'S · U · N',
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _sectionTitle(BuildContext context, IconData icon, String label) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
      child: Row(
        children: [
          Icon(icon, size: 18, color: scheme.primary),
          const SizedBox(width: 8),
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  /// Form-Streifen: je Spiel ein farbiger Punkt S/U/N (älter → neuer).
  Widget _formCard(BuildContext context, List<GameMatch> last5) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Text(
              'Form',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const Spacer(),
            for (final m in last5) ...[
              _formDot(context, m),
              const SizedBox(width: 6),
            ],
          ],
        ),
      ),
    );
  }

  Widget _formDot(BuildContext context, GameMatch m) {
    final r = m.ownScore.compareTo(m.opponentScore);
    final (color, letter) = r > 0
        ? (const Color(0xFF2E7D32), 'S')
        : r == 0
        ? (const Color(0xFF9E9E9E), 'U')
        : (const Color(0xFFC62828), 'N');
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => MatchCenterScreen(matchId: m.id)),
      ),
      child: Container(
        width: 30,
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: Text(
          letter,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w900,
            fontSize: 14,
          ),
        ),
      ),
    );
  }

  Widget _statTile(
    BuildContext context,
    IconData icon,
    String label,
    String value, {
    String? sub,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: scheme.primary),
              const SizedBox(width: 6),
              Text(label, style: Theme.of(context).textTheme.labelMedium),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            value,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          if (sub != null) ...[
            const SizedBox(height: 2),
            Text(
              sub,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).hintColor,
              ),
            ),
          ],
        ],
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
            Icons.fitness_center,
            'Training',
            () => push(const TrainingHomeScreen()),
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
