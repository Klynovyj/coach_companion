import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';

/// Auswahl von Mit-Trainern zum Erwähnen (@) – für Aufgaben und Spielberichte.
/// Lädt die Trainer des aktiven Teams (ohne mich) und meldet die ausgewählten
/// user_ids per [onChanged]. Ohne Cloud/ohne Mit-Trainer wird nichts angezeigt.
class TrainerMentionField extends StatefulWidget {
  const TrainerMentionField({super.key, required this.onChanged});

  final ValueChanged<List<String>> onChanged;

  @override
  State<TrainerMentionField> createState() => _TrainerMentionFieldState();
}

class _TrainerMentionFieldState extends State<TrainerMentionField> {
  List<({String userId, String name})> _trainers = [];
  final Set<String> _selected = {};
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final list = await context.read<AppState>().teamTrainers();
    if (!mounted) return;
    setState(() {
      _trainers = list;
      _loaded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded || _trainers.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.alternate_email,
              size: 16,
              color: Theme.of(context).hintColor,
            ),
            const SizedBox(width: 6),
            Text(
              'Trainer erwähnen',
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 2,
          children: [
            for (final t in _trainers)
              FilterChip(
                label: Text(t.name),
                selected: _selected.contains(t.userId),
                onSelected: (v) {
                  setState(() {
                    if (v) {
                      _selected.add(t.userId);
                    } else {
                      _selected.remove(t.userId);
                    }
                  });
                  widget.onChanged(_selected.toList());
                },
              ),
          ],
        ),
      ],
    );
  }
}
