import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/player_stat.dart';
import '../state/app_state.dart';

enum _SortKey { goals, assists, matches, minutes, name }

class StatsScreen extends StatefulWidget {
  const StatsScreen({
    super.key,
    required this.teamId,
    required this.teamName,
    this.fupaUrl,
  });

  final String teamId;
  final String teamName;
  final String? fupaUrl;

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  _SortKey _sort = _SortKey.goals;

  List<PlayerStat> _sorted(List<PlayerStat> stats) {
    final list = [...stats];
    switch (_sort) {
      case _SortKey.goals:
        list.sort((a, b) => b.goals != a.goals
            ? b.goals.compareTo(a.goals)
            : b.assists.compareTo(a.assists));
      case _SortKey.assists:
        list.sort((a, b) => b.assists.compareTo(a.assists));
      case _SortKey.matches:
        list.sort((a, b) => b.matches.compareTo(a.matches));
      case _SortKey.minutes:
        list.sort((a, b) => b.minutes.compareTo(a.minutes));
      case _SortKey.name:
        list.sort((a, b) => a.lastName
            .toLowerCase()
            .compareTo(b.lastName.toLowerCase()));
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: Text('Statistik · ${widget.teamName}'),
        actions: [
          IconButton(
            tooltip: 'Statistik aus FuPa importieren',
            icon: const Icon(Icons.cloud_download),
            onPressed: _import,
          ),
        ],
      ),
      body: FutureBuilder<List<PlayerStat>>(
        future: state.statsOf(widget.teamId),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final stats = snap.data!;
          if (stats.isEmpty) {
            return _empty();
          }
          return Column(
            children: [
              _sortBar(),
              Expanded(child: _table(_sorted(stats))),
            ],
          );
        },
      ),
    );
  }

  Widget _sortBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          const Text('Sortieren: '),
          const SizedBox(width: 8),
          DropdownButton<_SortKey>(
            value: _sort,
            onChanged: (v) => setState(() => _sort = v ?? _sort),
            items: const [
              DropdownMenuItem(value: _SortKey.goals, child: Text('Tore')),
              DropdownMenuItem(value: _SortKey.assists, child: Text('Vorlagen')),
              DropdownMenuItem(value: _SortKey.matches, child: Text('Spiele')),
              DropdownMenuItem(value: _SortKey.minutes, child: Text('Minuten')),
              DropdownMenuItem(value: _SortKey.name, child: Text('Name')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _table(List<PlayerStat> stats) {
    return SingleChildScrollView(
      scrollDirection: Axis.vertical,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columnSpacing: 18,
          columns: const [
            DataColumn(label: Text('Spieler')),
            DataColumn(label: Text('Sp'), numeric: true),
            DataColumn(label: Text('Tore'), numeric: true),
            DataColumn(label: Text('Vorl'), numeric: true),
            DataColumn(label: Text('🟨'), numeric: true),
            DataColumn(label: Text('🟨🟥'), numeric: true),
            DataColumn(label: Text('🟥'), numeric: true),
            DataColumn(label: Text('Min'), numeric: true),
            DataColumn(label: Text('⭐'), numeric: true),
          ],
          rows: [
            for (final s in stats)
              DataRow(cells: [
                DataCell(Text(s.fullName)),
                DataCell(Text('${s.matches}')),
                DataCell(Text('${s.goals}')),
                DataCell(Text('${s.assists}')),
                DataCell(Text('${s.yellowCards}')),
                DataCell(Text('${s.yellowRedCards}')),
                DataCell(Text('${s.redCards}')),
                DataCell(Text('${s.minutes}')),
                DataCell(Text('${s.topEleven}')),
              ]),
          ],
        ),
      ),
    );
  }

  Widget _empty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.bar_chart, size: 48, color: Colors.grey),
            const SizedBox(height: 12),
            const Text(
              'Noch keine Statistik.\nImportiere sie aus dem FuPa-Teamlink.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _import,
              icon: const Icon(Icons.cloud_download),
              label: const Text('Statistik importieren'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _import() async {
    final controller = TextEditingController(text: widget.fupaUrl ?? '');
    final url = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Statistik importieren'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
                'FuPa-Teamlink einfügen – Tore, Vorlagen, Spiele, Karten und '
                'Minuten der Saison werden geladen und ersetzen den alten Stand.'),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'FuPa-Teamlink',
                hintText: 'https://www.fupa.net/team/...',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('Importieren')),
        ],
      ),
    );
    if (url == null || url.isEmpty || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(children: [
          CircularProgressIndicator(),
          SizedBox(width: 16),
          Expanded(child: Text('Statistik wird geladen …')),
        ]),
      ),
    );
    try {
      final n = await context.read<AppState>().importStats(widget.teamId, url);
      if (mounted) Navigator.pop(context);
      messenger.showSnackBar(
          SnackBar(content: Text('Statistik importiert: $n Spieler.')));
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) Navigator.pop(context);
      messenger.showSnackBar(SnackBar(
          content: Text('Import fehlgeschlagen: $e'),
          backgroundColor: Colors.red.shade700));
    }
  }
}
