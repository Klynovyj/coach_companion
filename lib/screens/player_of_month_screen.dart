import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import 'package:supabase_flutter/supabase_flutter.dart' show RealtimeChannel;

import '../models/peer_rating.dart';
import '../models/player.dart';
import '../models/player_of_month.dart';
import '../services/peer_rating_service.dart';
import '../state/app_state.dart';
import '../widgets/player_avatar.dart';
import 'club_stats_screen.dart';
import 'player_of_month_graphic_screen.dart';

/// Spieler des Monats: pro Kalendermonat eine Rangliste der Spieler nach
/// Bewertungs-Schnitt; der Trainer kürt (final) einen Spieler, mit Historie.
class PlayerOfMonthScreen extends StatefulWidget {
  const PlayerOfMonthScreen({super.key});

  @override
  State<PlayerOfMonthScreen> createState() => _PlayerOfMonthScreenState();
}

class _PlayerOfMonthScreenState extends State<PlayerOfMonthScreen> {
  static const _gold = Color(0xFFC9A24B);

  String? _teamId;
  List<String> _months = [];
  String? _month;
  List<(Player, double?, int)> _ranking = [];
  Map<String, Player> _byId = {};
  PlayerOfMonth? _honored;
  List<PlayerOfMonth> _history = [];
  bool _loading = true;

  /// Kürung im Cloud-Team: alle Trainer müssen zustimmen (Stufe 68).
  CrownState? _crown;
  RealtimeChannel? _crownCh;
  bool _voting = false;

  late final AppState _app = context.read<AppState>();

  @override
  void initState() {
    super.initState();
    _app.addListener(_onChanged);
    _init();
  }

  void _onChanged() {
    if (mounted && _month != null) _loadMonth();
  }

  @override
  void dispose() {
    _app.removeListener(_onChanged);
    PeerRatingService.unsubscribe(_crownCh);
    super.dispose();
  }

  Future<void> _loadCrown() async {
    final teamId = _teamId, month = _month;
    if (teamId == null || month == null || !_app.crownByConsensus) return;
    final c = await PeerRatingService.crownState(teamId, month);
    if (mounted && c != null && c.yearMonth == _month) {
      setState(() => _crown = c);
    }
  }

  /// Eigene Zustimmung setzen/ändern ([playerId] null = zurücknehmen).
  Future<void> _vote(String? playerId) async {
    final teamId = _teamId, month = _month;
    if (teamId == null || month == null) return;
    setState(() => _voting = true);
    final c = await PeerRatingService.crownVote(teamId, month, playerId);
    if (!mounted) return;
    setState(() {
      _voting = false;
      if (c != null) _crown = c;
    });
    if (c == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Zum Zustimmen bitte online sein.')),
      );
    }
  }

  Future<void> _init() async {
    final team = _app.ownTeam;
    if (team == null) {
      setState(() => _loading = false);
      return;
    }
    final players = await _app.playersOf(team.id);
    final months = await _app.ratedMonths(team.id);
    final nowM = DateFormat('yyyy-MM').format(DateTime.now());
    final list = months.isEmpty ? [nowM] : months;
    if (!mounted) return;
    setState(() {
      _teamId = team.id;
      _byId = {for (final p in players) p.id: p};
      _months = list;
      _month = list.first;
    });
    if (_app.crownByConsensus) {
      // Zustimmungen anderer Trainer sofort sehen (Realtime).
      _crownCh = PeerRatingService.subscribeCrown(team.id, _loadCrown);
    }
    await _loadMonth();
  }

  Future<void> _loadMonth() async {
    final teamId = _teamId, month = _month;
    if (teamId == null || month == null) return;
    final ranking = await _app.monthRanking(teamId, month);
    final honored = await _app.honoredOf(month);
    final history = await _app.honorHistory();
    final crown = _app.crownByConsensus
        ? await PeerRatingService.crownState(teamId, month)
        : null;
    if (!mounted) return;
    setState(() {
      _ranking = ranking;
      _honored = honored;
      _history = history;
      _crown = crown;
      _loading = false;
    });
  }

  String _monthLabel(String ym) {
    final y = int.tryParse(ym.substring(0, 4)) ?? 2000;
    final m = int.tryParse(ym.substring(5, 7)) ?? 1;
    return DateFormat('MMMM yyyy', 'de_DE').format(DateTime(y, m));
  }

  String _name(String playerId) => _byId[playerId]?.fullName ?? 'Spieler';

  Future<void> _honor() async {
    final rated = _ranking.where((e) => e.$2 != null).toList();
    final suggestion = rated.isNotEmpty ? rated.first.$1.id : null;
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(
                _crown != null
                    ? 'Zustimmen: Spieler des Monats'
                    : 'Spieler des Monats küren',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
            const Divider(height: 1),
            for (final e in _ranking.where((e) => e.$2 != null))
              ListTile(
                leading: PlayerAvatar(player: e.$1, radius: 16),
                title: Text(e.$1.fullName),
                subtitle: Text('Ø ${e.$2!.toStringAsFixed(1)} (${e.$3})'),
                trailing: e.$1.id == suggestion
                    ? const Chip(label: Text('Vorschlag'))
                    : null,
                onTap: () => Navigator.pop(ctx, e.$1.id),
              ),
          ],
        ),
      ),
    );
    if (picked == null || _month == null) return;
    if (_crown != null) {
      await _vote(picked);
      return;
    }
    await _app.honorPlayerOfMonth(_month!, picked);
    await _loadMonth();
  }

  /// Öffnet die teilbare Grafik/Urkunde für den gekürten Spieler des Monats.
  void _openExport() {
    final honoredId = _crown?.crowned ?? _honored?.playerId;
    final month = _month;
    if (honoredId == null || month == null) return;
    final player = _byId[honoredId];
    if (player == null) return;
    // Ø-Note + Anzahl aus der Monats-Rangliste (null, falls unbewertet).
    double? avg;
    var count = 0;
    for (final e in _ranking) {
      if (e.$1.id == player.id) {
        avg = e.$2;
        count = e.$3;
        break;
      }
    }
    final team = _app.ownTeam;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerOfMonthGraphicScreen(
          player: player,
          yearMonth: month,
          avg: avg,
          ratedCount: count,
          teamName: team?.name ?? team?.shortName ?? 'Mannschaft',
          teamLogo: team?.logoPath,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ehrungen')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _teamId == null
          ? const Center(child: Text('Keine Mannschaft.'))
          : ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                _createHonorCard(),
                _clubStatsTile(),
                _sectionHeader('Spieler des Monats'),
                _monthSelector(),
                _honorCard(),
                const Divider(height: 1),
                if (_ranking.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Noch keine Spieler/Bewertungen.',
                      textAlign: TextAlign.center,
                    ),
                  )
                else
                  for (var i = 0; i < _ranking.length; i++)
                    _rankRow(i, _ranking[i]),
                if (_history.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Text(
                      'Hall of Fame',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                  ),
                  for (final h in _history)
                    ListTile(
                      dense: true,
                      leading: const Text('🏆', style: TextStyle(fontSize: 20)),
                      title: Text(_name(h.playerId)),
                      trailing: Text(_monthLabel(h.yearMonth)),
                    ),
                ],
              ],
            ),
    );
  }

  /// Einstieg zur Vereins-Bilanz (FuPa) aller Spieler.
  Widget _clubStatsTile() => Card(
    margin: const EdgeInsets.fromLTRB(12, 0, 12, 4),
    child: ListTile(
      leading: const Icon(Icons.leaderboard, color: _gold),
      title: const Text(
        'Vereins-Bilanz (FuPa)',
        style: TextStyle(fontWeight: FontWeight.bold),
      ),
      subtitle: const Text(
        'Alle Spieler: Spiele/Tore/Vorlagen für den Verein (gesamt / nur Pflicht)',
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const ClubStatsScreen()),
      ),
    ),
  );

  Widget _sectionHeader(String title) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 2),
    child: Text(
      title,
      style: const TextStyle(
        fontWeight: FontWeight.bold,
        fontSize: 15,
        color: _gold,
      ),
    ),
  );

  /// Oben: beliebige Ehrung für einen frei gewählten Spieler erstellen.
  Widget _createHonorCard() {
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            const Icon(Icons.workspace_premium, size: 30, color: _gold),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Ehrung erstellen',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'Spieler wählen und eine Urkunde/Grafik für einen '
                    'beliebigen Anlass erzeugen (z.B. Jubiläum, 100. Spiel).',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: _createHonor,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Erstellen'),
            ),
          ],
        ),
      ),
    );
  }

  /// Spieler auswählen und die Grafik/Urkunde im Anlass-Modus öffnen.
  Future<void> _createHonor() async {
    final players = _byId.values.where((p) => !p.isStaffOnly).toList()
      ..sort(
        (a, b) => a.fullName.toLowerCase().compareTo(b.fullName.toLowerCase()),
      );
    final picked = await showModalBottomSheet<Player>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          maxChildSize: 0.95,
          minChildSize: 0.4,
          builder: (ctx, scroll) => ListView(
            controller: scroll,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Text(
                  'Spieler für die Ehrung wählen',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ),
              const Divider(height: 1),
              for (final p in players)
                ListTile(
                  leading: PlayerAvatar(player: p, radius: 16),
                  title: Text(p.fullName),
                  subtitle: (p.position ?? '').isEmpty
                      ? null
                      : Text(p.position!),
                  onTap: () => Navigator.pop(ctx, p),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    final team = _app.ownTeam;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerOfMonthGraphicScreen(
          player: picked,
          teamName: team?.name ?? team?.shortName ?? 'Mannschaft',
          teamLogo: team?.logoPath,
          defaultOccasion: 'Ehrung',
        ),
      ),
    );
  }

  Widget _monthSelector() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          const Icon(Icons.calendar_month),
          const SizedBox(width: 10),
          Expanded(
            child: DropdownButton<String>(
              isExpanded: true,
              value: _month,
              items: [
                for (final m in _months)
                  DropdownMenuItem(value: m, child: Text(_monthLabel(m))),
              ],
              onChanged: (v) {
                if (v == null) return;
                setState(() => _month = v);
                _loadMonth();
              },
            ),
          ),
        ],
      ),
    );
  }

  /// Kürung mit Zustimmung aller Trainer: fest gekürt oder voraussichtlich
  /// (Platz 1 der Rangliste), wer schon bestätigt hat, Zustimmen/Zurücknehmen.
  Widget _crownCard(CrownState c) {
    final small = Theme.of(context).textTheme.bodySmall;
    final crowned = c.crowned;
    final leaders = c.leaders.where(_byId.containsKey).toList();
    final mine = c.myVote;
    final n = c.required.length;
    final best = c.counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      color: _gold.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('🏆', style: TextStyle(fontSize: 28)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        crowned != null
                            ? 'Spieler des Monats'
                            : 'Voraussichtlich Spieler des Monats',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      Text(
                        crowned != null
                            ? _name(crowned)
                            : (leaders.isEmpty
                                  ? 'Noch keine Trainer-Noten'
                                  : leaders.map(_name).join(' · ')),
                        style: const TextStyle(fontSize: 16),
                      ),
                      Text(
                        crowned != null
                            ? 'Von allen $n Trainern bestätigt'
                            : 'Gekürt wird erst, wenn alle $n Trainer '
                                  'denselben Spieler bestätigen.',
                        style: small,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (best.isNotEmpty && n > 0) ...[
              const SizedBox(height: 10),
              Text(
                'Zustimmung für ${_name(best.first.key)}: '
                '${best.first.value}/$n Trainer',
                style: small,
              ),
              const SizedBox(height: 4),
              LinearProgressIndicator(
                value: best.first.value / n,
                color: _gold,
                backgroundColor: _gold.withValues(alpha: 0.2),
                minHeight: 6,
                borderRadius: BorderRadius.circular(3),
              ),
            ],
            const SizedBox(height: 8),
            for (final r in c.required)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Icon(
                      r.$3 != null
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      size: 18,
                      color: r.$3 != null ? Colors.green : Colors.grey,
                    ),
                    const SizedBox(width: 6),
                    Expanded(child: Text(r.$1 == c.me ? '${r.$2} (du)' : r.$2)),
                    Text(
                      r.$3 != null ? _name(r.$3!) : 'noch offen',
                      style: small?.copyWith(
                        color: r.$3 != null ? null : Colors.grey,
                        fontWeight: r.$3 != null ? FontWeight.w600 : null,
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                FilledButton.icon(
                  onPressed: _voting || !_ranking.any((e) => e.$2 != null)
                      ? null
                      : _honor,
                  icon: const Icon(Icons.how_to_vote, size: 18),
                  label: Text(mine == null ? 'Zustimmen' : 'Stimme ändern'),
                ),
                if (mine != null)
                  OutlinedButton(
                    onPressed: _voting ? null : () => _vote(null),
                    child: const Text('Zurücknehmen'),
                  ),
                if (crowned != null && _byId.containsKey(crowned))
                  TextButton.icon(
                    onPressed: _openExport,
                    icon: const Icon(Icons.ios_share, size: 18),
                    label: const Text('Teilen / Urkunde'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _honorCard() {
    if (_crown != null) return _crownCard(_crown!);
    final honoredPlayer = _honored == null ? null : _byId[_honored!.playerId];
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      color: _gold.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Text('🏆', style: TextStyle(fontSize: 28)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Spieler des Monats',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text(
                    honoredPlayer != null
                        ? honoredPlayer.fullName
                        : (_honored != null
                              ? _name(_honored!.playerId)
                              : 'Noch nicht gekürt'),
                    style: const TextStyle(fontSize: 16),
                  ),
                ],
              ),
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                FilledButton.icon(
                  onPressed: _ranking.any((e) => e.$2 != null) ? _honor : null,
                  icon: const Icon(Icons.emoji_events, size: 18),
                  label: Text(_honored == null ? 'Küren' : 'Ändern'),
                ),
                if (_honored != null &&
                    _byId.containsKey(_honored!.playerId)) ...[
                  const SizedBox(height: 4),
                  TextButton.icon(
                    onPressed: _openExport,
                    icon: const Icon(Icons.ios_share, size: 18),
                    label: const Text('Teilen / Urkunde'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _rankRow(int index, (Player, double?, int) e) {
    final (p, avg, count) = e;
    final isHonored = (_crown?.crowned ?? _honored?.playerId) == p.id;
    final voters = [
      for (final r in _crown?.required ?? const <(String, String, String?)>[])
        if (r.$3 == p.id) r.$2,
    ];
    final rank = avg != null ? index + 1 : null;
    final top = rank == 1;
    return Container(
      color: isHonored ? _gold.withValues(alpha: 0.1) : null,
      child: ListTile(
        leading: SizedBox(
          width: 56,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 22,
                child: Text(
                  rank?.toString() ?? '–',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: top ? _gold : Theme.of(context).hintColor,
                  ),
                ),
              ),
              PlayerAvatar(player: p, radius: 15),
            ],
          ),
        ),
        title: Text(
          p.fullName,
          style: TextStyle(
            fontWeight: top ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        subtitle: avg == null
            ? const Text('keine Bewertung')
            : (voters.isEmpty
                  ? null
                  : Text(
                      '✓ ${voters.join(', ')}',
                      style: TextStyle(
                        color: _gold,
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                    )),
        trailing: avg == null
            ? (isHonored ? const Text('🏆') : null)
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isHonored) const Text('🏆  '),
                  Icon(Icons.star, size: 16, color: Colors.amber.shade700),
                  const SizedBox(width: 2),
                  Text(
                    '${avg.toStringAsFixed(1)} ($count)',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
      ),
    );
  }
}
