import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'nachholen_screen.dart';
import 'schedule_screen.dart';
import 'spielergespraeche_screen.dart';
import 'squad_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

/// Stellt den aktuellen Haupt-Tab und das Umschalten bereit – damit auch das
/// Seitenmenü (Drawer) die unteren Bereiche wechseln kann.
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
      SpielergespraecheScreen(),
    ];

    // Navigation läuft über das Seitenmenü (☰) – keine untere Leiste mehr.
    return HomeNav(
      index: _index,
      onSelect: (i) => setState(() => _index = i),
      child: Scaffold(body: pages[_index]),
    );
  }
}
