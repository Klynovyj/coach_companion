import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/enums.dart';
import '../models/player.dart';
import '../screens/paste_import_screen.dart';
import '../screens/player_detail_screen.dart';
import '../state/app_state.dart';
import 'player_avatar.dart';
import 'player_edit_dialog.dart';

/// Zeigt den Kader eines Teams mit Suche und Status-Filter. Bearbeitet wird
/// ein Spieler im Profil (Tippen öffnet es); hier nur Hinzufügen/Einfügen und
/// Löschen. Wird auch (gefiltert) im Spielcenter genutzt.
class SquadListView extends StatefulWidget {
  const SquadListView({
    super.key,
    required this.teamId,
    this.teamName = 'Team',
    this.fupaUrl,
    this.emptyHint = 'Noch keine Spieler. Jetzt welche hinzufügen oder einfügen.',
    this.showActions = true,
    this.onlyPlayerIds,
  });

  final String teamId;
  final String teamName;
  final String? fupaUrl;
  final String emptyHint;

  /// Zeigt die Buttons „Hinzufügen"/„Einfügen" (im Spielcenter ausgeblendet).
  final bool showActions;

  /// Wenn gesetzt, werden nur diese Spieler angezeigt (z.B. nur Nominierte).
  final Set<String>? onlyPlayerIds;

  @override
  State<SquadListView> createState() => _SquadListViewState();
}

class _SquadListViewState extends State<SquadListView> {
  final _searchCtrl = TextEditingController();
  String _query = '';
  PlayerStatus? _statusFilter;

  /// Suche/Filter nur im echten Kader (nicht in der gefilterten Spielansicht).
  bool get _showSearch => widget.showActions && widget.onlyPlayerIds == null;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Lauscht auf Änderungen, damit nach Add/Delete/Status neu geladen wird.
    final state = context.watch<AppState>();
    return FutureBuilder<_SquadData>(
      future: _load(state),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final all = snap.data!.players;
        final cards = snap.data!.cardCounts;
        final ratings = snap.data!.ratings;

        var players = all;
        if (widget.onlyPlayerIds != null) {
          players =
              players.where((p) => widget.onlyPlayerIds!.contains(p.id)).toList();
        }
        if (_showSearch) {
          players = _applyFilter(players);
        }

        if (all.isEmpty) {
          if (!widget.showActions) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  widget.onlyPlayerIds != null
                      ? 'Noch keine Spieler nominiert.\nÜber „Nominierung" zusagen.'
                      : widget.emptyHint,
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return _EmptyState(
            hint: widget.emptyHint,
            onAdd: () => _add(context),
            onPaste: () => _pasteImport(context),
          );
        }

        return Column(
          children: [
            if (_showSearch) _searchAndFilter(context, all),
            Expanded(
              child: players.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('Keine Treffer.',
                            style: TextStyle(color: Colors.grey)),
                      ),
                    )
                  : ListView.separated(
                      itemCount: players.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) =>
                          _playerTile(context, players[i], cards, ratings),
                    ),
            ),
            if (widget.showActions)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _add(context),
                        icon: const Icon(Icons.person_add),
                        label: const Text('Hinzufügen'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.tonalIcon(
                        onPressed: () => _pasteImport(context),
                        icon: const Icon(Icons.content_paste),
                        label: const Text('Einfügen'),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _playerTile(
    BuildContext context,
    Player p,
    Map<String, Map<CardType, int>> cards,
    Map<String, (double, int)> ratings,
  ) {
    final inactive = p.status == PlayerStatus.inaktiv;
    final tile = ListTile(
      leading: PlayerAvatar(player: p),
      title: Row(
        children: [
          Flexible(
              child: Text(p.fullName,
                  maxLines: 1, overflow: TextOverflow.ellipsis)),
          if (p.captainRole != CaptainRole.none) ...[
            const SizedBox(width: 6),
            Text(p.captainRole.badge,
                style: TextStyle(color: Theme.of(context).colorScheme.primary)),
          ],
          if (p.status != PlayerStatus.fit) ...[
            const SizedBox(width: 6),
            Text(p.status.symbol, style: const TextStyle(fontSize: 13)),
          ],
        ],
      ),
      subtitle: _subtitle(p, cards[p.id], ratings[p.id]),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => PlayerDetailScreen(player: p)),
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (v) {
          if (v == 'delete') _delete(context, p);
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'delete', child: Text('Löschen')),
        ],
      ),
    );
    // Inaktive Spieler dezent abgeblendet.
    return inactive ? Opacity(opacity: 0.55, child: tile) : tile;
  }

  /// Such- und Filterleiste über der Kaderliste.
  Widget _searchAndFilter(BuildContext context, List<Player> all) {
    int countOf(PlayerStatus s) => all.where((p) => p.status == s).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: Column(
        children: [
          TextField(
            controller: _searchCtrl,
            onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
            decoration: InputDecoration(
              hintText: 'Spieler suchen (Name, Nr., Position)',
              prefixIcon: const Icon(Icons.search),
              isDense: true,
              border: const OutlineInputBorder(),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchCtrl.clear();
                        setState(() => _query = '');
                      },
                    ),
            ),
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                ChoiceChip(
                  label: const Text('Alle'),
                  selected: _statusFilter == null,
                  onSelected: (_) => setState(() => _statusFilter = null),
                ),
                for (final s in PlayerStatus.values) ...[
                  const SizedBox(width: 6),
                  ChoiceChip(
                    avatar: Text(s.symbol, style: const TextStyle(fontSize: 12)),
                    label: Text('${s.label} (${countOf(s)})'),
                    selected: _statusFilter == s,
                    onSelected: (_) => setState(
                        () => _statusFilter = _statusFilter == s ? null : s),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Player> _applyFilter(List<Player> players) {
    return players.where((p) {
      if (_statusFilter != null && p.status != _statusFilter) return false;
      if (_query.isEmpty) return true;
      final hay = [
        p.fullName,
        p.position ?? '',
        p.number?.toString() ?? '',
      ].join(' ').toLowerCase();
      return hay.contains(_query);
    }).toList();
  }

  Future<_SquadData> _load(AppState state) async {
    final players = await state.playersOf(widget.teamId);
    final cards = await state.cardCountsForTeam(widget.teamId);
    final ratings = await state.ratingAveragesForTeam(widget.teamId);
    return _SquadData(players, cards, ratings);
  }

  /// Untertitel mit Position, Bewertungsschnitt und – falls vorhanden –
  /// Karten-Badges.
  Widget? _subtitle(Player p, Map<CardType, int>? cards, (double, int)? rating) {
    final parts = <Widget>[];
    if (p.position != null) parts.add(Text(p.position!));
    if (rating != null) {
      parts.add(Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.star, size: 13, color: Colors.amber.shade700),
          const SizedBox(width: 2),
          Text(rating.$1.toStringAsFixed(1)),
        ],
      ));
    }
    if (cards != null && cards.isNotEmpty) {
      final badges = <String>[
        for (final t in CardType.values)
          if ((cards[t] ?? 0) > 0) '${t.symbol} ${cards[t]}',
      ];
      if (badges.isNotEmpty) parts.add(Text(badges.join('  ')));
    }
    if (parts.isEmpty) return null;
    return Row(
      children: [
        for (var i = 0; i < parts.length; i++) ...[
          if (i > 0) const Text('  ·  '),
          parts[i],
        ],
      ],
    );
  }

  Future<void> _pasteImport(BuildContext context) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PasteImportScreen(
          teamId: widget.teamId,
          teamName: widget.teamName,
          fupaUrl: widget.fupaUrl,
        ),
      ),
    );
  }

  Future<void> _add(BuildContext context) async {
    final data = await showPlayerEditDialog(context);
    if (data == null || !context.mounted) return;
    await context.read<AppState>().addPlayer(
          widget.teamId,
          firstName: data.firstName,
          lastName: data.lastName,
          number: data.number,
          position: data.position,
          wishPosition: data.wishPosition,
          status: data.status,
          captainRole: data.captainRole,
        );
  }

  Future<void> _delete(BuildContext context, Player p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Spieler löschen?'),
        content: Text('„${p.fullName}" wirklich entfernen?'),
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
      await context.read<AppState>().deletePlayer(p.id);
    }
  }
}

class _SquadData {
  final List<Player> players;
  final Map<String, Map<CardType, int>> cardCounts;
  final Map<String, (double, int)> ratings;
  const _SquadData(this.players, this.cardCounts, this.ratings);
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.hint,
    required this.onAdd,
    required this.onPaste,
  });
  final String hint;
  final VoidCallback onAdd;
  final VoidCallback onPaste;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.group_off, size: 48, color: Colors.grey),
            const SizedBox(height: 12),
            Text(hint, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onPaste,
              icon: const Icon(Icons.content_paste),
              label: const Text('Liste einfügen'),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.person_add),
              label: const Text('Einzeln hinzufügen'),
            ),
          ],
        ),
      ),
    );
  }
}
