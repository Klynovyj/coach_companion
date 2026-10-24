import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/update_service.dart';
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

/// Gewählter Start-Tab. Global, damit das Menü den Tab auch aus aufgeschobenen
/// Seiten heraus umschalten kann (danach zurück zur Startseite springen).
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

    final index = homeTabNotifier.value.clamp(0, pages.length - 1);
    // Navigation läuft über das Seitenmenü (☰) – keine untere Leiste mehr.
    return HomeNav(
      index: index,
      onSelect: (i) => homeTabNotifier.value = i,
      child: Scaffold(body: pages[index]),
    );
  }
}
