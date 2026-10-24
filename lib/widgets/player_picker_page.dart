import 'package:flutter/material.dart';

import '../models/player.dart';
import 'player_avatar.dart';

/// Rückgabewert für „— ohne —" (kein Spieler).
const String kPlayerPickNone = '\u0000none';

/// Vollbild-Einzelauswahl eines Spielers (mit Foto + Suche).
/// Gibt die Spieler-ID zurück, [kPlayerPickNone] für „ohne", oder null bei
/// Abbruch (Zurück).
class PlayerPickerPage extends StatefulWidget {
  const PlayerPickerPage({
    super.key,
    required this.players,
    this.selected,
    this.allowNone = true,
    this.title = 'Spieler wählen',
  });

  final List<Player> players;
  final String? selected;
  final bool allowNone;
  final String title;

  @override
  State<PlayerPickerPage> createState() => _PlayerPickerPageState();
}

class _PlayerPickerPageState extends State<PlayerPickerPage> {
  String _query = '';

  List<Player> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return widget.players;
    return widget.players
        .where((p) => p.displayName.toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget tile({
      required bool selected,
      required Widget leading,
      required String label,
      required VoidCallback onTap,
    }) =>
        Card(
          elevation: 0,
          margin: const EdgeInsets.symmetric(vertical: 3),
          color: selected ? scheme.primaryContainer : scheme.surfaceContainerHighest,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: selected ? scheme.primary : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: ListTile(
            leading: leading,
            title: Text(label),
            trailing:
                selected ? Icon(Icons.check_circle, color: scheme.primary) : null,
            onTap: onTap,
          ),
        );

    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          TextField(
            onChanged: (v) => setState(() => _query = v),
            decoration: InputDecoration(
              hintText: 'Spieler suchen …',
              prefixIcon: const Icon(Icons.search),
              isDense: true,
              border: const OutlineInputBorder(),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () => setState(() => _query = ''),
                    ),
            ),
          ),
          const SizedBox(height: 8),
          if (widget.allowNone)
            tile(
              selected: widget.selected == null,
              leading: const CircleAvatar(
                  radius: 18, child: Icon(Icons.block, size: 18)),
              label: '— ohne —',
              onTap: () => Navigator.pop(context, kPlayerPickNone),
            ),
          for (final p in _filtered)
            tile(
              selected: widget.selected == p.id,
              leading: PlayerAvatar(player: p, radius: 18),
              label: p.displayName,
              onTap: () => Navigator.pop(context, p.id),
            ),
        ],
      ),
    );
  }
}
