import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/player.dart';
import '../models/player_of_month.dart';
import '../state/app_state.dart';
import '../widgets/player_avatar.dart';
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
    super.dispose();
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
    await _loadMonth();
  }

  Future<void> _loadMonth() async {
    final teamId = _teamId, month = _month;
    if (teamId == null || month == null) return;
    final ranking = await _app.monthRanking(teamId, month);
    final honored = await _app.honoredOf(month);
    final history = await _app.honorHistory();
    if (!mounted) return;
    setState(() {
      _ranking = ranking;
      _honored = honored;
      _history = history;
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
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(
                'Spieler des Monats küren',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
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
    await _app.honorPlayerOfMonth(_month!, picked);
    await _loadMonth();
  }

  /// Öffnet die teilbare Grafik/Urkunde für den gekürten Spieler des Monats.
  void _openExport() {
    final honored = _honored, month = _month;
    if (honored == null || month == null) return;
    final player = _byId[honored.playerId];
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
      appBar: AppBar(title: const Text('Spieler des Monats')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _teamId == null
          ? const Center(child: Text('Keine Mannschaft.'))
          : ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
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

  Widget _honorCard() {
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
    final isHonored = _honored?.playerId == p.id;
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
        subtitle: avg == null ? const Text('keine Bewertung') : null,
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
