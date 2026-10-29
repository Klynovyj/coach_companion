import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/exercise.dart';
import '../../widgets/drill_diagram_view.dart';
import '../../widgets/team_logo.dart';
import 'exercise_editor_screen.dart';

/// Übung ansehen (mit Bearbeiten-Knopf).
class ExerciseDetailScreen extends StatefulWidget {
  const ExerciseDetailScreen({super.key, required this.exercise});

  final Exercise exercise;

  @override
  State<ExerciseDetailScreen> createState() => _ExerciseDetailScreenState();
}

class _ExerciseDetailScreenState extends State<ExerciseDetailScreen> {
  late Exercise _ex = widget.exercise;

  @override
  Widget build(BuildContext context) {
    final e = _ex;
    final meta = <String>[
      if (e.minPlayers != null) 'ab ${e.minPlayers} Spielern',
      if (e.needsGoalkeeper) 'Torwart nötig',
      if (e.durationMin != null) '${e.durationMin} Min',
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(e.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit),
            onPressed: () async {
              final updated = await Navigator.push<Exercise>(
                context,
                MaterialPageRoute(
                  builder: (_) => ExerciseEditorScreen(initial: e),
                ),
              );
              if (updated != null && mounted) setState(() => _ex = updated);
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 28),
        children: [
          if (e.categories.isNotEmpty)
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [for (final c in e.categories) Chip(label: Text(c))],
            ),
          if (meta.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(meta.join('  ·  ')),
            ),
          if (e.diagram != null) ...[
            const SizedBox(height: 12),
            DrillDiagramView(diagram: e.diagram!),
          ],
          _block('Aufbau', e.aufbau),
          _block('Ablauf', e.ablauf),
          _block('Coaching-Punkte', e.coachingPoints),
          _block('Varianten', e.varianten),
          _block('Material', e.material),
          if (e.videoLinks.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text('Videos', style: TextStyle(fontWeight: FontWeight.bold)),
            for (final link in e.videoLinks)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: const Icon(Icons.ondemand_video),
                title: Text(link, maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: () => launchUrl(
                  Uri.parse(link),
                  mode: LaunchMode.externalApplication,
                ),
              ),
          ],
          if (e.sketchPhotoUrl != null) ...[
            const SizedBox(height: 12),
            const Text(
              'Original-Skizze',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.memory(
                TeamLogo.decode(e.sketchPhotoUrl)!,
                fit: BoxFit.contain,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _block(String title, String text) {
    if (text.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 2),
          Text(text),
        ],
      ),
    );
  }
}
