import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../models/training_session.dart';
import '../../state/app_state.dart';
import 'exercise_library_screen.dart';
import 'session_editor_screen.dart';

/// Trainings-Start: geplante Einheiten + Zugang zur Übungs-Bibliothek.
class TrainingHomeScreen extends StatefulWidget {
  const TrainingHomeScreen({super.key});

  @override
  State<TrainingHomeScreen> createState() => _TrainingHomeScreenState();
}

class _TrainingHomeScreenState extends State<TrainingHomeScreen> {
  final _df = DateFormat('EEE, dd.MM.yyyy', 'de_DE');

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(title: const Text('Training')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const SessionEditorScreen()),
          );
          if (mounted) setState(() {});
        },
        icon: const Icon(Icons.add),
        label: const Text('Neue Einheit'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.menu_book),
              title: const Text('Übungs-Bibliothek'),
              subtitle: const Text(
                'Übungen anlegen, bearbeiten, wiederverwenden',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const ExerciseLibraryScreen(),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 4, 4, 6),
            child: Text(
              'Geplante Einheiten',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
          ),
          FutureBuilder<List<TrainingSession>>(
            future: state.trainingSessions(),
            builder: (context, snap) {
              final list = snap.data ?? const <TrainingSession>[];
              if (list.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Noch keine Einheit geplant. Lege eine neue an.',
                    style: TextStyle(color: Colors.grey),
                  ),
                );
              }
              return Column(
                children: [for (final s in list) _sessionTile(context, s)],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _sessionTile(BuildContext context, TrainingSession s) {
    final parts = <String>[
      '${s.fieldPlayers} Feld + ${s.goalkeepers} TW',
      if (s.categories.isNotEmpty) s.categories.join(', '),
    ];
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: const Icon(Icons.fitness_center),
        title: Text(_df.format(s.date)),
        subtitle: Text(parts.join(' · ')),
        trailing: const Icon(Icons.chevron_right),
        onTap: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => SessionEditorScreen(initial: s)),
          );
          if (mounted) setState(() {});
        },
      ),
    );
  }
}
