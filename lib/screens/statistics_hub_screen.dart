import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'cards_suspensions_screen.dart';
import 'club_stats_screen.dart';
import 'rating_overview_screen.dart';
import 'season_stats_screen.dart';
import 'stats_screen.dart';

/// Zentrale Statistik-Seite: alle Statistiken in einem Ort, als Reiter.
/// Team · Spieler · Verein · Noten · Karten. Der Verein-Reiter (FuPa-Laufbahn
/// aller Spieler, Netzwerk) wird erst beim ersten Öffnen geladen.
class StatisticsHubScreen extends StatefulWidget {
  const StatisticsHubScreen({super.key, this.initialTab = 0});

  final int initialTab;

  @override
  State<StatisticsHubScreen> createState() => _StatisticsHubScreenState();
}

class _StatisticsHubScreenState extends State<StatisticsHubScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(
    length: 5,
    vsync: this,
    initialIndex: widget.initialTab,
  );
  late final Set<int> _visited = {widget.initialTab};

  @override
  void initState() {
    super.initState();
    _tab.addListener(() {
      if (!_visited.contains(_tab.index)) {
        setState(() => _visited.add(_tab.index));
      }
    });
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final team = context.read<AppState>().ownTeam;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Statistik'),
        bottom: TabBar(
          controller: _tab,
          isScrollable: true,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          indicatorColor: Colors.white,
          dividerColor: Colors.transparent,
          tabs: const [
            Tab(text: 'Team'),
            Tab(text: 'Spieler'),
            Tab(text: 'Verein'),
            Tab(text: 'Noten'),
            Tab(text: 'Karten'),
          ],
        ),
      ),
      body: team == null
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('Keine Mannschaft.', textAlign: TextAlign.center),
              ),
            )
          : TabBarView(
              controller: _tab,
              children: [
                const SeasonStatsScreen(embedded: true),
                StatsScreen(
                  teamId: team.id,
                  teamName: team.name,
                  fupaUrl: team.fupaUrl,
                  embedded: true,
                ),
                // Verein: Netzwerk je Spieler – erst beim ersten Öffnen laden.
                _visited.contains(2)
                    ? const ClubStatsScreen(embedded: true)
                    : const _LoadOnOpen(),
                const RatingOverviewScreen(embedded: true),
                const CardsSuspensionsScreen(embedded: true),
              ],
            ),
    );
  }
}

/// Platzhalter für den Verein-Reiter, bis er ausgewählt wird.
class _LoadOnOpen extends StatelessWidget {
  const _LoadOnOpen();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'Vereins-Bilanz wird beim Öffnen dieses Reiters geladen …',
          textAlign: TextAlign.center,
          style: TextStyle(color: Theme.of(context).hintColor),
        ),
      ),
    );
  }
}
