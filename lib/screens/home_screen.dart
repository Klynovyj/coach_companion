import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/update_service.dart';
import '../state/app_state.dart';
import 'more_screen.dart';
import 'schedule_screen.dart';
import 'squad_screen.dart';
import 'start_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

/// Stellt den aktuellen Haupt-Tab und das Umschalten bereit – damit auch andere
/// Stellen die unteren Bereiche wechseln können.
class HomeNav extends InheritedWidget {
  const HomeNav({
    super.key,
    required this.index,
    required this.onSelect,
    required super.child,
  });

  final int index;
  final void Function(int) onSelect;

  static HomeNav? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HomeNav>();

  @override
  bool updateShouldNotify(HomeNav old) => old.index != index;
}

/// Gewählter Start-Tab (untere Leiste). Global, damit das Umschalten auch aus
/// aufgeschobenen Seiten heraus funktioniert (danach zurück zur Startseite).
/// 0 = Start, 1 = Spielplan, 2 = Kader, 3 = Mehr.
final ValueNotifier<int> homeTabNotifier = ValueNotifier<int>(0);

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    homeTabNotifier.addListener(_onTabChanged);
    // Einmal beim Start auf App-Updates prüfen (nur Android, still).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) UpdateService.promptIfAvailable(context);
    });
  }

  @override
  void dispose() {
    homeTabNotifier.removeListener(_onTabChanged);
    super.dispose();
  }

  void _onTabChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (state.loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    const pages = [
      StartScreen(),
      ScheduleScreen(),
      SquadScreen(),
      MoreScreen(),
    ];

    final index = homeTabNotifier.value.clamp(0, pages.length - 1);
    return HomeNav(
      index: index,
      onSelect: (i) => homeTabNotifier.value = i,
      child: Scaffold(
        body: pages[index],
        bottomNavigationBar: NavigationBar(
          selectedIndex: index,
          onDestinationSelected: (i) => homeTabNotifier.value = i,
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home),
              label: 'Start',
            ),
            NavigationDestination(
              icon: Icon(Icons.event_note_outlined),
              selectedIcon: Icon(Icons.event_note),
              label: 'Spielplan',
            ),
            NavigationDestination(
              icon: Icon(Icons.groups_outlined),
              selectedIcon: Icon(Icons.groups),
              label: 'Kader',
            ),
            NavigationDestination(
              icon: Icon(Icons.apps_outlined),
              selectedIcon: Icon(Icons.apps),
              label: 'Mehr',
            ),
          ],
        ),
      ),
    );
  }
}
