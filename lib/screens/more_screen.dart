import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'cards_suspensions_screen.dart';
import 'material_duty_screen.dart';
import 'nachholen_screen.dart';
import 'player_of_month_screen.dart';
import 'absence_overview_screen.dart';
import 'inbox_screen.dart';
import 'rating_overview_screen.dart';
import 'settings_screen.dart';
import 'statistics_hub_screen.dart';
import 'spielergespraeche_screen.dart';
import 'sponsors_screen.dart';
import 'todos_screen.dart';

/// Sammelstelle für Neben-Funktionen (statt eines überladenen Menüs). Die
/// Haupt-Bereiche sind in der unteren Leiste; hier liegt der Rest.
class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final team = state.ownTeam;
    final isTrainer = state.isTrainerHere;

    return Scaffold(
      appBar: AppBar(title: const Text('Mehr')),
      body: ListView(
        children: [
          _group(context, 'Posteingang'),
          _tile(
            context,
            icon: Icons.inbox,
            label: 'Posteingang',
            screen: const InboxScreen(),
            trailing: _Badge(future: state.inboxUnreadCount()),
          ),
          _group(context, 'Statistik'),
          _tile(
            context,
            icon: Icons.insights,
            label: 'Statistik (alles an einem Ort)',
            screen: const StatisticsHubScreen(),
          ),
          _group(context, 'Team'),
          _tile(
            context,
            icon: Icons.event_busy,
            label: 'Abwesenheit',
            screen: const AbsenceOverviewScreen(),
          ),
          _tile(
            context,
            icon: Icons.record_voice_over,
            label: 'Spielergespräche',
            screen: const SpielergespraecheScreen(),
          ),
          if (isTrainer)
            _tile(
              context,
              icon: Icons.playlist_add_check_circle,
              label: 'Nachholen (Bewertungen)',
              screen: const NachholenScreen(),
              trailing: _Badge(future: state.nachholenCount()),
            ),
          if (isTrainer)
            _tile(
              context,
              icon: Icons.assessment_outlined,
              label: 'Spielbericht & Voting',
              screen: const RatingOverviewScreen(),
            ),
          _tile(
            context,
            icon: Icons.checklist,
            label: 'Aufgaben',
            screen: const TodosScreen(),
            trailing: _Badge(future: state.openTodoCount()),
          ),
          _group(context, 'Organisation'),
          if (team != null)
            ListTile(
              leading: const Icon(Icons.sports_soccer),
              title: const Text('Ball-/Materialdienst'),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      MaterialDutyScreen(teamId: team.id, teamName: team.name),
                ),
              ),
            ),
          _tile(
            context,
            icon: Icons.emoji_events,
            label: 'Ehrungen',
            screen: const PlayerOfMonthScreen(),
          ),
          _tile(
            context,
            icon: Icons.style_outlined,
            label: 'Karten & Sperren',
            screen: const CardsSuspensionsScreen(),
          ),
          _tile(
            context,
            icon: Icons.handshake_outlined,
            label: 'Sponsoring',
            screen: const SponsorsScreen(),
          ),
          const Divider(),
          _tile(
            context,
            icon: Icons.settings_outlined,
            label: 'Einstellungen',
            screen: const SettingsScreen(),
          ),
          const SizedBox(height: 16),
          _versionFooter(context),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  /// Versionsanzeige unten im Menü (aus dem App-Paket).
  Widget _versionFooter(BuildContext context) {
    return FutureBuilder<PackageInfo>(
      future: PackageInfo.fromPlatform(),
      builder: (context, snap) {
        final info = snap.data;
        final text = info == null
            ? ''
            : 'myCoach · Version ${info.version} (${info.buildNumber})';
        return Center(
          child: Text(
            text,
            style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12),
          ),
        );
      },
    );
  }

  Widget _group(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(
      title,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.bold,
      ),
    ),
  );

  Widget _tile(
    BuildContext context, {
    required IconData icon,
    required String label,
    required Widget screen,
    Widget? trailing,
  }) {
    return ListTile(
      leading: Icon(icon),
      title: Text(label),
      trailing: trailing,
      onTap: () =>
          Navigator.push(context, MaterialPageRoute(builder: (_) => screen)),
    );
  }
}

/// Kleines Zähl-Badge (z.B. offene Aufgaben/Nachhol-Punkte).
class _Badge extends StatelessWidget {
  const _Badge({required this.future});
  final Future<int> future;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<int>(
      future: future,
      builder: (context, snap) {
        final n = snap.data ?? 0;
        if (n <= 0) return const Icon(Icons.chevron_right);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Badge(label: Text('$n')),
            const SizedBox(width: 6),
            const Icon(Icons.chevron_right),
          ],
        );
      },
    );
  }
}
