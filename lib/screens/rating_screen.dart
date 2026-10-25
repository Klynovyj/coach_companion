import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/match.dart';
import '../models/match_rating.dart';
import '../models/player.dart';
import '../models/player_rating.dart';
import '../state/app_state.dart';
import '../widgets/player_avatar.dart';

/// Bewertungs-Screen nach dem Spiel: 1–5 Sterne je Spieler **pro Benutzer** +
/// eine Spiel-Gesamtnote. Jeder bewertet eigenständig; angezeigt wird der
/// Schnitt aller Benutzer. „War nicht da / bewerte nicht" blendet die eigenen
/// Bewertungen aus. Bewerten ist bis 3 Tage nach Spielende möglich.
class RatingScreen extends StatefulWidget {
  const RatingScreen({super.key, required this.matchId});
  final String matchId;

  @override
  State<RatingScreen> createState() => _RatingScreenState();
}

class _RatingScreenState extends State<RatingScreen> {
  GameMatch? _match;
  List<Player> _roster = [];
  Map<String, PlayerRating> _mine = {}; // eigene Spielerbewertungen
  Map<String, (double, int)> _avg = {}; // Schnitt+Anzahl je Spieler
  MatchRating? _myMatch; // eigene Spiel-Gesamtnote/Abwesenheit
  (double?, int, int) _summary = (null, 0, 0);
  DateTime? _deadline;
  bool _open = true;
  bool _loading = true;

  late final AppState _app = context.read<AppState>();

  @override
  void initState() {
    super.initState();
    _app.addListener(_onAppChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  void _onAppChanged() {
    if (mounted) _load();
  }

  @override
  void dispose() {
    _app.removeListener(_onAppChanged);
    super.dispose();
  }

  bool get _abstained => _myMatch?.abstained ?? false;
  bool get _canEdit => _open && !_abstained;

  Future<void> _load() async {
    final state = context.read<AppState>();
    final match = await state.getMatch(widget.matchId);
    if (match == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final players = await state.playersOf(match.ownTeamId);
    final byId = {for (final p in players) p.id: p};
    final playedIds =
        await state.playedPlayerIds(widget.matchId, match.ownTeamId);
    final roster = <Player>[
      for (final id in playedIds)
        if (byId[id] != null) byId[id]!,
    ]..sort((a, b) {
        final an = a.number ?? 9999, bn = b.number ?? 9999;
        return an != bn ? an.compareTo(bn) : a.lastName.compareTo(b.lastName);
      });
    final mine = await state.ratingsMapOf(widget.matchId);
    final avg = await state.ratingAverages(widget.matchId);
    final myMatch = await state.myMatchRating(widget.matchId);
    final summary = await state.matchRatingSummary(widget.matchId);
    final deadline = await state.ratingDeadline(widget.matchId);
    if (!mounted) return;
    setState(() {
      _match = match;
      _roster = roster;
      _mine = mine;
      _avg = avg;
      _myMatch = myMatch;
      _summary = summary;
      _deadline = deadline;
      _open = deadline == null || DateTime.now().isBefore(deadline);
      _loading = false;
    });
  }

  Future<void> _setStars(Player p, int stars) async {
    if (!_canEdit) return;
    await context.read<AppState>().setRating(
        matchId: widget.matchId, playerId: p.id, rating: stars.toDouble());
    await _load();
  }

  Future<void> _clear(Player p) async {
    await context.read<AppState>().removeRating(widget.matchId, p.id);
    await _load();
  }

  Future<void> _setMatchStars(int stars) async {
    if (!_canEdit) return;
    await context.read<AppState>().setMatchRating(widget.matchId, stars.toDouble());
    await _load();
  }

  Future<void> _toggleAbstain(bool v) async {
    if (!_open) return;
    await context.read<AppState>().setAbstain(widget.matchId, v);
    await _load();
  }

  Future<void> _editNote(Player p) async {
    if (!_canEdit) return;
    final current = _mine[p.id];
    final ctrl = TextEditingController(text: current?.note ?? '');
    final note = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Notiz zu ${p.fullName}'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(hintText: 'Kurze Bewertung …'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () => Navigator.pop(context, ctrl.text.trim()),
              child: const Text('Speichern')),
        ],
      ),
    );
    if (note == null || !mounted) return;
    final stars = current?.rating ?? 3.0;
    await context.read<AppState>().setRating(
          matchId: widget.matchId,
          playerId: p.id,
          rating: stars,
          note: note.isEmpty ? null : note,
          keepNote: false,
        );
    await _load();
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
    return Scaffold(
      appBar: AppBar(title: Text('Bewertung • vs ${match.opponentName}')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          _fristBanner(context),
          _fupaVoteCard(context, match),
          _matchNoteCard(context),
          SwitchListTile(
            secondary: const Icon(Icons.event_busy),
            title: const Text('War nicht da / bewerte nicht'),
            subtitle: const Text('Deine Bewertungen zählen dann nicht mit.'),
            value: _abstained,
            onChanged: _open ? _toggleAbstain : null,
          ),
          const Divider(height: 1),
          if (_roster.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Keine Spieler zum Bewerten.\nErst nominieren bzw. aufstellen.',
                textAlign: TextAlign.center,
              ),
            )
          else
            for (final p in _roster) _playerRow(context, p),
        ],
      ),
    );
  }

  Widget _fristBanner(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (!_open) {
      return Container(
        width: double.infinity,
        color: scheme.errorContainer,
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          const Icon(Icons.lock_clock, size: 18),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
                'Bewerten ist nur bis 3 Tage nach Spielende möglich – '
                'die Frist ist abgelaufen.'),
          ),
        ]),
      );
    }
    if (_deadline == null) return const SizedBox.shrink();
    final df = DateFormat('EEE, dd.MM. HH:mm', 'de_DE');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Text('Bewerten möglich bis ${df.format(_deadline!.toLocal())}',
          style: Theme.of(context).textTheme.bodySmall),
    );
  }

  /// „Bester Spieler" bei FuPa: öffnet die FuPa-Spielseite (Elf-der-Woche-
  /// Abstimmung). Nur sichtbar, wenn zum Spiel ein FuPa-Slug bekannt ist.
  Widget _fupaVoteCard(BuildContext context, GameMatch match) {
    final slug = match.fupaMatchSlug?.trim();
    if (slug == null || slug.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final url = 'https://www.fupa.net/match/$slug/lineup';
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      color: scheme.primaryContainer,
      child: ListTile(
        leading: Icon(Icons.how_to_vote, color: scheme.onPrimaryContainer),
        title: Text('Bester Spieler bei FuPa',
            style: TextStyle(
                fontWeight: FontWeight.w700,
                color: scheme.onPrimaryContainer)),
        subtitle: Text('Für die Elf der Woche abstimmen',
            style: TextStyle(
                color: scheme.onPrimaryContainer.withValues(alpha: 0.8))),
        trailing: FilledButton(
          onPressed: () => _openFupa(url),
          child: const Text('Abstimmen'),
        ),
        onTap: () => _openFupa(url),
      ),
    );
  }

  Future<void> _openFupa(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  Widget _matchNoteCard(BuildContext context) {
    final my = _myMatch?.rating?.round() ?? 0;
    final (avg, rated, abs) = _summary;
    final sub = StringBuffer();
    if (avg != null) sub.write('Schnitt ${avg.toStringAsFixed(1)} ($rated)');
    if (abs > 0) sub.write('${sub.isEmpty ? '' : ' · '}$abs abwesend');
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.scoreboard,
                  color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 8),
              const Text('Spiel-Gesamtnote',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ]),
            _StarRow(
                value: my,
                enabled: _canEdit,
                onTap: (s) => _setMatchStars(s)),
            if (sub.isNotEmpty)
              Text(sub.toString(),
                  style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  Widget _playerRow(BuildContext context, Player p) {
    final r = _mine[p.id];
    final myStars = r?.rating.round() ?? 0;
    final a = _avg[p.id];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          PlayerAvatar(player: p),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(p.fullName,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                    if (a != null) ...[
                      Icon(Icons.star,
                          size: 15, color: Colors.amber.shade700),
                      const SizedBox(width: 2),
                      Text('${a.$1.toStringAsFixed(1)} (${a.$2})',
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ],
                ),
                _StarRow(
                  value: myStars,
                  enabled: _canEdit,
                  onTap: (s) => _setStars(p, s),
                ),
                if (r?.note != null && r!.note!.isNotEmpty)
                  Text(r.note!,
                      style: Theme.of(context).textTheme.bodySmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Notiz',
            icon: Icon(
              Icons.sticky_note_2_outlined,
              size: 20,
              color: (r?.note != null && r!.note!.isNotEmpty)
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
            onPressed: _canEdit ? () => _editNote(p) : null,
          ),
          if (myStars > 0 && _canEdit)
            IconButton(
              tooltip: 'Meine Bewertung entfernen',
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => _clear(p),
            ),
        ],
      ),
    );
  }
}

/// Reihe aus 5 antippbaren Sternen.
class _StarRow extends StatelessWidget {
  const _StarRow(
      {required this.value, required this.onTap, this.enabled = true});
  final int value;
  final ValueChanged<int> onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 1; i <= 5; i++)
          IconButton(
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
            icon: Icon(
              i <= value ? Icons.star : Icons.star_border,
              color: enabled ? Colors.amber.shade700 : Colors.grey,
              size: 26,
            ),
            onPressed: enabled ? () => onTap(i) : null,
          ),
      ],
    );
  }
}
