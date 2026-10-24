import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/enums.dart';
import '../screens/home_screen.dart';
import '../screens/live_match_screen.dart';
import '../screens/material_duty_screen.dart';
import '../screens/settings_screen.dart';
import '../screens/todos_screen.dart';
import '../state/app_state.dart';
import 'team_logo.dart';

/// Seitenmenü (☰) mit allen Bereichen: die unteren Haupt-Tabs (wechseln den
/// Tab) sowie weitere Funktionen (öffnen als eigene Seite). Hier kommen
/// künftige Funktionen dazu.
class AppDrawer extends StatelessWidget {
  const AppDrawer({super.key});

  static const _mainSections = <(IconData, String)>[
    (Icons.event_note, 'Spielplan'),
    (Icons.groups, 'Kader'),
    (Icons.playlist_add_check_circle, 'Nachholen'),
    (Icons.record_voice_over, 'Spielergespräche'),
  ];

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final team = state.ownTeam;
    final nav = HomeNav.maybeOf(context);
    final live = state.matches
        .where((m) => m.status == MatchStatus.live)
        .toList();

    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            DrawerHeader(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _HeaderClock(),
                  const Spacer(),
                  if (team?.logoPath != null)
                    TeamLogo(logoPath: team!.logoPath, size: 36),
                  const SizedBox(height: 6),
                  Text(
                    team?.name ?? 'myCouch',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            // Laufendes Live-Spiel – direkt reinspringen.
            if (live.isNotEmpty)
              Container(
                color: Theme.of(context).colorScheme.errorContainer,
                child: ListTile(
                  leading: Icon(Icons.sports_soccer,
                      color: Theme.of(context).colorScheme.error),
                  title: const Text('Live-Spiel läuft',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text('vs ${live.first.opponentName}'),
                  trailing: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.error,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text('LIVE',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.bold)),
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            LiveMatchScreen(matchId: live.first.id),
                      ),
                    );
                  },
                ),
              ),
            // Haupt-Bereiche (wechseln den unteren Tab).
            for (var i = 0; i < _mainSections.length; i++)
              ListTile(
                leading: Icon(_mainSections[i].$1),
                title: Text(_mainSections[i].$2),
                selected: nav?.index == i,
                trailing: i == 2 ? _NachholenBadge() : null,
                onTap: () {
                  Navigator.pop(context);
                  nav?.onSelect(i);
                },
              ),
            const Divider(),
            // Weitere Funktionen (eigene Seiten).
            _push(
              context,
              icon: Icons.checklist,
              label: 'Aufgaben',
              trailing: _TodoBadge(),
              screen: const TodosScreen(),
            ),
            if (team != null)
              ListTile(
                leading: const Icon(Icons.sports_soccer),
                title: const Text('Ball-/Materialdienst'),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => MaterialDutyScreen(
                        teamId: team.id,
                        teamName: team.name,
                      ),
                    ),
                  );
                },
              ),
            _push(
              context,
              icon: Icons.settings_outlined,
              label: 'Einstellungen',
              screen: const SettingsScreen(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _push(
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
      onTap: () {
        Navigator.pop(context); // Drawer schließen
        Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
      },
    );
  }
}

/// Live-Uhr + Datum oben im Menükopf.
class _HeaderClock extends StatefulWidget {
  const _HeaderClock();

  @override
  State<_HeaderClock> createState() => _HeaderClockState();
}

class _HeaderClockState extends State<_HeaderClock> {
  Timer? _timer;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final onP = Theme.of(context).colorScheme.onPrimary;
    final time = DateFormat("HH:mm:ss 'Uhr'", 'de_DE').format(_now);
    final date = DateFormat('EEEE, dd.MM.yyyy', 'de_DE').format(_now);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(time,
            style: TextStyle(
                color: onP, fontSize: 20, fontWeight: FontWeight.bold)),
        Text(date,
            style: TextStyle(
                color: onP.withValues(alpha: 0.85), fontSize: 12)),
      ],
    );
  }
}

/// Anzahl offener Nachhol-Punkte.
class _NachholenBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return FutureBuilder<int>(
      future: context.watch<AppState>().nachholenCount(),
      builder: (context, snap) {
        final n = snap.data ?? 0;
        if (n <= 0) return const SizedBox.shrink();
        return Badge(label: Text('$n'));
      },
    );
  }
}

/// Anzahl offener Aufgaben.
class _TodoBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return FutureBuilder<int>(
      future: context.watch<AppState>().openTodoCount(),
      builder: (context, snap) {
        final n = snap.data ?? 0;
        if (n <= 0) return const SizedBox.shrink();
        return Badge(label: Text('$n'));
      },
    );
  }
}
