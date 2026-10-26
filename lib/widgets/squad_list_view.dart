import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/enums.dart';
import '../models/player.dart';
import '../models/player_stat.dart';
import '../models/scout_marker.dart';
import '../screens/paste_import_screen.dart';
import '../screens/player_detail_screen.dart';
import '../state/app_state.dart';
import 'opponent_scout_sheet.dart';
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
    this.isOpponent = false,
  });

  final String teamId;
  final String teamName;
  final String? fupaUrl;
  final String emptyHint;

  /// Zeigt die Buttons „Hinzufügen"/„Einfügen" (im Spielcenter ausgeblendet).
  final bool showActions;

  /// Wenn gesetzt, werden nur diese Spieler angezeigt (z.B. nur Nominierte).
  final Set<String>? onlyPlayerIds;

  /// Gegner-Modus: kein Spielerprofil, stattdessen Scouting (Marker/Kommentar)
  /// und Toranzahl aus der Statistik.
  final bool isOpponent;

  @override
  State<SquadListView> createState() => _SquadListViewState();
}

class _SquadListViewState extends State<SquadListView> {
  final _searchCtrl = TextEditingController();
  String _query = '';
  PlayerStatus? _statusFilter;
  bool _filterVisible = false; // Status-Filter nur bei Bedarf einblenden

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
        final markers = snap.data!.markers;
        final goals = snap.data!.goals;
        final stats = snap.data!.stats;

        var players = all;
        if (widget.onlyPlayerIds != null) {
          players =
              players.where((p) => widget.onlyPlayerIds!.contains(p.id)).toList();
        }
        if (_showSearch) {
          players = _applyFilter(players);
        }
        // Trainerteam getrennt führen: erscheint nicht in der Spielerliste und
        // nur im vollen Kader (nicht bei Nominierungs-/Gegneransicht).
        final staff = (!widget.isOpponent && widget.onlyPlayerIds == null)
            ? players.where((p) => p.isStaffOnly).toList()
            : const <Player>[];
        players = players.where((p) => !p.isStaffOnly).toList();

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
              child: (players.isEmpty && staff.isEmpty)
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('Keine Treffer.',
                            style: TextStyle(color: Colors.grey)),
                      ),
                    )
                  : ListView(
                      children: [
                        for (var i = 0; i < players.length; i++) ...[
                          if (i > 0) const Divider(height: 1),
                          _playerTile(context, players[i], cards, ratings,
                              markers, goals, stats),
                        ],
                        if (staff.isNotEmpty) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                            child: Row(
                              children: [
                                Icon(Icons.sports,
                                    size: 18,
                                    color:
                                        Theme.of(context).colorScheme.primary),
                                const SizedBox(width: 8),
                                Text('Trainerteam',
                                    style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary)),
                              ],
                            ),
                          ),
                          const Divider(height: 1),
                          for (var i = 0; i < staff.length; i++) ...[
                            if (i > 0) const Divider(height: 1),
                            _staffTile(context, staff[i]),
                          ],
                        ],
                      ],
                    ),
            ),
            if (widget.showActions)
              Padding(
                padding: const EdgeInsets.all(12),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () => _add(context),
                    icon: const Icon(Icons.person_add),
                    label: const Text('Spieler hinzufügen'),
                  ),
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
    Map<String, Set<ScoutMarker>> markers,
    Map<String, int> goals,
    Map<String, PlayerStat> stats,
  ) {
    if (widget.isOpponent) {
      return _opponentTile(context, p, markers, stats[p.dedupKey]);
    }

    final inactive = p.status == PlayerStatus.inaktiv;
    final tile = ListTile(
      leading: PlayerAvatar(player: p),
      title: Row(
        children: [
          Flexible(
              child: Text(p.fullName,
                  maxLines: 1, overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 6),
          _sourceBadge(context, p),
          if (p.captainRole != CaptainRole.none) ...[
            const SizedBox(width: 6),
            Text(p.captainRole.badge,
                style: TextStyle(color: Theme.of(context).colorScheme.primary)),
          ],
          if (p.status != PlayerStatus.fit) ...[
            const SizedBox(width: 6),
            if (p.status == PlayerStatus.verletzt)
              Container(
                width: 16,
                height: 16,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.error,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.add, size: 12, color: Colors.white),
              )
            else
              Text(p.status.symbol, style: const TextStyle(fontSize: 13)),
          ],
          if (p.suspendedGames > 0) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.error,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text('⛔ ${p.suspendedGames}',
                  style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: Colors.white)),
            ),
          ],
          if (p.isStarter) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color:
                    Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text('S11',
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.primary)),
            ),
          ],
        ],
      ),
      subtitle: _subtitle(p, cards[p.id], ratings[p.id], stats[p.dedupKey]),
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

  /// Trainerteam-Kachel: Name + Rolle, tippbar ins Profil.
  Widget _staffTile(BuildContext context, Player p) {
    return ListTile(
      leading: PlayerAvatar(player: p),
      title: Text(p.fullName),
      subtitle: Text(p.staffRole ?? 'Trainerteam',
          style: Theme.of(context).textTheme.bodySmall),
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
  }

  /// Gegner-Kachel: kein Profil, Tippen öffnet das Scouting-Blatt.
  /// Zeigt Scout-Marker und – falls vorhanden – die Toranzahl.
  Widget _opponentTile(
    BuildContext context,
    Player p,
    Map<String, Set<ScoutMarker>> markers,
    PlayerStat? stat,
  ) {
    final ms = (markers[p.id] ?? const <ScoutMarker>{}).toList();
    final g = stat?.goals ?? 0;
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: PlayerAvatar(player: p),
      title: Row(
        children: [
          Flexible(
              child: Text(p.fullName,
                  maxLines: 1, overflow: TextOverflow.ellipsis)),
          if (g >= 5) ...[
            const SizedBox(width: 6),
            Icon(Icons.local_fire_department,
                size: 15, color: Colors.red.shade700),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (p.position != null)
            Text(p.position!, maxLines: 1, overflow: TextOverflow.ellipsis),
          if (stat != null &&
              (stat.matches > 0 || stat.goals > 0 || stat.assists > 0))
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '${stat.matches} Sp · ⚽ ${stat.goals} · 🅰 ${stat.assists}',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: g >= 5 ? Colors.red.shade700 : null),
              ),
            ),
        ],
      ),
      trailing: ms.isEmpty
          ? const Icon(Icons.chevron_right)
          : Wrap(
              spacing: 2,
              children: [
                for (final m in ms.take(4))
                  Icon(m.icon, size: 16, color: scheme.primary),
              ],
            ),
      onTap: () => showOpponentScoutSheet(context, p, goals: g),
    );
  }

  /// Suchleiste mit Filter-Icon; der Status-Filter erscheint nur bei Bedarf.
  Widget _searchAndFilter(BuildContext context, List<Player> all) {
    int countOf(PlayerStatus s) => all.where((p) => p.status == s).length;
    final filterActive = _statusFilter != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  onChanged: (v) =>
                      setState(() => _query = v.trim().toLowerCase()),
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
              ),
              const SizedBox(width: 6),
              IconButton.filledTonal(
                tooltip: 'Status-Filter',
                isSelected: _filterVisible || filterActive,
                icon: Badge(
                  isLabelVisible: filterActive,
                  child: const Icon(Icons.filter_list),
                ),
                onPressed: () =>
                    setState(() => _filterVisible = !_filterVisible),
              ),
            ],
          ),
          if (_filterVisible) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                ChoiceChip(
                  label: const Text('Alle'),
                  selected: _statusFilter == null,
                  onSelected: (_) => setState(() => _statusFilter = null),
                ),
                for (final s in PlayerStatus.values)
                  ChoiceChip(
                    avatar:
                        Text(s.symbol, style: const TextStyle(fontSize: 12)),
                    label: Text('${s.label} (${countOf(s)})'),
                    selected: _statusFilter == s,
                    onSelected: (_) => setState(
                        () => _statusFilter = _statusFilter == s ? null : s),
                  ),
              ],
            ),
          ],
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
    // Scouting-Daten nur für den Gegner laden.
    final markers = widget.isOpponent
        ? await state.scoutMarkersForTeam(widget.teamId)
        : const <String, Set<ScoutMarker>>{};
    // Beim Gegner die Statistik bei Bedarf automatisch nachladen.
    if (widget.isOpponent) {
      await state.ensureOpponentStats(widget.teamId);
    }
    final goals = widget.isOpponent
        ? await state.scoutGoals(widget.teamId)
        : const <String, int>{};
    // FuPa-Saisonstatistik je Spieler (über den Namen zugeordnet).
    final statsList = await state.statsOf(widget.teamId);
    final stats = <String, PlayerStat>{
      for (final s in statsList)
        '${s.firstName.trim().toLowerCase()}|${s.lastName.trim().toLowerCase()}':
            s,
    };
    return _SquadData(players, cards, ratings, markers, goals, stats);
  }

  /// Untertitel mit Position, Bewertungsschnitt, Karten-Badges und – falls
  /// vorhanden – der FuPa-Saisonstatistik (Spiele/Tore/Vorlagen).
  Widget? _subtitle(Player p, Map<CardType, int>? cards, (double, int)? rating,
      PlayerStat? stat) {
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
    final statLine = _statLine(stat);
    if (parts.isEmpty && statLine == null) return null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (parts.isNotEmpty)
          Row(
            children: [
              for (var i = 0; i < parts.length; i++) ...[
                if (i > 0) const Text('  ·  '),
                parts[i],
              ],
            ],
          ),
        ?statLine,
      ],
    );
  }

  /// Kompakte Saison-Zeile (FuPa): „13 Sp · ⚽ 5 · 🅰 3".
  Widget? _statLine(PlayerStat? s) {
    if (s == null || (s.matches == 0 && s.goals == 0 && s.assists == 0)) {
      return null;
    }
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        '${s.matches} Sp · ⚽ ${s.goals} · 🅰 ${s.assists}',
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
      ),
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

  /// Herkunfts-Badge: „FuPa" für importierte, „Manuell" für selbst angelegte
  /// Spieler – damit klar ist, wer (nicht) bei FuPa gepflegt wird.
  Widget _sourceBadge(BuildContext context, Player p) {
    final isFupa = p.source == DataSource.fupaApproved;
    final bg = isFupa
        ? const Color(0xFF138A54)
        : Theme.of(context).colorScheme.outline;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
      child: Text(isFupa ? 'FuPa' : 'Manuell',
          style: const TextStyle(
              fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white)),
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
  final Map<String, Set<ScoutMarker>> markers;
  final Map<String, int> goals;
  final Map<String, PlayerStat> stats;
  const _SquadData(this.players, this.cardCounts, this.ratings, this.markers,
      this.goals, this.stats);
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
