import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/enums.dart';
import '../models/match.dart';
import '../models/match_rating.dart';
import '../models/player.dart';
import '../services/cloud_service.dart';
import '../state/app_state.dart';
import '../widgets/player_avatar.dart';
import 'rating_screen.dart';

/// Auswertung eines Spiels: Gesamtnoten der Trainer (+ Schnitt), ihre
/// Spielberichte und der Spieler-Schnitt. Rein lesend.
class RatingSummaryScreen extends StatefulWidget {
  const RatingSummaryScreen({super.key, required this.matchId});

  final String matchId;

  @override
  State<RatingSummaryScreen> createState() => _RatingSummaryScreenState();
}

class _RatingSummaryScreenState extends State<RatingSummaryScreen> {
  final _dt = DateFormat('dd.MM.yyyy · HH:mm', 'de_DE');
  GameMatch? _match;
  List<MatchRating> _ratings = [];
  MatchRating? _myMatch; // eigene Note/Bericht (inline bearbeitbar)
  (double?, int, int) _summary = (null, 0, 0);
  Map<String, (double, int)> _avg = {};
  Map<String, Player> _byId = {};
  Map<String, String> _names = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final s = context.read<AppState>();
    final match = await s.getMatch(widget.matchId);
    if (match == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final ratings = await s.matchRatingsOf(widget.matchId);
    final myMatch = await s.myMatchRating(widget.matchId);
    final summary = await s.matchRatingSummary(widget.matchId);
    final avg = await s.ratingAverages(widget.matchId);
    final players = await s.playersOf(match.ownTeamId);
    final names = await s.teamMemberNames(match.ownTeamId);
    if (!mounted) return;
    setState(() {
      _match = match;
      _ratings = ratings;
      _myMatch = myMatch;
      _summary = summary;
      _avg = avg;
      _byId = {for (final p in players) p.id: p};
      _names = names;
      _loading = false;
    });
  }

  String _trainerName(String? uid) {
    final me = CloudService.userId;
    if (uid != null && uid == me) return 'Du';
    if (uid == null || uid == 'local') return 'Du';
    final n = _names[uid];
    return (n != null && n.isNotEmpty) ? n : 'Trainer';
  }

  Future<void> _setMyStars(int stars) async {
    await context.read<AppState>().setMatchRating(
      widget.matchId,
      stars == 0 ? null : stars.toDouble(),
    );
    await _load();
  }

  Future<void> _editMyNote() async {
    final ctrl = TextEditingController(text: _myMatch?.note ?? '');
    final res = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Mein Spielbericht'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          minLines: 4,
          maxLines: 10,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            hintText: 'Dein Kommentar/Bericht zum Spiel …',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
    if (res == null || !mounted) return;
    await context.read<AppState>().setMatchNote(widget.matchId, res);
    await _load();
  }

  /// Karte „Meine Bewertung": eigene Note (Sterne) + Bericht inline bearbeiten,
  /// plus Button zur vollen Bewertung (Spieler einzeln). Speichert geteilt.
  Widget _myRatingCard(BuildContext context) {
    final my = _myMatch?.rating?.round() ?? 0;
    final myNote = (_myMatch?.note ?? '').trim();
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.rate_review, color: scheme.primary),
                const SizedBox(width: 8),
                const Text(
                  'Meine Bewertung',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            Row(
              children: [
                for (var i = 1; i <= 5; i++)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 36,
                      minHeight: 36,
                    ),
                    icon: Icon(
                      i <= my ? Icons.star : Icons.star_border,
                      color: Colors.amber.shade700,
                      size: 28,
                    ),
                    onPressed: () => _setMyStars(i),
                  ),
                if (my > 0)
                  TextButton(
                    onPressed: () => _setMyStars(0),
                    child: const Text('Note weg'),
                  ),
              ],
            ),
            const Divider(height: 8),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Mein Spielbericht',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                TextButton(
                  onPressed: _editMyNote,
                  child: Text(myNote.isEmpty ? 'Schreiben' : 'Bearbeiten'),
                ),
              ],
            ),
            Text(
              myNote.isEmpty ? 'Noch kein Bericht.' : myNote,
              style: TextStyle(
                color: myNote.isEmpty ? Theme.of(context).hintColor : null,
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () =>
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => RatingScreen(matchId: widget.matchId),
                      ),
                    ).then((_) {
                      if (mounted) _load();
                    }),
                icon: const Icon(Icons.groups, size: 18),
                label: const Text('Spieler einzeln bewerten'),
              ),
            ),
          ],
        ),
      ),
    );
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
    final (avg, rated, abs) = _summary;
    // Trainer mit Note/Abwesenheit zuerst, dann nach Name.
    final ratings = [..._ratings]
      ..sort((a, b) {
        final ra = a.rating ?? -1, rb = b.rating ?? -1;
        if (ra != rb) return rb.compareTo(ra);
        return _trainerName(a.userId).compareTo(_trainerName(b.userId));
      });
    final reports = ratings
        .where((r) => (r.note ?? '').trim().isNotEmpty)
        .toList();
    // Spieler-Schnitt: nach Durchschnitt absteigend.
    final rated2 = _avg.entries.where((e) => _byId.containsKey(e.key)).toList()
      ..sort((a, b) => b.value.$1.compareTo(a.value.$1));

    return Scaffold(
      appBar: AppBar(
        title: Text('Spielbericht & Voting · vs ${match.opponentName}'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 28),
        children: [
          // Eigene Bewertung inline – nur bei beendeten Spielen (mit Ergebnis);
          // geteilt mit allen Trainern.
          if (match.status == MatchStatus.finished) _myRatingCard(context),
          // Gesamtnote-Schnitt
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(
                    Icons.scoreboard,
                    color: Theme.of(context).colorScheme.primary,
                    size: 28,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Spiel-Gesamtnote',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        Text(
                          avg == null
                              ? 'Noch keine Note'
                              : 'Schnitt ${avg.toStringAsFixed(1)} aus $rated Note(n)'
                                    '${abs > 0 ? ' · $abs abwesend' : ''}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  if (avg != null)
                    Text(
                      avg.toStringAsFixed(1),
                      style: const TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                ],
              ),
            ),
          ),
          // Trainer-Noten
          _sectionTitle(context, 'Noten der Trainer'),
          if (ratings.isEmpty)
            _hint('Noch keine Bewertungen abgegeben.')
          else
            for (final r in ratings) _trainerRatingRow(context, r),
          // Trainer-Berichte
          _sectionTitle(context, 'Spielberichte'),
          if (reports.isEmpty)
            _hint('Noch kein Bericht geschrieben.')
          else
            for (final r in reports) _reportCard(context, r),
          // Spieler-Schnitt
          _sectionTitle(context, 'Spieler-Schnitt'),
          if (rated2.isEmpty)
            _hint('Noch keine Spielerbewertungen.')
          else
            for (final e in rated2) _playerAvgRow(context, e.key, e.value),
        ],
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String t) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 18, 4, 6),
    child: Text(
      t,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.bold,
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );

  Widget _hint(String t) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 2, 4, 2),
    child: Text(t, style: const TextStyle(color: Colors.grey)),
  );

  Widget _trainerRatingRow(BuildContext context, MatchRating r) {
    final stars = r.rating?.round() ?? 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      child: Row(
        children: [
          const Icon(Icons.sports, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(_trainerName(r.userId))),
          if (r.abstained)
            const Text('abwesend', style: TextStyle(color: Colors.grey))
          else if (stars == 0)
            const Text('keine Note', style: TextStyle(color: Colors.grey))
          else
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 1; i <= 5; i++)
                  Icon(
                    i <= stars ? Icons.star : Icons.star_border,
                    size: 18,
                    color: Colors.amber.shade700,
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _reportCard(BuildContext context, MatchRating r) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.edit_note, size: 18),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _trainerName(r.userId),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                Text(
                  _dt.format(r.editedAt.toLocal()),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).hintColor,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text((r.note ?? '').trim()),
          ],
        ),
      ),
    );
  }

  Widget _playerAvgRow(
    BuildContext context,
    String playerId,
    (double, int) avg,
  ) {
    final p = _byId[playerId]!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      child: Row(
        children: [
          PlayerAvatar(player: p, radius: 16),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              p.fullName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Icon(Icons.star, size: 15, color: Colors.amber.shade700),
          const SizedBox(width: 3),
          Text(
            '${avg.$1.toStringAsFixed(1)} (${avg.$2})',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
