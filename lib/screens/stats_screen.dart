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

  // Kompakte, bildschirmfüllende Tabelle (passt auch auf dem Handy, ohne
  // horizontales Scrollen). Spalten: Sp · Tore · Vorlagen · Gelb · Rot · Top11.
  static const _numW = 30.0;

  Widget _num(String t, {bool header = false, Color? color}) => SizedBox(
        width: _numW,
        child: Text(t,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.clip,
            style: TextStyle(
                fontWeight: header ? FontWeight.bold : FontWeight.w600,
                color: color)),
      );

  Widget _table(List<PlayerStat> stats) {
    return Column(
      children: [
        // Kopfzeile
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 12, 6),
          child: Row(
            children: [
              const Expanded(
                  child: Text('Spieler',
                      style: TextStyle(fontWeight: FontWeight.bold))),
              _num('Sp', header: true),
              _num('⚽', header: true),
              _num('🅰', header: true),
              _num('🟨', header: true),
              _num('🟥', header: true),
              _num('⭐', header: true),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.separated(
            itemCount: stats.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final s = stats[i];
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('${i + 1}. ${s.fullName}',
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                    _num('${s.matches}'),
                    _num('${s.goals}'),
                    _num('${s.assists}'),
                    _num('${s.yellowCards}'),
                    _num('${s.yellowRedCards + s.redCards}'),
                    _num('${s.topEleven}'),
                  ],
                ),
              );
            },
          ),
        ),
      ],
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
