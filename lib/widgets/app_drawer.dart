import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../screens/home_screen.dart';
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
    (Icons.event, 'Termine'),
  ];

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final team = state.ownTeam;
    final nav = HomeNav.maybeOf(context);

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
                mainAxisAlignment: MainAxisAlignment.end,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (team?.logoPath != null)
                    TeamLogo(logoPath: team!.logoPath, size: 44),
                  const SizedBox(height: 8),
                  Text(
                    team?.name ?? 'Coach Companion',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
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
