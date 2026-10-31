import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/scouting.dart';
import '../state/app_state.dart';
import 'scouting_detail_screen.dart';

/// Scouting: Liste beobachteter (potenzieller) Spieler. Team-weit geteilt;
/// anlegen/bearbeiten dürfen Trainer, jede Angabe trägt ihren Autor.
class ScoutingScreen extends StatefulWidget {
  const ScoutingScreen({super.key});

  @override
  State<ScoutingScreen> createState() => _ScoutingScreenState();
}

class _ScoutingScreenState extends State<ScoutingScreen> {
  late final AppState _app = context.read<AppState>();
  bool _busy = false;

  Future<void> _add() async {
    final mode = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Spieler hinzufügen',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('Per FuPa-Link'),
              subtitle: const Text('Stammdaten & Statistik automatisch laden'),
              onTap: () => Navigator.pop(ctx, 'fupa'),
            ),
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('Manuell'),
              subtitle: const Text('Name, Position, Nummer selbst eingeben'),
              onTap: () => Navigator.pop(ctx, 'manual'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (mode == 'fupa') {
      await _addFromFupa();
    } else if (mode == 'manual') {
      await _addManual();
    }
  }

  Future<void> _addFromFupa() async {
    final ctrl = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('FuPa-Spieler-Link'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: 'Link',
            hintText: 'https://www.fupa.net/player/…',
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Laden'),
          ),
        ],
      ),
    );
    if (url == null || url.isEmpty || !mounted) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final p = await _app.addScoutPlayerFromFupa(url);
      if (!mounted) return;
      setState(() => _busy = false);
      _open(p.id);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(
        SnackBar(content: Text('Konnte Spieler nicht laden: $e')),
      );
    }
  }

  Future<void> _addManual() async {
    final nameCtrl = TextEditingController();
    final posCtrl = TextEditingController();
    final numCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Spieler manuell'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            TextField(
              controller: posCtrl,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Position (optional)',
              ),
            ),
            TextField(
              controller: numCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Nummer (optional)',
              ),
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
            child: const Text('Anlegen'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final name = nameCtrl.text.trim();
    if (name.isEmpty) return;
    final p = await _app.addScoutPlayerManual(
      name: name,
      position: posCtrl.text.trim(),
      number: int.tryParse(numCtrl.text.trim()),
    );
    if (mounted) _open(p.id);
  }

  void _open(String id) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ScoutingDetailScreen(scoutId: id)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final isTrainer = state.isTrainerHere;
    return Scaffold(
      appBar: AppBar(title: const Text('Scouting')),
      floatingActionButton: isTrainer
          ? FloatingActionButton.extended(
              onPressed: _busy ? null : _add,
              icon: const Icon(Icons.person_add),
              label: const Text('Spieler hinzufügen'),
            )
          : null,
      body: Stack(
        children: [
          FutureBuilder<List<ScoutPlayer>>(
            future: state.scoutPlayers(),
            builder: (context, snap) {
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final players = snap.data!;
              if (players.isEmpty) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Noch keine beobachteten Spieler.\nTippe auf „Spieler '
                      'hinzufügen".',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.only(bottom: 90),
                itemCount: players.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) => _row(players[i]),
              );
            },
          ),
          if (_busy)
            const Positioned.fill(
              child: ColoredBox(
                color: Color(0x66000000),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
    );
  }

  Widget _row(ScoutPlayer p) {
    final photo = p.photoDisplayUrl;
    final sub = [
      if (p.position != null && p.position!.isNotEmpty) p.position!,
      if (p.number != null) 'Nr. ${p.number}',
    ].join('  ·  ');
    return ListTile(
      leading: CircleAvatar(
        radius: 22,
        backgroundColor: Colors.grey.shade200,
        backgroundImage: photo != null ? NetworkImage(photo) : null,
        child: photo == null
            ? const Icon(Icons.person, color: Colors.grey)
            : null,
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              p.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (p.fupaUrl != null) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: const Color(0xFF2E7D4F),
                borderRadius: BorderRadius.circular(5),
              ),
              child: const Text(
                'FuPa',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ],
      ),
      subtitle: sub.isEmpty ? null : Text(sub),
      trailing: _statusChip(p.status),
      onTap: () => _open(p.id),
    );
  }

  Widget _statusChip(ScoutStatus s) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: s.color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: s.color.withValues(alpha: 0.5)),
      ),
      child: Text(
        s.label,
        style: TextStyle(
          color: s.color,
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
      ),
    );
  }
}
