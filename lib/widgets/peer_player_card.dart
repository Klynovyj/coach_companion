import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/peer_rating.dart';
import '../models/player.dart';
import '../screens/peer_links_screen.dart';
import '../services/peer_rating_service.dart';
import '../state/app_state.dart';
import 'star_rating.dart';

/// Karte im Spieler-Detail (nur Trainer): persönlicher Bewertungs-Link und
/// Verlauf der Selbsteinschätzung aus der Web-Bewertung.
class PeerPlayerCard extends StatefulWidget {
  const PeerPlayerCard({super.key, required this.player});

  final Player player;

  @override
  State<PeerPlayerCard> createState() => _PeerPlayerCardState();
}

class _PeerPlayerCardState extends State<PeerPlayerCard> {
  final _df = DateFormat('dd.MM.yy', 'de_DE');
  String? _token;
  bool _linksOk = false;
  List<PeerSelfEntry>? _self;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final teamId = context.read<AppState>().activeCloudTeamId;
    if (teamId == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final links = await PeerRatingService.links(teamId);
    final self = await PeerRatingService.selfRatings(widget.player.id);
    if (!mounted) return;
    setState(() {
      _linksOk = links != null;
      _token = links?[widget.player.id];
      _self = self;
      _loading = false;
    });
  }

  Future<void> _act(String a) async {
    final teamId = context.read<AppState>().activeCloudTeamId;
    if (teamId == null) return;
    final t = await peerLinkAction(context, widget.player, teamId, _token, a);
    if (t != null && mounted) setState(() => _token = t);
  }

  @override
  Widget build(BuildContext context) {
    final cloud = context.watch<AppState>().activeCloudTeamId != null;
    if (!cloud) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final self = _self ?? const <PeerSelfEntry>[];
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.how_to_vote_outlined, color: scheme.primary),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Spieler-Bewertung per Link',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (!_linksOk)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  'Nicht verfügbar (offline oder Cloud-Stufe 59 fehlt).',
                  style: TextStyle(color: Colors.grey),
                ),
              )
            else ...[
              const SizedBox(height: 4),
              Text(
                _token == null
                    ? 'Noch kein persönlicher Link.'
                    : 'Persönlicher Link vorhanden – gilt dauerhaft.',
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: () => _act('share'),
                    icon: const Icon(Icons.share, size: 18),
                    label: Text(
                      _token == null ? 'Link anlegen & teilen' : 'Link teilen',
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _act('copy'),
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('Kopieren'),
                  ),
                  if (_token != null)
                    TextButton.icon(
                      onPressed: () => _act('renew'),
                      icon: const Icon(Icons.autorenew, size: 18),
                      label: const Text('Neu erzeugen'),
                    ),
                ],
              ),
              const Divider(height: 22),
              const Text(
                'Selbsteinschätzung',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              if (self.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text(
                    'Noch keine Selbsteinschätzung abgegeben.',
                    style: TextStyle(color: Colors.grey),
                  ),
                )
              else
                for (final e in self) _selfRow(context, e),
            ],
          ],
        ),
      ),
    );
  }

  Widget _selfRow(BuildContext context, PeerSelfEntry e) {
    final stars = e.stars ?? 0;
    final note = (e.note ?? '').trim();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  [
                    if (e.matchDate != null) _df.format(e.matchDate!.toLocal()),
                    e.title,
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              StarDisplay(value: stars, size: 16),
            ],
          ),
          if (note.isNotEmpty) Text(note),
        ],
      ),
    );
  }
}
