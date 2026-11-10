import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../models/prep_plan.dart';
import '../services/studio_plan_import.dart';
import '../state/app_state.dart';
import '../widgets/team_logo.dart';
import 'prep_plan_editor_screen.dart';

const _uuid = Uuid();

/// Vorbereitungspläne (Mehr → Vorbereitungsplan): Saison-Termine als
/// druckbarer DIN-A4-Plan – 1:1 wie im Coach Studio.
class PrepPlansScreen extends StatefulWidget {
  const PrepPlansScreen({super.key});

  @override
  State<PrepPlansScreen> createState() => _PrepPlansScreenState();
}

class _PrepPlansScreenState extends State<PrepPlansScreen> {
  List<PrepPlan>? _plans;

  @override
  void initState() {
    super.initState();
    _load();
    // Cloud-Abgleich (lädt neuere Pläne, schiebt fehlende hoch).
    context.read<AppState>().syncPrepPlans().then((_) => _load());
  }

  Future<void> _load() async {
    final p = await context.read<AppState>().prepPlans();
    if (mounted) setState(() => _plans = p);
  }

  Future<void> _create() async {
    final ctrl = TextEditingController(text: 'Vorbereitungsplan');
    final title = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Neuer Vorbereitungsplan'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Titel'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('Erstellen'),
          ),
        ],
      ),
    );
    if (title == null || !mounted) return;
    final plan = PrepPlan(
      id: 'plan-${_uuid.v4().substring(0, 8)}',
      title: title.trim().isEmpty ? 'Vorbereitungsplan' : title.trim(),
      createdAt: DateTime.now().toUtc().toIso8601String(),
    );
    await context.read<AppState>().savePrepPlan(plan);
    if (!mounted) return;
    await _open(plan);
  }

  Future<void> _open(PrepPlan plan) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => PrepPlanEditorScreen(plan: plan)),
    );
    _load();
  }

  Future<void> _delete(PrepPlan p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Plan „${p.title}" löschen?'),
        content: const Text('Der Plan wird endgültig entfernt.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await context.read<AppState>().deletePrepPlan(p.id);
    _load();
  }

  Future<void> _importStudio() async {
    final state = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      final plans = await StudioPlanImport.readPlans();
      final existing = {for (final p in await state.prepPlans()) p.id};
      var added = 0;
      var updated = 0;
      for (final p in plans) {
        existing.contains(p.id) ? updated++ : added++;
        await state.savePrepPlan(p, notify: false);
      }
      await _load();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            plans.isEmpty
                ? 'Keine Pläne im Coach Studio gefunden.'
                : 'Aus Coach Studio übernommen: $added neu'
                      '${updated > 0 ? ', $updated aktualisiert' : ''}.',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Übernahme fehlgeschlagen: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final team = state.ownTeam;
    final canEdit = state.isTrainerHere;
    final plans = _plans;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Vorbereitungspläne'),
        actions: [
          if (canEdit && StudioPlanImport.available)
            IconButton(
              tooltip: 'Aus Coach Studio übernehmen',
              icon: const Icon(Icons.download_for_offline_outlined),
              onPressed: _importStudio,
            ),
        ],
      ),
      floatingActionButton: canEdit
          ? FloatingActionButton.extended(
              onPressed: _create,
              icon: const Icon(Icons.add),
              label: const Text('Neuer Plan'),
            )
          : null,
      body: plans == null
          ? const Center(child: CircularProgressIndicator())
          : plans.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'Noch keine Pläne angelegt.\n'
                  'Saison-Termine als druckbarer Plan – Trainings, Spiele, '
                  'Mannschaftsfoto, Grillen und alles dazwischen.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).hintColor),
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
              children: [
                for (final p in plans)
                  Card(
                    child: ListTile(
                      leading: TeamLogo(logoPath: team?.logoPath, size: 40),
                      title: Text(
                        p.title,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        [
                          if (p.subtitle?.trim().isNotEmpty ?? false)
                            p.subtitle!.trim(),
                          '${p.entries.length} Termin'
                              '${p.entries.length == 1 ? '' : 'e'}',
                        ].join(' · '),
                      ),
                      onTap: () => _open(p),
                      trailing: canEdit
                          ? IconButton(
                              tooltip: 'Plan löschen',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => _delete(p),
                            )
                          : const Icon(Icons.chevron_right),
                    ),
                  ),
              ],
            ),
    );
  }
}
