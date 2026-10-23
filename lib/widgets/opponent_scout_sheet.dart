import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/player.dart';
import '../models/player_stat.dart';
import '../models/scout_marker.dart';
import '../state/app_state.dart';
import 'player_avatar.dart';

/// Öffnet das Scouting-Blatt für einen Gegner-Spieler (kein volles Profil):
/// besondere Marker (verletzt, schnell …) und ein Kommentar. Die Toranzahl
/// kommt aus der importierten Statistik.
Future<void> showOpponentScoutSheet(
  BuildContext context,
  Player player, {
  int goals = 0,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _ScoutSheet(player: player, goals: goals),
  );
}

class _ScoutSheet extends StatefulWidget {
  const _ScoutSheet({required this.player, required this.goals});
  final Player player;
  final int goals;

  @override
  State<_ScoutSheet> createState() => _ScoutSheetState();
}

class _ScoutSheetState extends State<_ScoutSheet> {
  late final AppState _state;
  final _commentCtrl = TextEditingController();
  Set<ScoutMarker> _markers = {};
  String _savedComment = '';
  PlayerStat? _stat;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _state = context.read<AppState>();
    _load();
  }

  Future<void> _load() async {
    final markers = await _state.scoutMarkersOf(widget.player.id);
    final comment = await _state.scoutCommentOf(widget.player.id);
    final stat = await _state.playerSeasonStat(
        widget.player.teamId, widget.player.dedupKey);
    if (!mounted) return;
    setState(() {
      _markers = markers;
      _commentCtrl.text = comment;
      _savedComment = comment;
      _stat = stat;
      _loading = false;
    });
  }

  Widget _statCol(String label, String value) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value,
              style: const TextStyle(
                  fontSize: 18, fontWeight: FontWeight.bold)),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      );

  void _commitComment() {
    if (_commentCtrl.text == _savedComment) return;
    _savedComment = _commentCtrl.text;
    _state.setScoutComment(widget.player.id, _commentCtrl.text);
  }

  @override
  void dispose() {
    // Kommentar beim Schließen sichern.
    if (_commentCtrl.text != _savedComment) {
      _state.setScoutComment(widget.player.id, _commentCtrl.text);
    }
    _commentCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.player;
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 4,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: _loading
          ? const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    PlayerAvatar(player: p, radius: 26),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(p.fullName,
                              style: Theme.of(context).textTheme.titleLarge,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis),
                          Text([
                            if (p.number != null) 'Nr. ${p.number}',
                            if (p.position != null) p.position!,
                          ].join('  ·  ')),
                        ],
                      ),
                    ),
                    if (widget.goals > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: widget.goals >= 5
                              ? Colors.red.withValues(alpha: 0.12)
                              : Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('⚽', style: TextStyle(fontSize: 14)),
                            const SizedBox(width: 4),
                            Text('${widget.goals}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ),
                  ],
                ),
                if (widget.goals >= 5)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      children: [
                        Icon(Icons.local_fire_department,
                            size: 16, color: Colors.red.shade700),
                        const SizedBox(width: 4),
                        Text('Torjäger – ${widget.goals} Saisontore',
                            style: TextStyle(
                                color: Colors.red.shade700,
                                fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                // FuPa-Saisonstatistik (Spiele/Tore/Vorlagen) – wie bei FuPa.
                const SizedBox(height: 14),
                if (_stat != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 10),
                    decoration: BoxDecoration(
                      color:
                          Theme.of(context).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _statCol('Spiele', '${_stat!.matches}'),
                        _statCol('Tore', '${_stat!.goals}'),
                        _statCol('Vorlagen', '${_stat!.assists}'),
                        _statCol('Min', '${_stat!.minutes}'),
                      ],
                    ),
                  )
                else
                  Text('Keine FuPa-Saisonstatistik für diesen Spieler.',
                      style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 16),
                Text('Besondere Marker',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: ScoutMarker.values.map((m) {
                    final on = _markers.contains(m);
                    return FilterChip(
                      avatar: Icon(m.icon, size: 18),
                      label: Text(m.label),
                      selected: on,
                      onSelected: (v) {
                        setState(() {
                          if (v) {
                            _markers.add(m);
                          } else {
                            _markers.remove(m);
                          }
                        });
                        _state.toggleScoutMarker(widget.player.id, m, v);
                      },
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),
                Text('Kommentar',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                TextField(
                  controller: _commentCtrl,
                  minLines: 2,
                  maxLines: 5,
                  onEditingComplete: _commitComment,
                  onTapOutside: (_) {
                    FocusManager.instance.primaryFocus?.unfocus();
                    _commitComment();
                  },
                  decoration: const InputDecoration(
                    hintText: 'z.B. „links sehr offensiv, Standards gefährlich"',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: () {
                      _commitComment();
                      Navigator.pop(context);
                    },
                    child: const Text('Fertig'),
                  ),
                ),
              ],
            ),
    );
  }
}
