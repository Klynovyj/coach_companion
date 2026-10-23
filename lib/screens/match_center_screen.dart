import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/enums.dart';
import '../models/match.dart';
import '../models/team.dart';
import '../services/fupa/fupa_dtos.dart';
import '../state/app_state.dart';
import '../widgets/reset_dialog.dart';
import '../widgets/squad_list_view.dart';
import '../widgets/team_logo.dart';
import 'lineup_editor_screen.dart';
import 'live_match_screen.dart';
import 'nomination_screen.dart';

class MatchCenterScreen extends StatefulWidget {
  const MatchCenterScreen({super.key, required this.matchId});
  final String matchId;

  @override
  State<MatchCenterScreen> createState() => _MatchCenterScreenState();
}

class _MatchCenterScreenState extends State<MatchCenterScreen> {
  GameMatch? _match;
  Team? _ownTeam;
  Team? _opponentTeam;
  ImportResult? _syncResult;
  Set<String> _nominatedIds = {};
  int _starterCount = 0;
  bool _loading = true;

  bool get _hasNominations => _nominatedIds.isNotEmpty;
  bool get _hasLineup => _starterCount > 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(initial: true));
  }

  Future<void> _load({bool initial = false, bool force = false}) async {
    final state = context.read<AppState>();
    var match = await state.getMatch(widget.matchId);
    if (match == null) {
      setState(() => _loading = false);
      return;
    }
    // Beim Öffnen Gegner sicherstellen (Import oder Platzhalter).
    ImportResult? result;
    if (initial || force) {
      result = await state.openMatch(match, force: force);
      match = await state.getMatch(widget.matchId);
    }
    final own = await state.repository.getTeam(match!.ownTeamId);
    final opp = match.opponentTeamId == null
        ? null
        : await state.repository.getTeam(match.opponentTeamId!);
    final noms = await state.nominationsOf(widget.matchId);
    // Aufstellung vorhanden? (Starter gezählt, ohne eine neue Aufstellung anzulegen)
    var starters = 0;
    final lineup = await state.repository.getLineup(widget.matchId, match.ownTeamId);
    if (lineup != null) {
      final entries = await state.lineupEntries(lineup.id);
      starters = entries.where((e) => e.role == LineupRole.starter).length;
    }
    if (!mounted) return;
    setState(() {
      _match = match;
      _ownTeam = own;
      _opponentTeam = opp;
      _nominatedIds = {
        for (final e in noms.entries)
          if (e.value == NominationStatus.zugesagt) e.key,
      };
      _starterCount = starters;
      if (result != null) _syncResult = result;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final match = _match;
    if (match == null) {
      return const Scaffold(body: Center(child: Text('Spiel nicht gefunden.')));
    }
    final df = DateFormat('dd.MM.yyyy • HH:mm', 'de_DE');

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text('vs ${match.opponentName}'),
          bottom: TabBar(
            labelColor: Theme.of(context).colorScheme.onPrimary,
            unselectedLabelColor:
                Theme.of(context).colorScheme.onPrimary.withValues(alpha: 0.7),
            indicatorColor: Theme.of(context).colorScheme.onPrimary,
            labelStyle: const TextStyle(fontWeight: FontWeight.bold),
            tabs: const [
              Tab(text: 'Eigenes Team'),
              Tab(text: 'Gegner'),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Gegner neu synchronisieren',
              icon: const Icon(Icons.sync),
              onPressed: () => _load(force: true),
            ),
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'reset') _resetMatch();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'reset', child: Text('Spiel zurücksetzen')),
              ],
            ),
          ],
        ),
        body: Column(
          children: [
            _Header(
              match: match,
              df: df,
              ownLogo: _ownTeam?.logoPath,
              oppLogo: _opponentTeam?.logoPath ?? match.opponentLogoPath,
            ),
            if (_syncResult != null && _syncResult!.status != ImportStatus.alreadyPresent)
              _SyncBanner(result: _syncResult!),
            Expanded(
              child: TabBarView(
                children: [
                  _ownTeam == null
                      ? const Center(child: Text('Kein eigenes Team.'))
                      : SquadListView(
                          teamId: _ownTeam!.id,
                          teamName: _ownTeam!.name,
                          fupaUrl: _ownTeam!.fupaUrl,
                          showActions: false,
                          onlyPlayerIds: _nominatedIds,
                        ),
                  _opponentTeam == null
                      ? const Center(
                          child: Text('Gegner wird vorbereitet …'))
                      : SquadListView(
                          teamId: _opponentTeam!.id,
                          teamName: _opponentTeam!.name,
                          fupaUrl: _opponentTeam!.fupaUrl,
                          showActions: false,
                        ),
                ],
              ),
            ),
          ],
        ),
        bottomNavigationBar: SafeArea(
          child: _stepBar(context, match),
        ),
      ),
    );
  }

  /// Geführte Schritt-Leiste: Nominierung → Aufstellung → Live.
  Widget _stepBar(BuildContext context, GameMatch match) {
    final finished = match.status == MatchStatus.finished;
    // Aktueller Schritt (1/2/3) für die Hervorhebung.
    final step = !_hasNominations ? 1 : (!_hasLineup ? 2 : 3);

    Widget stepButton({
      required int index,
      required IconData icon,
      required String label,
      required VoidCallback onTap,
    }) {
      final active = step == index;
      final child = Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 6),
          Flexible(
            child: Text(label,
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      );
      return Expanded(
        child: active
            ? FilledButton(onPressed: onTap, child: child)
            : OutlinedButton(onPressed: onTap, child: child),
      );
    }

    final hint = switch (step) {
      1 => 'Schritt 1 von 3: Spieler nominieren',
      2 => 'Schritt 2 von 3: Aufstellung festlegen',
      _ => finished ? 'Spiel beendet' : 'Bereit – du kannst live gehen',
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline,
                  size: 15, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 6),
              Text(hint, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              stepButton(
                index: 1,
                icon: Icons.how_to_reg,
                label: 'Nominierung',
                onTap: _ownTeam == null ? () {} : _openNomination,
              ),
              const SizedBox(width: 8),
              stepButton(
                index: 2,
                icon: Icons.dashboard_customize,
                label: 'Aufstellung',
                onTap: _tryOpenLineup,
              ),
              const SizedBox(width: 8),
              stepButton(
                index: 3,
                icon: Icons.sports,
                label: finished ? 'Bericht' : 'Live',
                onTap: () => _tryOpenLive(finished),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _tryOpenLineup() {
    if (_ownTeam == null) return;
    if (!_hasNominations) {
      _snack('Bitte zuerst Spieler nominieren.');
      return;
    }
    _openLineup();
  }

  void _tryOpenLive(bool finished) {
    // Bericht (beendet) ist immer erlaubt; Live braucht eine Aufstellung.
    if (!finished && !_hasLineup) {
      _snack(_hasNominations
          ? 'Bitte zuerst die Aufstellung festlegen.'
          : 'Bitte zuerst nominieren und aufstellen.');
      return;
    }
    _openLive();
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _openNomination() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => NominationScreen(
          matchId: widget.matchId,
          teamId: _ownTeam!.id,
          title: _match!.opponentName,
        ),
      ),
    );
    if (mounted) _load(); // Nominierungen neu laden (Kader-Filter + Aufstellung-Gate)
  }

  Future<void> _resetMatch() async {
    final match = _match;
    if (match == null) return;
    final choice = await showResetMatchDialog(context);
    if (choice == null || !choice.any || !mounted) return;
    await context.read<AppState>().resetMatchParts(
          widget.matchId,
          match.ownTeamId,
          verlauf: choice.verlauf,
          aufstellung: choice.aufstellung,
          nominierung: choice.nominierung,
        );
    if (mounted) _load();
  }

  Future<void> _openLineup() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => LineupEditorScreen(
          matchId: widget.matchId,
          teamId: _ownTeam!.id,
          teamName: _ownTeam!.name,
        ),
      ),
    );
    if (mounted) _load(); // Aufstellungs-Status neu laden (schaltet „Live" frei)
  }

  Future<void> _openLive() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => LiveMatchScreen(matchId: widget.matchId),
      ),
    );
    if (mounted) _load();
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.match,
    required this.df,
    this.ownLogo,
    this.oppLogo,
  });
  final GameMatch match;
  final DateFormat df;
  final String? ownLogo;
  final String? oppLogo;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final ownName = state.ownTeam?.name ?? 'Mein Team';
    return Container(
      width: double.infinity,
      color: scheme.primary,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        children: [
          Text(
            '${match.venue.label}${match.kickoff != null ? ' • ${df.format(match.kickoff!.toLocal())}' : ''}',
            style: TextStyle(color: scheme.onPrimary.withValues(alpha: 0.9)),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: _side(scheme, ownLogo, ownName)),
              Text('${match.ownScore} : ${match.opponentScore}',
                  style: TextStyle(
                      color: scheme.onPrimary,
                      fontSize: 28,
                      fontWeight: FontWeight.bold)),
              Expanded(child: _side(scheme, oppLogo, match.opponentName)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _side(ColorScheme scheme, String? logo, String name) {
    return Column(
      children: [
        if (logo != null) ...[
          TeamLogo(logoPath: logo, size: 40),
          const SizedBox(height: 4),
        ],
        Text(name,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: scheme.onPrimary, fontWeight: FontWeight.bold)),
      ],
    );
  }
}

class _SyncBanner extends StatelessWidget {
  const _SyncBanner({required this.result});
  final ImportResult result;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (result.status) {
      ImportStatus.success => (Icons.cloud_done, Colors.green.shade700),
      ImportStatus.error => (Icons.error_outline, Colors.red.shade700),
      _ => (Icons.edit_note, Colors.orange.shade800),
    };
    return Container(
      width: double.infinity,
      color: color.withValues(alpha: 0.10),
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 8),
          Expanded(
              child: Text(result.message,
                  style: Theme.of(context).textTheme.bodySmall)),
        ],
      ),
    );
  }
}
