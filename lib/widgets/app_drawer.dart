import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../screens/settings_screen.dart';
import '../screens/todos_screen.dart';
import '../state/app_state.dart';
import 'team_logo.dart';

/// Seitenmenü (☰) für alle Bereiche außerhalb der unteren Haupt-Tabs.
/// Hier kommen künftige Funktionen dazu.
class AppDrawer extends StatelessWidget {
  const AppDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    final team = context.watch<AppState>().ownTeam;
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
            _tile(
              context,
              icon: Icons.checklist,
              label: 'Aufgaben',
              trailing: _TodoBadge(),
              screen: const TodosScreen(),
            ),
            const Divider(),
            _tile(
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
      onTap: () {
        Navigator.pop(context); // Drawer schließen
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => screen),
        );
      },
    );
  }
}

/// Zeigt die Anzahl offener Aufgaben als Badge.
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
