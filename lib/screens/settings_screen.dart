import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/note_category.dart';
import '../state/app_state.dart';
import 'cloud_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return Scaffold(
      appBar: AppBar(title: const Text('Einstellungen')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _sectionTitle(context, 'Gemeinsam nutzen'),
          Card(
            child: ListTile(
              leading: const Icon(Icons.cloud_outlined),
              title: const Text('Konto & Team'),
              subtitle: const Text(
                  'Anmelden, Team anlegen/beitreten und aktives Team wählen'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const CloudScreen()),
              ),
            ),
          ),
          _sectionTitle(context, 'Notiz-Kategorien'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Kategorien ordnen die Spieler-Notizen (z.B. „Taktik", „Fitness", '
              '„Verhalten"). Beim Erstellen einer Notiz wählst du eine Kategorie.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          _RubrikenCard(state: state),
        ],
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
        child: Text(text,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );
}

/// Verwaltung der Notiz-Rubriken (zentral): anlegen, umbenennen, löschen.
class _RubrikenCard extends StatelessWidget {
  const _RubrikenCard({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: FutureBuilder<List<NoteCategory>>(
          future: state.noteCategories(),
          builder: (context, snap) {
            if (!snap.hasData) {
              return const Padding(
                padding: EdgeInsets.all(12),
                child: LinearProgressIndicator(),
              );
            }
            final cats = snap.data!;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (cats.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(8),
                    child: Text('Noch keine Kategorien.',
                        style: TextStyle(color: Colors.grey)),
                  )
                else
                  for (final c in cats)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.label_outline),
                      title: Text(c.name),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Umbenennen',
                            icon: const Icon(Icons.edit, size: 20),
                            onPressed: () => _rename(context, c),
                          ),
                          IconButton(
                            tooltip: 'Löschen',
                            icon: const Icon(Icons.delete_outline, size: 20),
                            onPressed: () => _delete(context, c),
                          ),
                        ],
                      ),
                    ),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => _add(context),
                    icon: const Icon(Icons.add),
                    label: const Text('Kategorie hinzufügen'),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _add(BuildContext context) async {
    final name = await _promptName(context, title: 'Kategorie hinzufügen');
    if (name == null || name.isEmpty || !context.mounted) return;
    await state.addNoteCategory(name);
  }

  Future<void> _rename(BuildContext context, NoteCategory c) async {
    final name = await _promptName(context,
        title: 'Kategorie umbenennen', initial: c.name);
    if (name == null || name.isEmpty || !context.mounted) return;
    await state.updateNoteCategory(c.copyWith(name: name));
  }

  Future<void> _delete(BuildContext context, NoteCategory c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Kategorie löschen?'),
        content: Text(
            '„${c.name}" wird entfernt. Vorhandene Notizen bleiben erhalten, '
            'landen aber unter „Ohne Kategorie".'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Löschen')),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await state.deleteNoteCategory(c.id);
    }
  }

  Future<String?> _promptName(BuildContext context,
      {required String title, String? initial}) {
    final ctrl = TextEditingController(text: initial ?? '');
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name der Kategorie'),
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
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
  }
}
