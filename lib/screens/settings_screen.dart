import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/enums.dart';
import '../services/fupa/fupa_dtos.dart';
import '../services/fupa/fupa_source_registry.dart';
import '../state/app_state.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _linkController = TextEditingController();
  final _baseController = TextEditingController();
  final _tokenController = TextEditingController();
  bool _busy = false;
  ImportResult? _lastResult;

  @override
  void initState() {
    super.initState();
    final state = context.read<AppState>();
    _linkController.text = state.ownTeam?.fupaUrl ?? '';
    _baseController.text = state.apiBase ?? '';
    _tokenController.text = state.apiToken ?? '';
  }

  @override
  void dispose() {
    _linkController.dispose();
    _baseController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final url = _linkController.text.trim();
    if (url.isEmpty) return;
    setState(() => _busy = true);
    final result = await context.read<AppState>().connectOwnTeam(url);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _lastResult = result;
    });
    _showResultSnack(result);
  }

  Future<void> _resync() async {
    setState(() => _busy = true);
    final result = await context.read<AppState>().resyncOwnTeam();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _lastResult = result;
    });
    _showResultSnack(result);
  }

  void _showResultSnack(ImportResult result) {
    final color = switch (result.status) {
      ImportStatus.success => Colors.green.shade700,
      ImportStatus.alreadyPresent => Colors.blueGrey,
      ImportStatus.error => Colors.red.shade700,
      _ => Colors.orange.shade800,
    };
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(result.message), backgroundColor: color),
    );
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
          _sectionTitle(context, 'FuPa-Teamlink'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _linkController,
                    decoration: const InputDecoration(
                      labelText: 'FuPa-Teamlink',
                      hintText: 'https://www.fupa.net/team/...',
                      prefixIcon: Icon(Icons.link),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _busy ? null : _connect,
                    icon: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.sync),
                    label: const Text('Mannschaft verbinden'),
                  ),
                  if (team != null) ...[
                    const Divider(height: 28),
                    Row(
                      children: [
                        const Icon(Icons.verified, color: Colors.green),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text('Verbunden: ${team.name}',
                              style: Theme.of(context).textTheme.titleMedium),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text('Quelle: ${team.source.label}'),
                    if (team.lastSyncedAt != null)
                      Text('Letzte Synchronisierung: ${df.format(team.lastSyncedAt!)}'),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _busy ? null : _resync,
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
          if (_lastResult != null) _ImportStatusCard(result: _lastResult!),

          _sectionTitle(context, 'Genehmigter Datenzugang'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Automatischer Online-Import ist nur über eine offiziell erlaubte '
              'FuPa-Schnittstelle möglich. Ohne hinterlegten Zugang bleibt die '
              'App voll nutzbar – Daten werden dann manuell gepflegt.',
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
                    controller: _baseController,
                    decoration: const InputDecoration(
                      labelText: 'Basis-URL der Schnittstelle',
                      hintText: 'https://...',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _tokenController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Zugriffstoken',
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.tonalIcon(
                    onPressed: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      await context.read<AppState>().saveApprovedSource(
                          _baseController.text, _tokenController.text);
                      if (!mounted) return;
                      setState(() {});
                      messenger.showSnackBar(
                        const SnackBar(content: Text('Zugang gespeichert.')),
                      );
                    },
                    icon: const Icon(Icons.save),
                    label: const Text('Zugang speichern'),
                  ),
                ],
              ),
            ),
          ),

          _sectionTitle(context, 'Status der Datenquellen'),
          FutureBuilder<List<SourceStatus>>(
            future: state.sourceStatuses(),
            builder: (context, snap) {
              if (!snap.hasData) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: LinearProgressIndicator(),
                );
              }
              return Column(
                children: snap.data!
                    .map((s) => Card(
                          child: ListTile(
                            leading: Icon(
                              s.availability.canAutoImport
                                  ? Icons.cloud_done
                                  : Icons.cloud_off,
                              color: s.availability.canAutoImport
                                  ? Colors.green
                                  : Colors.grey,
                            ),
                            title: Text(s.label),
                            subtitle: Text(s.availability.message),
                          ),
                        ))
                    .toList(),
              );
            },
          ),
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

class _ImportStatusCard extends StatelessWidget {
  const _ImportStatusCard({required this.result});
  final ImportResult result;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (result.status) {
      ImportStatus.success => (Icons.check_circle, Colors.green.shade700),
      ImportStatus.alreadyPresent => (Icons.info, Colors.blueGrey),
      ImportStatus.error => (Icons.error, Colors.red.shade700),
      _ => (Icons.edit_note, Colors.orange.shade800),
    };
    return Card(
      color: color.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color),
            const SizedBox(width: 10),
            Expanded(child: Text(result.message)),
          ],
        ),
      ),
    );
  }
}
