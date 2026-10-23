import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'nachholen_screen.dart';
import 'schedule_screen.dart';
import 'settings_screen.dart';
import 'squad_screen.dart';
import 'termine_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (state.loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final pages = const [
      ScheduleScreen(),
      SquadScreen(),
      NachholenScreen(),
      TermineScreen(),
      SettingsScreen(),
    ];

    return Scaffold(
      body: pages[_index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          const NavigationDestination(
              icon: Icon(Icons.event_note_outlined),
              selectedIcon: Icon(Icons.event_note),
              label: 'Spielplan'),
          const NavigationDestination(
              icon: Icon(Icons.groups_outlined),
              selectedIcon: Icon(Icons.groups),
              label: 'Kader'),
          NavigationDestination(
              icon: _NachholenIcon(state: state, outlined: true),
              selectedIcon: _NachholenIcon(state: state, outlined: false),
              label: 'Nachholen'),
          const NavigationDestination(
              icon: Icon(Icons.event_outlined),
              selectedIcon: Icon(Icons.event),
              label: 'Termine'),
          const NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: 'Einstellungen'),
        ],
      ),
    );
  }
}

/// Nachholen-Icon mit Anzahl-Badge der offenen Punkte.
class _NachholenIcon extends StatelessWidget {
  const _NachholenIcon({required this.state, required this.outlined});
  final AppState state;
  final bool outlined;

  @override
  Widget build(BuildContext context) {
    final icon = Icon(outlined ? Icons.playlist_add_check_circle_outlined
        : Icons.playlist_add_check_circle);
    return FutureBuilder<int>(
      future: state.nachholenCount(),
      builder: (context, snap) {
        final n = snap.data ?? 0;
        if (n <= 0) return icon;
        return Badge(label: Text('$n'), child: icon);
      },
    );
  }
}
