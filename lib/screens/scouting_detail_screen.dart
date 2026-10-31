import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/scouting.dart';
import '../state/app_state.dart';

/// Detailansicht eines beobachteten Spielers: Status + Verlauf, FuPa-Statistik,
/// Notizen. Team-weit; Trainer dürfen bearbeiten, Autor ist überall sichtbar.
class ScoutingDetailScreen extends StatefulWidget {
  const ScoutingDetailScreen({super.key, required this.scoutId});

  final String scoutId;

  @override
  State<ScoutingDetailScreen> createState() => _ScoutingDetailScreenState();
}

class _ScoutingDetailScreenState extends State<ScoutingDetailScreen> {
  late final AppState _app = context.read<AppState>();
  final _df = DateFormat('dd.MM.yyyy', 'de_DE');
  bool _busy = false;

  Future<(ScoutPlayer?, List<ScoutEntry>)> _load() async {
    final p = await _app.scoutPlayer(widget.scoutId);
    final entries = await _app.scoutEntries(widget.scoutId);
    return (p, entries);
  }

  Future<void> _changeStatus(ScoutPlayer p) async {
    var status = p.status;
    var date = DateTime.now();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Status ändern'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<ScoutStatus>(
                initialValue: status,
                decoration: const InputDecoration(
                  labelText: 'Status',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final s in ScoutStatus.values)
                    DropdownMenuItem(value: s, child: Text(s.label)),
                ],
                onChanged: (v) => setLocal(() => status = v ?? status),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.event),
                label: Text('Datum: ${_df.format(date)}'),
                onPressed: () async {
                  final picked = await showDatePicker(
                    context: ctx,
                    initialDate: date,
                    firstDate: DateTime(2020),
                    lastDate: DateTime(2100),
                  );
                  if (picked != null) setLocal(() => date = picked);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Speichern'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    await _app.setScoutStatus(p, status, date);
    if (mounted) setState(() {});
  }

  Future<void> _addNote() async {
    final ctrl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Notiz hinzufügen'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          minLines: 2,
          maxLines: 5,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            hintText: 'z. B. starker Linksfuß, schneller Außenbahnspieler …',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
    if (text == null || text.isEmpty || !mounted) return;
    await _app.addScoutNote(widget.scoutId, text);
    if (mounted) setState(() {});
  }

  Future<void> _refreshStats(ScoutPlayer p) async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _app.refreshScoutStats(p);
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Statistik aktuell nicht verfügbar.')),
      );
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _deletePlayer(ScoutPlayer p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Spieler entfernen?'),
        content: Text('„${p.name}" wird aus dem Scouting entfernt.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Entfernen'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _app.deleteScoutPlayer(p.id);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _deleteEntry(ScoutEntry e) async {
    await _app.deleteScoutEntry(e.id);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final isTrainer = context.watch<AppState>().isTrainerHere;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scouting'),
        actions: [
          if (isTrainer)
            FutureBuilder<ScoutPlayer?>(
              future: _app.scoutPlayer(widget.scoutId),
              builder: (_, snap) {
                final p = snap.data;
                if (p == null) return const SizedBox.shrink();
                return IconButton(
                  tooltip: 'Spieler entfernen',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _deletePlayer(p),
                );
              },
            ),
        ],
      ),
      body: FutureBuilder<(ScoutPlayer?, List<ScoutEntry>)>(
        future: _load(),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final (p, entries) = snap.data!;
          if (p == null) {
            return const Center(child: Text('Spieler nicht gefunden.'));
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              _header(p),
              _statusCard(p, isTrainer),
              _statsCard(p, isTrainer),
              _historyCard(p, entries, isTrainer),
            ],
          );
        },
      ),
    );
  }

  Widget _header(ScoutPlayer p) {
    final photo = p.photoDisplayUrl;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        children: [
          CircleAvatar(
            radius: 32,
            backgroundColor: Colors.grey.shade200,
            backgroundImage: photo != null ? NetworkImage(photo) : null,
            child: photo == null
                ? const Icon(Icons.person, size: 32, color: Colors.grey)
                : null,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p.name,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    if (p.position != null && p.position!.isNotEmpty) p.position!,
                    if (p.number != null) 'Nr. ${p.number}',
                  ].join('  ·  '),
                  style: TextStyle(color: Theme.of(context).hintColor),
                ),
                if (p.fupaUrl != null)
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      alignment: Alignment.centerLeft,
                      minimumSize: const Size(0, 32),
                    ),
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: const Text('FuPa-Profil öffnen'),
                    onPressed: () => launchUrl(
                      Uri.parse(p.fupaUrl!),
                      mode: LaunchMode.externalApplication,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusCard(ScoutPlayer p, bool isTrainer) {
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: ListTile(
        leading: Icon(Icons.flag, color: p.status.color),
        title: Text(
          'Status: ${p.status.label}',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text('seit ${_df.format(p.statusDate)}'),
        trailing: isTrainer
            ? TextButton(
                onPressed: () => _changeStatus(p),
                child: const Text('Ändern'),
              )
            : null,
      ),
    );
  }

  Widget _statsCard(ScoutPlayer p, bool isTrainer) {
    Map<String, dynamic>? stats;
    if (p.statsJson != null && p.statsJson!.isNotEmpty) {
      try {
        stats = jsonDecode(p.statsJson!) as Map<String, dynamic>;
      } catch (_) {
        stats = null;
      }
    }
    final stations = (stats?['stations'] as List?) ?? const [];
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'FuPa-Statistik',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                ),
                if (p.fupaUrl != null && isTrainer)
                  TextButton.icon(
                    onPressed: _busy ? null : () => _refreshStats(p),
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Aktualisieren'),
                  ),
              ],
            ),
            if (p.fupaUrl == null)
              const Padding(
                padding: EdgeInsets.fromLTRB(2, 4, 8, 4),
                child: Text(
                  'Kein FuPa-Link hinterlegt – keine Statistik.',
                  style: TextStyle(color: Colors.grey),
                ),
              )
            else if (stats == null)
              const Padding(
                padding: EdgeInsets.fromLTRB(2, 4, 8, 4),
                child: Text(
                  'Noch keine Statistik geladen. Tippe auf „Aktualisieren".',
                  style: TextStyle(color: Colors.grey),
                ),
              )
            else ...[
              Wrap(
                spacing: 16,
                runSpacing: 8,
                children: [
                  _stat('Spiele', stats['totalMatches']),
                  _stat('Tore', stats['totalGoals']),
                  _stat('Vorlagen', stats['totalAssists']),
                  _stat('Gelb', stats['totalYellow']),
                  _stat('Gelb-Rot', stats['totalYellowRed']),
                  _stat('Rot', stats['totalRed']),
                  _stat('Top-Elf', stats['totalTopEleven']),
                ],
              ),
              if (stations.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text(
                  'Stationen',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                for (final s in stations)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      '${s['club'] ?? ''} · ${s['competition'] ?? ''} — '
                      '${s['matches'] ?? 0} Sp, ${s['goals'] ?? 0} T, '
                      '${s['assists'] ?? 0} V',
                      style: const TextStyle(fontSize: 12.5),
                    ),
                  ),
              ],
              if (p.statsUpdatedAt != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Stand: ${_df.format(p.statsUpdatedAt!)}',
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).hintColor,
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _stat(String label, Object? value) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '${value ?? 0}',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        Text(
          label,
          style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
        ),
      ],
    );
  }

  Widget _historyCard(
    ScoutPlayer p,
    List<ScoutEntry> entries,
    bool isTrainer,
  ) {
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Verlauf & Notizen',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                ),
                if (isTrainer)
                  TextButton.icon(
                    onPressed: _addNote,
                    icon: const Icon(Icons.add_comment_outlined, size: 18),
                    label: const Text('Notiz'),
                  ),
              ],
            ),
            if (entries.isEmpty)
              const Padding(
                padding: EdgeInsets.all(8),
                child: Text(
                  'Noch keine Einträge.',
                  style: TextStyle(color: Colors.grey),
                ),
              )
            else
              for (final e in entries) _entryTile(e, isTrainer),
          ],
        ),
      ),
    );
  }

  Widget _entryTile(ScoutEntry e, bool isTrainer) {
    final isStatus = e.isStatus;
    final title = isStatus
        ? 'Status: ${(e.status ?? ScoutStatus.beobachten).label}'
        : (e.text ?? '');
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        isStatus ? Icons.flag : Icons.sticky_note_2_outlined,
        color: isStatus
            ? (e.status ?? ScoutStatus.beobachten).color
            : Theme.of(context).colorScheme.primary,
      ),
      title: Text(title),
      subtitle: Text(
        'von ${e.actorName} · ${_df.format(e.entryDate)}',
        style: const TextStyle(fontSize: 11.5),
      ),
      trailing: isTrainer
          ? IconButton(
              icon: const Icon(Icons.close, size: 18),
              tooltip: 'Eintrag löschen',
              onPressed: () => _deleteEntry(e),
            )
          : null,
    );
  }
}
