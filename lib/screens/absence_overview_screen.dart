import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/enums.dart';
import '../models/player.dart';
import '../models/player_absence.dart';
import '../state/app_state.dart';
import '../widgets/absence_actions.dart';
import '../widgets/availability_controls.dart';
import '../widgets/player_avatar.dart';

/// Zentrale Abwesenheits-Verwaltung: alle Spieler (inkl. Trainer/Staff) auf
/// einen Blick; pro Spieler Grundstatus (Fit/Inaktiv) setzen und Abwesenheiten
/// (Grund + Zeitraum) eintragen/ändern/löschen.
class AbsenceOverviewScreen extends StatefulWidget {
  const AbsenceOverviewScreen({super.key});

  @override
  State<AbsenceOverviewScreen> createState() => _AbsenceOverviewScreenState();
}

class _AbsenceOverviewScreenState extends State<AbsenceOverviewScreen> {
  final _df = DateFormat('dd.MM.yyyy', 'de_DE');
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  bool _matches(Player p) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return p.fullName.toLowerCase().contains(q) ||
        (p.nickname ?? '').toLowerCase().contains(q) ||
        (p.number?.toString() ?? '').contains(q);
  }

  // Sortier-Rang: Abwesende/Ausfälle zuerst, dann Fit, dann Inaktiv.
  static const _order = <PlayerStatus>[
    PlayerStatus.verletzt,
    PlayerStatus.gesperrt,
    PlayerStatus.krank,
    PlayerStatus.urlaub,
    PlayerStatus.abwesend,
    PlayerStatus.fit,
    PlayerStatus.inaktiv,
  ];

  int _rank(PlayerStatus s) {
    final i = _order.indexOf(s);
    return i < 0 ? _order.length : i;
  }

  Future<List<PlayerStatusInfo>> _load(AppState state, String teamId) async {
    final list = await state.squadStatus(teamId, includeStaff: true);
    list.sort((a, b) {
      final r = _rank(a.player.status).compareTo(_rank(b.player.status));
      if (r != 0) return r;
      return a.player.fullName.toLowerCase().compareTo(
        b.player.fullName.toLowerCase(),
      );
    });
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final team = state.ownTeam;
    final isTrainer = state.isTrainerHere;
    return Scaffold(
      appBar: AppBar(title: const Text('Abwesenheit')),
      body: team == null
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('Keine Mannschaft.', textAlign: TextAlign.center),
              ),
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                  child: TextField(
                    controller: _searchCtrl,
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
                              onPressed: () {
                                _searchCtrl.clear();
                                setState(() => _query = '');
                              },
                            ),
                    ),
                  ),
                ),
                Expanded(
                  child: FutureBuilder<List<PlayerStatusInfo>>(
                    future: _load(state, team.id),
                    builder: (context, snap) {
                      if (!snap.hasData) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      final all = snap.data!;
                      final list = all
                          .where((i) => _matches(i.player))
                          .toList();
                      return Column(
                        children: [
                          _summaryBar(context, all),
                          Expanded(
                            child: list.isEmpty
                                ? Center(
                                    child: Padding(
                                      padding: const EdgeInsets.all(24),
                                      child: Text(
                                        _query.isEmpty
                                            ? 'Noch keine Spieler.'
                                            : 'Keine Treffer für „$_query".',
                                      ),
                                    ),
                                  )
                                : ListView.separated(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 6,
                                    ),
                                    itemCount: list.length,
                                    separatorBuilder: (_, _) =>
                                        const Divider(height: 1),
                                    itemBuilder: (context, i) => _row(
                                      context,
                                      state,
                                      list[i],
                                      isTrainer,
                                    ),
                                  ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }

  Widget _row(
    BuildContext context,
    AppState state,
    PlayerStatusInfo info,
    bool isTrainer,
  ) {
    final p = info.player;
    final s = p.status;
    final subtitleParts = <String>[
      if (p.number != null) 'Nr. ${p.number}',
      if (p.staffRole != null && p.staffRole!.isNotEmpty) p.staffRole!,
      if (s.isAbsence && info.until != null) 'bis ${_df.format(info.until!)}',
    ];
    return ListTile(
      leading: PlayerAvatar(player: p, radius: 20),
      title: Text(p.fullName.isEmpty ? 'Spieler' : p.fullName),
      subtitle: subtitleParts.isEmpty ? null : Text(subtitleParts.join(' · ')),
      trailing: _statusChip(context, s),
      onTap: isTrainer ? () => _openSheet(context, state, p.id) : null,
    );
  }

  Widget _statusChip(BuildContext context, PlayerStatus s) {
    final c = playerStatusColor(s);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: c.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          absenceReasonIcon(s, size: 12),
          const SizedBox(width: 6),
          Text(
            s.label,
            style: TextStyle(color: c, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  // Reihenfolge der Zähl-Chips oben.
  static const _summaryOrder = <PlayerStatus>[
    PlayerStatus.fit,
    PlayerStatus.verletzt,
    PlayerStatus.krank,
    PlayerStatus.gesperrt,
    PlayerStatus.urlaub,
    PlayerStatus.abwesend,
    PlayerStatus.inaktiv,
  ];

  /// Zähl-Leiste: wie viele Spieler je Status (Fit/Verletzt/Krank …).
  Widget _summaryBar(BuildContext context, List<PlayerStatusInfo> all) {
    int countOf(PlayerStatus s) =>
        all.where((i) => i.player.status == s).length;
    final chips = <Widget>[
      _summaryChip(
        context,
        const Icon(Icons.groups, size: 14),
        'Kader',
        all.length,
        strong: true,
      ),
      for (final s in _summaryOrder)
        if (countOf(s) > 0)
          _summaryChip(
            context,
            absenceReasonIcon(s, size: 13),
            s.label,
            countOf(s),
            color: playerStatusColor(s),
          ),
    ];
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        children: [
          for (final c in chips)
            Padding(padding: const EdgeInsets.only(right: 8), child: c),
        ],
      ),
    );
  }

  Widget _summaryChip(
    BuildContext context,
    Widget icon,
    String label,
    int n, {
    Color? color,
    bool strong = false,
  }) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: c.withValues(alpha: strong ? 0.18 : 0.10),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          icon,
          const SizedBox(width: 6),
          Text(
            '$n $label',
            style: TextStyle(
              color: c,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  /// Inline-Sheet: Grundstatus setzen, Abwesenheit eintragen/ändern/löschen.
  Future<void> _openSheet(
    BuildContext context,
    AppState state,
    String playerId,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _PlayerAbsenceSheet(state: state, playerId: playerId),
    );
    if (mounted) setState(() {}); // Liste nach Änderungen neu laden
  }
}

/// Inhalt des Inline-Sheets für einen Spieler.
class _PlayerAbsenceSheet extends StatefulWidget {
  const _PlayerAbsenceSheet({required this.state, required this.playerId});

  final AppState state;
  final String playerId;

  @override
  State<_PlayerAbsenceSheet> createState() => _PlayerAbsenceSheetState();
}

class _PlayerAbsenceSheetState extends State<_PlayerAbsenceSheet> {
  final _df = DateFormat('dd.MM.yyyy', 'de_DE');
  Player? _player;
  List<PlayerAbsence> _absences = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final p = await widget.state.playerById(widget.playerId);
    final abs = await widget.state.absencesOf(widget.playerId);
    abs.sort((a, b) => b.from.compareTo(a.from));
    if (!mounted) return;
    setState(() {
      _player = p;
      _absences = abs;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = _player;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: _loading || p == null
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    p.fullName.isEmpty ? 'Spieler' : p.fullName,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Status',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final s in PlayerStatus.settableStatuses)
                        ChoiceChip(
                          avatar: absenceReasonIcon(s, size: 16),
                          label: Text(s.label),
                          selected: p.status == s,
                          onSelected: (_) async {
                            final ok = await setStatusFlow(
                              context,
                              widget.state,
                              p,
                              s,
                            );
                            if (ok) await _reload();
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Abwesenheiten',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () async {
                          final ok = await addAbsenceFlow(
                            context,
                            widget.state,
                            p,
                          );
                          if (ok) await _reload();
                        },
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('Eintragen'),
                      ),
                    ],
                  ),
                  if (_absences.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 4),
                      child: Text(
                        'Keine Einträge.',
                        style: TextStyle(color: Colors.grey),
                      ),
                    )
                  else
                    Flexible(
                      child: ListView(
                        shrinkWrap: true,
                        children: [for (final a in _absences) _absenceTile(a)],
                      ),
                    ),
                  const SizedBox(height: 8),
                ],
              ),
      ),
    );
  }

  Widget _absenceTile(PlayerAbsence a) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final expired = a.until.isBefore(today);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: absenceReasonIcon(a.status, size: 20),
      title: Text(
        '${a.status.label} · ${_df.format(a.from)} – ${_df.format(a.until)}',
      ),
      subtitle: a.note == null
          ? null
          : Text(a.note!, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (expired)
            const Text(
              'abgelaufen',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            )
          else
            Icon(Icons.circle, size: 10, color: playerStatusColor(a.status)),
          IconButton(
            tooltip: 'Löschen',
            icon: const Icon(Icons.delete_outline, size: 20),
            onPressed: () async {
              await widget.state.deleteAbsence(a);
              await _reload();
            },
          ),
        ],
      ),
      onTap: () async {
        final ok = await editAbsenceFlow(context, widget.state, a);
        if (ok) await _reload();
      },
    );
  }
}
