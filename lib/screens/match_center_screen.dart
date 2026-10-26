import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/enums.dart';
import '../models/match.dart';
import '../models/player.dart';
import '../models/team.dart';
import '../services/fupa/fupa_dtos.dart';
import '../services/share_service.dart';
import '../state/app_state.dart';
import '../widgets/reset_dialog.dart';
import '../widgets/squad_list_view.dart';
import '../widgets/team_logo.dart';
import 'gegner_analyse_screen.dart';
import 'lineups_list_screen.dart';
import 'live_match_screen.dart';
import 'nomination_screen.dart';
import 'rating_screen.dart';

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

  late final AppState _app = context.read<AppState>();

  @override
  void initState() {
    super.initState();
    // Live-Updates anderer Trainer (Realtime) sofort übernehmen (ohne erneuten
    // Gegner-Import – nur Daten/Schritt-Status neu laden).
    _app.addListener(_onChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(initial: true));
  }

  void _onChanged() {
    if (mounted) _load();
  }

  @override
  void dispose() {
    _app.removeListener(_onChanged);
    super.dispose();
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
    // Freigegebene Aufstellung vorhanden? (nur die zählt für „Live")
    var starters = 0;
    final lineup = await state.repository.getReleasedLineup(
      widget.matchId,
      match.ownTeamId,
    );
    if (lineup != null && lineup.released) {
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
    // Spieler (Nicht-Trainer) sehen Nominierung/Aufstellung/Bewertung nicht.
    final isTrainer = context.watch<AppState>().isTrainerHere;

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text('vs ${match.opponentName}'),
          bottom: TabBar(
            labelColor: Theme.of(context).colorScheme.onPrimary,
            unselectedLabelColor: Theme.of(
              context,
            ).colorScheme.onPrimary.withValues(alpha: 0.7),
            indicatorColor: Theme.of(context).colorScheme.onPrimary,
            labelStyle: const TextStyle(fontWeight: FontWeight.bold),
            tabs: const [
              Tab(text: 'Eigenes Team'),
              Tab(text: 'Gegner'),
            ],
          ),
          actions: [
            if (isTrainer && match.status == MatchStatus.finished)
              IconButton(
                tooltip: 'Spieler & Spiel bewerten',
                icon: const Icon(Icons.star_rate),
                onPressed: _openRating,
              ),
            if (isTrainer)
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'sync') _load(force: true);
                  if (v == 'reset') _resetMatch();
                  if (v == 'rate') _openRating();
                  if (v == 'announce') _shareAnnouncement();
                  if (v == 'adopt_fupa') _adoptFupaResult();
                },
                itemBuilder: (_) => [
                  if (match.locallyManaged)
                    const PopupMenuItem(
                      value: 'adopt_fupa',
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.cloud_download_outlined),
                        title: Text('Ergebnis aus FuPa übernehmen'),
                      ),
                    ),
                  const PopupMenuItem(
                    value: 'announce',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.campaign_outlined),
                      title: Text('Spieltags-Info teilen'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'sync',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.sync),
                      title: Text('Gegner neu synchronisieren'),
                    ),
                  ),
                  if (match.status == MatchStatus.finished)
                    const PopupMenuItem(
                      value: 'rate',
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.star_border),
                        title: Text('Spieler bewerten'),
                      ),
                    ),
                  PopupMenuItem(
                    value: 'reset',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.restart_alt),
                      title: Text('Spiel zurücksetzen'),
                    ),
                  ),
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
            if (_syncResult != null &&
                _syncResult!.status != ImportStatus.alreadyPresent)
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
                      ? const Center(child: Text('Gegner wird vorbereitet …'))
                      : Column(
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                              child: SizedBox(
                                width: double.infinity,
                                child: FilledButton.tonalIcon(
                                  onPressed: _openAnalyse,
                                  icon: const Icon(Icons.insights),
                                  label: const Text('Gegner-Analyse'),
                                ),
                              ),
                            ),
                            Expanded(
                              child: SquadListView(
                                teamId: _opponentTeam!.id,
                                teamName: _opponentTeam!.name,
                                fupaUrl: _opponentTeam!.fupaUrl,
                                showActions: false,
                                isOpponent: true,
                              ),
                            ),
                          ],
                        ),
                ],
              ),
            ),
          ],
        ),
        bottomNavigationBar: SafeArea(
          child: _stepBar(context, match, isTrainer),
        ),
      ),
    );
  }

  /// Geführte Schritt-Leiste: Nominierung → Aufstellung → Live. Spieler
  /// (Nicht-Trainer) sehen nur „Live/Bericht" (Ticker ansehen).
  Widget _stepBar(BuildContext context, GameMatch match, bool isTrainer) {
    final finished = match.status == MatchStatus.finished;
    if (!isTrainer) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
        child: SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: () => _openLive(),
            icon: const Icon(Icons.sports),
            label: Text(finished ? 'Bericht ansehen' : 'Live ansehen'),
          ),
        ),
      );
    }
    // Aktueller Schritt (1/2/3) für die Hervorhebung.
    final step = !_hasNominations ? 1 : (!_hasLineup ? 2 : 3);

    Widget stepButton({
      required int index,
      required IconData icon,
      required String label,
      required VoidCallback onTap,
    }) {
      final active = step == index;
      // Icon über Label – so bleibt der Text auch auf schmalen Handys lesbar.
      final child = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 20),
          const SizedBox(height: 3),
          Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.visible,
            softWrap: false,
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
          ),
        ],
      );
      final style = ButtonStyle(
        padding: WidgetStateProperty.all(
          const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        ),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      );
      return Expanded(
        child: active
            ? FilledButton(onPressed: onTap, style: style, child: child)
            : OutlinedButton(onPressed: onTap, style: style, child: child),
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
              Icon(
                Icons.info_outline,
                size: 15,
                color: Theme.of(context).colorScheme.primary,
              ),
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
      _snack(
        _hasNominations
            ? 'Bitte zuerst eine Aufstellung freigeben.'
            : 'Bitte zuerst nominieren und eine Aufstellung freigeben.',
      );
      return;
    }
    _openLive();
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _openNomination() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => NominationScreen(
          matchId: widget.matchId,
          teamId: _ownTeam!.id,
          title: _match!.opponentName,
          readOnly: _match?.status == MatchStatus.finished,
        ),
      ),
    );
    if (mounted) {
      _load(); // Nominierungen neu laden (Kader-Filter + Aufstellung-Gate)
    }
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

  /// Hebt die Selbstverwaltung auf und holt das echte Ergebnis aus FuPa.
  Future<void> _adoptFupaResult() async {
    final messenger = ScaffoldMessenger.of(context);
    await context.read<AppState>().adoptFupaResult(widget.matchId);
    if (!mounted) return;
    await _load();
    messenger.showSnackBar(
      const SnackBar(content: Text('Ergebnis aus FuPa übernommen.')),
    );
  }

  Future<void> _openLineup() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => LineupsListScreen(
          matchId: widget.matchId,
          teamId: _ownTeam!.id,
          teamName: _ownTeam!.name,
          matchFinished: _match?.status == MatchStatus.finished,
        ),
      ),
    );
    if (mounted) {
      _load(); // Aufstellungs-Status neu laden (schaltet „Live" frei)
    }
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

  Future<void> _openRating() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => RatingScreen(matchId: widget.matchId)),
    );
    if (mounted) _load();
  }

  Future<void> _openAnalyse() async {
    final opp = _opponentTeam;
    final match = _match;
    if (opp == null || match == null) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => GegnerAnalyseScreen(
          ownTeamId: match.ownTeamId,
          opponentTeamId: opp.id,
          opponentName: opp.name,
          opponentLogoPath: opp.logoPath ?? match.opponentLogoPath,
        ),
      ),
    );
  }

  /// Spieltags-Ankündigung: Formular öffnen (Felder je Spiel gemerkt),
  /// Nachricht bauen und per WhatsApp teilen.
  Future<void> _shareAnnouncement() async {
    final match = _match;
    if (match == null) return;
    final state = context.read<AppState>();
    var info = await state.matchAnnouncement(widget.matchId);
    // Noch nichts für dieses Spiel gespeichert → Werte vom letzten Spieltag
    // übernehmen (Best-Guess, Nutzer korrigiert). Spieltag automatisch +1.
    if (info.isEmpty) {
      final last = await state.matchAnnouncement('last_${match.ownTeamId}');
      if (last.isNotEmpty) {
        info = {...last};
        final n = int.tryParse((last['spieltag'] ?? '').trim());
        if (n != null) info['spieltag'] = '${n + 1}';
      }
    }
    // Spieltag-Nr. aus FuPa (round.number) ist maßgeblich, falls bekannt.
    if ((info['spieltag'] ?? '').trim().isEmpty && match.matchday != null) {
      info = {...info, 'spieltag': '${match.matchday}'};
    }
    final players = await state.playersOf(match.ownTeamId);
    final noms = await state.nominationsOf(widget.matchId);
    if (!mounted) return;
    final data = await Navigator.push<Map<String, String>>(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _AnnouncementPage(initial: info),
      ),
    );
    if (data == null || !mounted) return;
    await state.saveMatchAnnouncement(widget.matchId, data);
    // Als Vorlage für den nächsten Spieltag merken.
    await state.saveMatchAnnouncement('last_${match.ownTeamId}', data);
    await shareViaWhatsApp(_buildAnnouncement(data, match, players, noms));
  }

  String _buildAnnouncement(
    Map<String, String> d,
    GameMatch match,
    List<Player> players,
    Map<String, NominationStatus> noms,
  ) {
    final tf = DateFormat('HH:mm', 'de_DE');
    final b = StringBuffer();

    final intro = (d['intro'] ?? '').trim();
    if (intro.isNotEmpty) {
      b.writeln(intro);
      b.writeln('');
    }
    final trikot = (d['trikot'] ?? '').trim();
    if (trikot.isNotEmpty) {
      b.writeln('Trikot: $trikot');
      b.writeln('');
    }
    final adresse = (d['adresse'] ?? '').trim();
    if (adresse.isNotEmpty) {
      b.writeln('Adresse:');
      b.writeln(adresse);
      b.writeln('');
    }
    final treff = (d['treffpunkte'] ?? '').trim();
    if (treff.isNotEmpty || match.kickoff != null) {
      b.writeln('Treffpunkte & Zeiten:');
      if (treff.isNotEmpty) b.writeln(treff);
      if (match.kickoff != null) {
        b.writeln('Anstoß: ${tf.format(match.kickoff!.toLocal())} Uhr');
      }
      b.writeln('');
    }
    b.writeln(_ownTeam?.name ?? match.opponentName);
    final spieltag = (d['spieltag'] ?? '').trim();
    if (spieltag.isNotEmpty) b.writeln('$spieltag. Spieltag');

    // Aufgebot: Zugesagte + „Unter Vorbehalt" (markiert), alphabetisch.
    final byId = {for (final p in players) p.id: p};
    final roster = <MapEntry<String, bool>>[];
    noms.forEach((id, status) {
      final p = byId[id];
      if (p == null) return;
      // Spitzname bevorzugen (wie im Beispiel-Aufgebot), sonst voller Name.
      final name = (p.nickname != null && p.nickname!.trim().isNotEmpty)
          ? p.nickname!.trim()
          : p.fullName;
      if (status == NominationStatus.zugesagt) {
        roster.add(MapEntry(name, false));
      } else if (status == NominationStatus.unterVorbehalt) {
        roster.add(MapEntry(name, true));
      }
    });
    roster.sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));
    if (roster.isNotEmpty) {
      b.writeln('');
      b.writeln('Aufgebot (${roster.length} Spieler):');
      for (var i = 0; i < roster.length; i++) {
        b.writeln(
          '${i + 1}. ${roster[i].key}'
          '${roster[i].value ? ' (unter Vorbehalt)' : ''}',
        );
      }
    }
    return b.toString().trim();
  }
}

/// Vollbild-Formular für die Spieltags-Ankündigung.
class _AnnouncementPage extends StatefulWidget {
  const _AnnouncementPage({required this.initial});
  final Map<String, String> initial;

  @override
  State<_AnnouncementPage> createState() => _AnnouncementPageState();
}

class _AnnouncementPageState extends State<_AnnouncementPage> {
  late final TextEditingController _spieltag;
  late final TextEditingController _trikot;
  late final TextEditingController _adresse;
  late final TextEditingController _treff;
  late final TextEditingController _intro;

  @override
  void initState() {
    super.initState();
    final i = widget.initial;
    _spieltag = TextEditingController(text: i['spieltag'] ?? '');
    _trikot = TextEditingController(text: i['trikot'] ?? '');
    _adresse = TextEditingController(text: i['adresse'] ?? '');
    _treff = TextEditingController(text: i['treffpunkte'] ?? '');
    _intro = TextEditingController(text: i['intro'] ?? '');
  }

  @override
  void dispose() {
    _spieltag.dispose();
    _trikot.dispose();
    _adresse.dispose();
    _treff.dispose();
    _intro.dispose();
    super.dispose();
  }

  void _share() {
    Navigator.pop(context, {
      'spieltag': _spieltag.text.trim(),
      'trikot': _trikot.text.trim(),
      'adresse': _adresse.text.trim(),
      'treffpunkte': _treff.text.trim(),
      'intro': _intro.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Spieltags-Info'),
        actions: [TextButton(onPressed: _share, child: const Text('Teilen'))],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          TextField(
            controller: _intro,
            minLines: 3,
            maxLines: 10,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Einleitung / Motivationstext (optional)',
              hintText: 'Nabend zusammen, am Sonntag geht\'s …',
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _spieltag,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Spieltag (Nr.)',
              hintText: 'z.B. 11',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _trikot,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Trikot-Farbe',
              hintText: 'z.B. Schwarz',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _adresse,
            minLines: 1,
            maxLines: 3,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Adresse / Spielstätte',
              hintText: 'Sportplatz Post SV, 40625 Düsseldorf',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _treff,
            minLines: 3,
            maxLines: 8,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Treffpunkte & Zeiten',
              hintText:
                  'Treffpunkt GSV Parkplatz 13:15\nAbfahrt 13:25\n'
                  'Treffpunkt Post 13:50',
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Anstoßzeit und das Aufgebot (zugesagte Spieler + „Unter '
            'Vorbehalt") werden automatisch ergänzt.',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _share,
            icon: const Icon(Icons.share),
            label: const Text('Per WhatsApp teilen'),
          ),
        ],
      ),
    );
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
              Text(
                '${match.ownScore} : ${match.opponentScore}',
                style: TextStyle(
                  color: scheme.onPrimary,
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                ),
              ),
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
        Text(
          name,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: scheme.onPrimary,
            fontWeight: FontWeight.bold,
          ),
        ),
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
            child: Text(
              result.message,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
