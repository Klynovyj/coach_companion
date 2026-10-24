import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/note_category.dart';
import '../state/app_state.dart';
import '../widgets/team_logo.dart';
import 'cloud_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _linkController = TextEditingController();
  bool _busy = false;
  String _progress = '';
  ConnectSummary? _summary;
  String? _error;

  @override
  void initState() {
    super.initState();
    _linkController.text = context.read<AppState>().ownTeam?.fupaUrl ?? '';
  }

  @override
  void dispose() {
    _linkController.dispose();
    super.dispose();
  }

  Future<void> _connect({bool resync = false}) async {
    final url = resync
        ? (context.read<AppState>().ownTeam?.fupaUrl ?? '')
        : _linkController.text.trim();
    if (url.isEmpty) return;
    setState(() {
      _busy = true;
      _progress = '';
      _summary = null;
      _error = null;
    });
    try {
      final summary = await context
          .read<AppState>()
          .connectOwnTeam(url, onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      });
      if (!mounted) return;
      setState(() {
        _busy = false;
        _summary = summary;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final team = state.ownTeam;
    final df = DateFormat('dd.MM.yyyy HH:mm', 'de_DE');

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
          _sectionTitle(context, 'FuPa-Teamlink'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Füge den Link deiner FuPa-Mannschaftsseite ein. Die App lädt '
              'daraus automatisch Teamname & Logo, den Kader (mit Fotos), den '
              'Spielplan (mit Ergebnissen) und die Spieler-Statistik.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _linkController,
                    enabled: !_busy,
                    decoration: const InputDecoration(
                      labelText: 'FuPa-Teamlink',
                      hintText: 'https://www.fupa.net/team/...',
                      prefixIcon: Icon(Icons.link),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (_busy) ...[
                    const LinearProgressIndicator(),
                    const SizedBox(height: 8),
                    Text(_progress,
                        style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 12),
                  ],
                  FilledButton.icon(
                    onPressed: _busy ? null : () => _connect(),
                    icon: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child:
                                CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.cloud_download),
                    label: const Text('Verbinden & alles laden'),
                  ),
                  if (team != null) ...[
                    const Divider(height: 28),
                    Row(
                      children: [
                        TeamLogo(logoPath: team.logoPath, size: 36),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Verbunden: ${team.name}',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium),
                              if (team.lastSyncedAt != null)
                                Text(
                                    'Zuletzt: ${df.format(team.lastSyncedAt!)}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _busy ? null : () => _connect(resync: true),
                            icon: const Icon(Icons.refresh),
                            label: const Text('Neu synchronisieren'),
                          ),
                        ),
                        if (team.fupaUrl != null) ...[
                          const SizedBox(width: 8),
                          IconButton(
                            tooltip: 'Im Browser öffnen',
                            onPressed: () => _openUrl(team.fupaUrl!),
                            icon: const Icon(Icons.open_in_new),
                          ),
                        ],
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (_summary != null) _SummaryCard(summary: _summary!),
          if (_error != null)
            Card(
              color: Colors.red.shade50,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Icon(Icons.error_outline, color: Colors.red.shade700),
                    const SizedBox(width: 10),
                    Expanded(child: Text('Import fehlgeschlagen: $_error')),
                  ],
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

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
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

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.summary});
  final ConnectSummary summary;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.green.shade50,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.check_circle, color: Colors.green.shade700),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Import abgeschlossen: ${summary.teamName}',
                      style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text('• ${summary.players} Spieler (mit Fotos)'),
                  Text(
                      '• ${summary.matches} Spiele (${summary.newMatches} neu)'),
                  Text('• Statistik: ${summary.stats} Spieler'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
