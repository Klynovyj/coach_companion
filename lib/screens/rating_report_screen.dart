import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/enums.dart';
import '../models/match.dart';
import '../models/match_rating.dart';
import '../services/cloud_service.dart';
import '../services/share_service.dart';
import '../state/app_state.dart';

/// Bericht „auf einen Blick": alle Trainer-Noten und Spielberichte (Kommentare)
/// über alle Spiele hinweg, gruppiert je Spiel (neueste zuerst). Rein lesend,
/// als Text teilbar. Optional nur Spiele mit Kommentar anzeigen.
class RatingReportScreen extends StatefulWidget {
  const RatingReportScreen({super.key});

  @override
  State<RatingReportScreen> createState() => _RatingReportScreenState();
}

/// Ein Spiel mit seinen Noten/Berichten für den Bericht.
class _Entry {
  final GameMatch match;
  final double? avg;
  final int rated;
  final List<MatchRating> ratings; // mit Note und/oder Kommentar
  const _Entry(this.match, this.avg, this.rated, this.ratings);

  bool get hasComment => ratings.any((r) => (r.note ?? '').trim().isNotEmpty);
}

class _RatingReportScreenState extends State<RatingReportScreen> {
  final _df = DateFormat('dd.MM.yyyy', 'de_DE');
  List<_Entry> _entries = [];
  Map<String, String> _names = {};
  bool _loading = true;
  bool _onlyComments = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final s = context.read<AppState>();
    final ownId = s.ownTeam?.id;
    _names = ownId == null ? {} : await s.teamMemberNames(ownId);
    // Gespielte Spiele, neueste zuerst.
    final matches =
        s.matches.where((m) => m.status == MatchStatus.finished).toList()..sort(
          (a, b) =>
              (b.kickoff ?? b.createdAt).compareTo(a.kickoff ?? a.createdAt),
        );
    final entries = <_Entry>[];
    for (final m in matches) {
      final ratings = await s.matchRatingsOf(m.id);
      final relevant =
          ratings
              .where(
                (r) => r.rating != null || (r.note ?? '').trim().isNotEmpty,
              )
              .toList()
            ..sort((a, b) {
              final ra = a.rating ?? -1, rb = b.rating ?? -1;
              if (ra != rb) return rb.compareTo(ra);
              return _trainerName(a.userId).compareTo(_trainerName(b.userId));
            });
      if (relevant.isEmpty) continue;
      final (avg, rated, _) = await s.matchRatingSummary(m.id);
      entries.add(_Entry(m, avg, rated, relevant));
    }
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _loading = false;
    });
  }

  String _trainerName(String? uid) {
    final me = CloudService.userId;
    if (uid == null || uid == 'local' || uid == me) return 'Du';
    final n = _names[uid];
    return (n != null && n.isNotEmpty) ? n : 'Trainer';
  }

  List<_Entry> get _visible =>
      _onlyComments ? _entries.where((e) => e.hasComment).toList() : _entries;

  String _stars(double? r) =>
      r == null ? '–' : r.toStringAsFixed(1).replaceAll('.', ',');

  Future<void> _share() async {
    final b = StringBuffer();
    b.writeln('*Auswertung – Noten & Berichte*');
    for (final e in _visible) {
      final m = e.match;
      b.writeln('');
      b.writeln(
        '*${m.venue == Venue.home ? 'H' : 'A'} · ${m.opponentName} '
        '${m.ownScore}:${m.opponentScore}* '
        '(${m.kickoff != null ? _df.format(m.kickoff!.toLocal()) : '—'})'
        '${e.avg != null ? ' · Ø ${_stars(e.avg)}' : ''}',
      );
      for (final r in e.ratings) {
        final note = (r.note ?? '').trim();
        final star = r.rating != null ? ' ⭐ ${_stars(r.rating)}' : '';
        b.writeln('• ${_trainerName(r.userId)}$star');
        if (note.isNotEmpty) b.writeln('  „$note"');
      }
    }
    final ok = await shareText(b.toString().trim());
    if (!ok && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Teilen nicht möglich.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _visible;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Berichte & Noten'),
        actions: [
          IconButton(
            tooltip: 'Als Text teilen',
            icon: const Icon(Icons.ios_share),
            onPressed: _loading || list.isEmpty ? null : _share,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Row(
                    children: [
                      FilterChip(
                        label: const Text('Nur mit Kommentar'),
                        selected: _onlyComments,
                        onSelected: (v) => setState(() => _onlyComments = v),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: list.isEmpty
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(24),
                            child: Text(
                              'Keine Noten oder Kommentare.',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                          itemCount: list.length,
                          itemBuilder: (context, i) => _matchCard(list[i]),
                        ),
                ),
              ],
            ),
    );
  }

  Widget _matchCard(_Entry e) {
    final m = e.match;
    final scheme = Theme.of(context).colorScheme;
    final win = m.ownScore > m.opponentScore;
    final loss = m.ownScore < m.opponentScore;
    final resultColor = win
        ? Colors.green.shade700
        : loss
        ? Colors.red.shade700
        : Colors.orange.shade800;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: resultColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '${m.ownScore}:${m.opponentScore}',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: resultColor,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${m.venue == Venue.home ? 'H' : 'A'} · ${m.opponentName}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                if (e.avg != null) ...[
                  Icon(Icons.star, size: 16, color: Colors.amber.shade700),
                  const SizedBox(width: 2),
                  Text(
                    '${_stars(e.avg)} (${e.rated})',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ],
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 6),
              child: Text(
                m.kickoff != null ? _df.format(m.kickoff!.toLocal()) : '—',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            for (final r in e.ratings) _ratingRow(r, scheme),
          ],
        ),
      ),
    );
  }

  Widget _ratingRow(MatchRating r, ColorScheme scheme) {
    final note = (r.note ?? '').trim();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _trainerName(r.userId),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              if (r.rating != null) ...[
                Icon(Icons.star, size: 14, color: Colors.amber.shade700),
                const SizedBox(width: 2),
                Text(
                  _stars(r.rating),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ],
            ],
          ),
          if (note.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 1, left: 2),
              child: Text(
                '„$note"',
                style: TextStyle(
                  fontStyle: FontStyle.italic,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
