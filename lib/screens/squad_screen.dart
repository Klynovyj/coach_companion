import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/team.dart';
import '../state/app_state.dart';
import '../widgets/app_drawer.dart';
import '../widgets/squad_list_view.dart';
import '../widgets/team_logo.dart';
import 'stats_screen.dart';

/// Kader des eigenen Teams.
class SquadScreen extends StatelessWidget {
  const SquadScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final team = state.ownTeam;

    return Scaffold(
      drawer: const AppDrawer(),
      appBar: AppBar(
        title: Row(
          children: [
            if (team?.logoPath != null) ...[
              TeamLogo(logoPath: team!.logoPath, size: 28),
              const SizedBox(width: 8),
            ],
            Flexible(
                child: Text(team?.name ?? 'Mein Kader',
                    maxLines: 1, overflow: TextOverflow.ellipsis)),
          ],
        ),
        actions: [
          if (team != null)
            IconButton(
              tooltip: 'Statistik',
              icon: const Icon(Icons.bar_chart),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => StatsScreen(
                    teamId: team.id,
                    teamName: team.name,
                    fupaUrl: team.fupaUrl,
                  ),
                ),
              ),
            ),
          if (team != null)
            IconButton(
              tooltip: 'Team umbenennen',
              icon: const Icon(Icons.edit),
              onPressed: () => _rename(context, team),
            ),
        ],
      ),
      body: team == null
          ? _NoTeam(onCreate: () => context.read<AppState>().ensureOwnTeam())
          : SquadListView(
              teamId: team.id,
              teamName: team.name,
              fupaUrl: team.fupaUrl,
            ),
    );
  }

  Future<void> _rename(BuildContext context, Team team) async {
    final ctrl = TextEditingController(text: team.name);
    final shortCtrl = TextEditingController(text: team.shortName ?? '');
    final name = await showDialog<String?>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Team umbenennen'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: ctrl,
                decoration: const InputDecoration(labelText: 'Teamname')),
            const SizedBox(height: 10),
            TextField(
                controller: shortCtrl,
                decoration: const InputDecoration(labelText: 'Kurzname')),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () => Navigator.pop(context, ctrl.text.trim()),
              child: const Text('Speichern')),
        ],
      ),
    );
    if (name != null && name.isNotEmpty && context.mounted) {
      await context.read<AppState>().renameTeam(team.id, name,
          shortName: shortCtrl.text.trim().isEmpty ? null : shortCtrl.text.trim());
    }
  }
}

class _NoTeam extends StatelessWidget {
  const _NoTeam({required this.onCreate});
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.shield_outlined, size: 56, color: Colors.grey),
            const SizedBox(height: 12),
            const Text(
              'Noch keine Mannschaft.\nVerbinde einen FuPa-Link in den '
              'Einstellungen oder lege manuell ein Team an.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add),
              label: const Text('Team manuell anlegen'),
            ),
          ],
        ),
      ),
    );
  }
}
