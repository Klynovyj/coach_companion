import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/enums.dart';
import '../models/match.dart';
import '../models/team.dart';
import '../services/fupa/fupa_dtos.dart';
import '../state/app_state.dart';
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
  bool _loading = true;

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
    if (!mounted) return;
    setState(() {
      _match = match;
      _ownTeam = own;
      _opponentTeam = opp;
      _nominatedIds = {
        for (final e in noms.entries)
          if (e.value == NominationStatus.zugesagt) e.key,
      };
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
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _ownTeam == null ? null : _openNomination,
                    icon: const Icon(Icons.how_to_reg),
                    label: const Text('Nominierung'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    // Aufstellung erst möglich, wenn Spieler nominiert sind.
                    onPressed: (_ownTeam == null || _nominatedIds.isEmpty)
                        ? null
                        : _openLineup,
                    icon: const Icon(Icons.dashboard_customize),
                    label: const Text('Aufstellung'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _openLive,
                    icon: const Icon(Icons.sports),
                    label: Text(match.status == MatchStatus.finished
                        ? 'Bericht'
                        : 'Live'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
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
            '${match.venue.label}${match.kickoff != null ? ' • ${df.format(match.kickoff!)}' : ''}',
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
