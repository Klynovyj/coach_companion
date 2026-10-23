import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../widgets/app_drawer.dart';
import 'match_center_screen.dart';
import 'rating_screen.dart';

/// „Nachholen" (wie MS-Teams): offene Punkte, die man später erledigen kann –
/// fehlende Bewertungen, Nominierungen und Aufstellungen. Eigene Aufgaben
/// haben einen eigenen Menüpunkt („Aufgaben").
class NachholenScreen extends StatelessWidget {
  const NachholenScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final df = DateFormat('dd.MM.yyyy', 'de_DE');

    return Scaffold(
      appBar: AppBar(title: const Text('Nachholen')),
      drawer: const AppDrawer(),
      body: FutureBuilder<List<NachholenItem>>(
        future: state.nachholen(),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final items = snap.data!;
          final ratings =
              items.where((i) => i.kind == NachholenKind.rating).toList();
          final noms =
              items.where((i) => i.kind == NachholenKind.nomination).toList();
          final lineups =
              items.where((i) => i.kind == NachholenKind.lineup).toList();

          return ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              if (items.isEmpty) _allClear(context),
              _section(
                context,
                icon: Icons.star_border,
                title: 'Offene Bewertungen',
                items: ratings,
                df: df,
                onTap: (i) => _open(context, RatingScreen(matchId: i.matchId)),
              ),
              _section(
                context,
                icon: Icons.how_to_reg,
                title: 'Offene Nominierungen',
                items: noms,
                df: df,
                onTap: (i) =>
                    _open(context, MatchCenterScreen(matchId: i.matchId)),
              ),
              _section(
                context,
                icon: Icons.dashboard_customize,
                title: 'Fehlende Aufstellung',
                items: lineups,
                df: df,
                onTap: (i) =>
                    _open(context, MatchCenterScreen(matchId: i.matchId)),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _open(BuildContext context, Widget screen) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
  }

  Widget _allClear(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 32, 16, 8),
        child: Column(
          children: [
            Icon(Icons.check_circle,
                size: 48, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 8),
            const Text('Alles erledigt 🎉', textAlign: TextAlign.center),
          ],
        ),
      );

  Widget _section(
    BuildContext context, {
    required IconData icon,
    required String title,
    required List<NachholenItem> items,
    required DateFormat df,
    required void Function(NachholenItem) onTap,
  }) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Row(
                children: [
                  Icon(icon,
                      size: 18, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 8),
                  Text(title,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const Spacer(),
                  _countBadge(context, items.length),
                ],
              ),
            ),
            for (final i in items)
              ListTile(
                contentPadding: const EdgeInsets.only(right: 8),
                title: Text(i.title),
                subtitle: Text([
                  if (i.kickoff != null) df.format(i.kickoff!.toLocal()),
                  i.detail,
                ].join('  ·  ')),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => onTap(i),
              ),
          ],
        ),
      ),
    );
  }

  Widget _countBadge(BuildContext context, int n) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text('$n',
            style: TextStyle(
                color: Theme.of(context).colorScheme.onPrimary,
                fontWeight: FontWeight.bold,
                fontSize: 12)),
      );
}
