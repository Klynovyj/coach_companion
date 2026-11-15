import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/peer_rating.dart';
import '../models/player.dart';
import '../services/cloud_service.dart';
import '../services/peer_rating_service.dart';
import '../services/share_service.dart';
import '../state/app_state.dart';
import '../widgets/player_avatar.dart';

/// Nachricht mit dem persönlichen Bewertungs-Link eines Spielers.
String peerLinkMessage(Player p, String token) {
  final hi = p.firstName.trim().isNotEmpty
      ? 'Hallo ${p.firstName.trim()}!'
      : 'Hallo!';
  return '$hi Hier ist dein persönlicher Link für die Spielbewertung – '
      'nach jedem Spiel kannst du dort Mitspieler, deine Leistung und das '
      'Spiel bewerten und den Spieler des Spiels wählen. Bitte als Lesezeichen '
      'speichern und nicht weitergeben:\n${peerRatingLink(token)}';
}

/// Nachricht mit dem persönlichen Bewertungs-Link eines Trainers.
String coachLinkMessage(String name, String token) {
  final first = name.trim().split(' ').first;
  final hi = first.isNotEmpty ? 'Hallo $first!' : 'Hallo!';
  return '$hi Hier ist dein persönlicher Trainer-Link für die Spielbewertung – '
      'nach jedem Spiel gibst du dort Spielnote, Spielbericht und die Noten '
      'der Spieler ab (zählt in den Trainer-Schnitt) und siehst danach die '
      'ganze Auswertung. Bitte als Lesezeichen speichern und nicht '
      'weitergeben:\n${coachRatingLink(token)}';
}

/// Teilen/Kopieren/Neu erzeugen für einen persönlichen Link. Gibt den
/// (ggf. neuen) Token zurück; `null` bei Abbruch/Fehler.
Future<String?> ratingLinkAction(
  BuildContext context, {
  required String who,
  required String? token,
  required String action, // share | copy | renew
  required Future<String?> Function() create,
  required String Function(String token) url,
  required String Function(String token) message,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  var t = token;
  if (action == 'renew' && t != null) {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Neuen Link erzeugen?'),
        content: Text(
          'Der bisherige Link von $who funktioniert danach nicht mehr. '
          'Sinnvoll, wenn der Link weitergegeben wurde.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Neu erzeugen'),
          ),
        ],
      ),
    );
    if (ok != true) return null;
    t = null;
  }
  if (t == null) {
    t = await create();
    if (t == null) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Link konnte nicht angelegt werden (online? Cloud-Stufen 59/60 '
            'ausgeführt?).',
          ),
        ),
      );
      return null;
    }
  }
  if (action == 'copy') {
    await Clipboard.setData(ClipboardData(text: url(t)));
    messenger.showSnackBar(const SnackBar(content: Text('Link kopiert.')));
  } else if (action == 'share') {
    await shareText(message(t));
  } else {
    messenger.showSnackBar(
      const SnackBar(content: Text('Neuer Link erzeugt – bitte neu teilen.')),
    );
  }
  return t;
}

/// Link-Aktion für einen Spieler (Spieler-Seite).
Future<String?> peerLinkAction(
  BuildContext context,
  Player p,
  String teamId,
  String? token,
  String action,
) => ratingLinkAction(
  context,
  who: p.fullName,
  token: token,
  action: action,
  create: () => PeerRatingService.createLink(p.id, teamId),
  url: peerRatingLink,
  message: (t) => peerLinkMessage(p, t),
);

/// Ein Trainer in der Link-Liste: App-Konto oder Trainer/Betreuer im Kader.
class _Coach {
  const _Coach({
    required this.raterId,
    required this.name,
    required this.subtitle,
    this.player,
  });

  final String raterId;
  final String name;
  final String subtitle;
  final Player? player;
}

/// Alle persönlichen Bewertungs-Links des Teams (Trainer + Spieler): anlegen,
/// teilen, kopieren, neu erzeugen. Jeder bekommt seinen Link einmal – er gilt
/// dauerhaft.
class PeerLinksScreen extends StatefulWidget {
  const PeerLinksScreen({super.key});

  @override
  State<PeerLinksScreen> createState() => _PeerLinksScreenState();
}

class _PeerLinksScreenState extends State<PeerLinksScreen> {
  List<Player> _players = [];
  List<_Coach> _coaches = [];
  Map<String, String>? _links;
  Map<String, String>? _coachLinks;
  bool _loading = true;
  bool _busy = false;

  String? get _teamId => context.read<AppState>().activeCloudTeamId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final s = context.read<AppState>();
    final teamId = _teamId;
    if (teamId == null) {
      setState(() => _loading = false);
      return;
    }
    final all = await s.playersOf(teamId, onlyActive: true);
    int byNumber(Player a, Player b) {
      final an = a.number ?? 9999, bn = b.number ?? 9999;
      return an != bn ? an.compareTo(bn) : a.lastName.compareTo(b.lastName);
    }

    final players = all.where((p) => !p.isStaffOnly).toList()..sort(byNumber);
    final coaches = <_Coach>[];
    try {
      for (final m in await CloudService.teamMembers(teamId)) {
        final isTrainer = m['role'] == 'trainer' || m['is_admin'] == true;
        final uid = m['user_id']?.toString();
        if (!isTrainer || uid == null) continue;
        final dn = (m['display_name'] as String?)?.trim() ?? '';
        final mail = (m['email'] as String?)?.trim() ?? '';
        coaches.add(
          _Coach(
            raterId: uid,
            name: dn.isNotEmpty ? dn : (mail.isNotEmpty ? mail : 'Trainer'),
            subtitle: 'App-Konto${m['is_me'] == true ? ' (du)' : ''}',
          ),
        );
      }
    } catch (_) {}
    for (final p in all.where((p) => p.isStaff).toList()..sort(byNumber)) {
      coaches.add(
        _Coach(
          raterId: staffRaterId(p.id),
          name: p.fullName,
          subtitle: 'Kader · ${p.staffRole}',
          player: p,
        ),
      );
    }
    // Runden für beendete Spiele nachtragen, damit die Links sofort etwas
    // zum Bewerten zeigen.
    await s.publishRecentPeerRounds(force: true);
    final links = await PeerRatingService.links(teamId);
    final coachLinks = await PeerRatingService.coachLinks(teamId);
    if (!mounted) return;
    setState(() {
      _players = players;
      _coaches = coaches;
      _links = links;
      _coachLinks = coachLinks;
      _loading = false;
    });
  }

  Future<void> _createMissing() async {
    final teamId = _teamId;
    final links = _links;
    if (teamId == null || links == null) return;
    setState(() => _busy = true);
    var made = 0;
    for (final p in _players) {
      if (links.containsKey(p.id)) continue;
      final t = await PeerRatingService.createLink(p.id, teamId);
      if (t != null) {
        links[p.id] = t;
        made++;
      }
    }
    final cl = _coachLinks;
    if (cl != null) {
      for (final c in _coaches) {
        if (cl.containsKey(c.raterId)) continue;
        final t = await PeerRatingService.createCoachLink(
          c.raterId,
          teamId,
          c.name,
        );
        if (t != null) {
          cl[c.raterId] = t;
          made++;
        }
      }
    }
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$made Link(s) angelegt.')));
  }

  @override
  Widget build(BuildContext context) {
    final teamId = _teamId;
    final links = _links;
    final cl = _coachLinks;
    final missing = links == null
        ? 0
        : _players.where((p) => !links.containsKey(p.id)).length +
              (cl == null
                  ? 0
                  : _coaches.where((c) => !cl.containsKey(c.raterId)).length);
    return Scaffold(
      appBar: AppBar(title: const Text('Bewertungs-Links')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : teamId == null
          ? const _Info('Bewertungs-Links gibt es nur mit einem Cloud-Team.')
          : links == null
          ? const _Info(
              'Links konnten nicht geladen werden. Bist du online und ist die '
              'Cloud-Stufe 59 (stage59_peer_ratings.sql) ausgeführt?',
            )
          : ListView(
              padding: const EdgeInsets.only(bottom: 28),
              children: [
                Card(
                  margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'So funktioniert es',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Jeder bekommt einmal seinen persönlichen Link (z. B. '
                          'per WhatsApp). Er gilt dauerhaft und zeigt nach jedem '
                          'Spiel die offene Bewertung, bis 3 Tage nach '
                          'Spielende. Trainer bewerten wie in der App (zählt in '
                          'den Trainer-Schnitt) und sehen danach die ganze '
                          'Auswertung. Spieler bewerten nur bei Einsatz.',
                        ),
                        if (missing > 0) ...[
                          const SizedBox(height: 8),
                          FilledButton.icon(
                            onPressed: _busy ? null : _createMissing,
                            icon: const Icon(Icons.add_link),
                            label: Text('$missing fehlende Links anlegen'),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                _header(context, 'Trainer'),
                if (cl == null)
                  const ListTile(
                    title: Text(
                      'Trainer-Links brauchen die Cloud-Stufe 60 '
                      '(stage60_coach_links.sql).',
                    ),
                  )
                else if (_coaches.isEmpty)
                  const ListTile(title: Text('Keine Trainer gefunden.'))
                else
                  for (final c in _coaches) _coachRow(context, c, teamId, cl),
                _header(context, 'Spieler'),
                for (final p in _players) _row(context, p, teamId, links),
              ],
            ),
    );
  }

  Widget _header(BuildContext context, String t) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(
      t,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.bold,
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );

  Widget _actions({
    required String? token,
    required void Function(String action) onAction,
  }) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(
        tooltip: 'Link teilen',
        icon: const Icon(Icons.share),
        onPressed: () => onAction('share'),
      ),
      PopupMenuButton<String>(
        onSelected: onAction,
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'copy', child: Text('Link kopieren')),
          if (token != null)
            const PopupMenuItem(
              value: 'renew',
              child: Text('Neuen Link erzeugen'),
            ),
        ],
      ),
    ],
  );

  Widget _coachRow(
    BuildContext context,
    _Coach c,
    String teamId,
    Map<String, String> cl,
  ) {
    final token = cl[c.raterId];
    return ListTile(
      leading: c.player != null
          ? PlayerAvatar(player: c.player!, radius: 18)
          : const CircleAvatar(radius: 18, child: Icon(Icons.sports, size: 20)),
      title: Text(c.name),
      subtitle: Text(
        '${c.subtitle} · ${token == null ? 'noch kein Link' : 'Link vorhanden'}',
      ),
      trailing: _actions(
        token: token,
        onAction: (a) async {
          final t = await ratingLinkAction(
            context,
            who: c.name,
            token: token,
            action: a,
            create: () =>
                PeerRatingService.createCoachLink(c.raterId, teamId, c.name),
            url: coachRatingLink,
            message: (t) => coachLinkMessage(c.name, t),
          );
          if (t != null && mounted) setState(() => cl[c.raterId] = t);
        },
      ),
    );
  }

  Widget _row(
    BuildContext context,
    Player p,
    String teamId,
    Map<String, String> links,
  ) {
    final token = links[p.id];
    return ListTile(
      leading: PlayerAvatar(player: p, radius: 18),
      title: Text(p.fullName),
      subtitle: Text(token == null ? 'Noch kein Link' : 'Link vorhanden'),
      trailing: _actions(
        token: token,
        onAction: (a) async {
          final t = await peerLinkAction(context, p, teamId, token, a);
          if (t != null && mounted) setState(() => links[p.id] = t);
        },
      ),
    );
  }
}

class _Info extends StatelessWidget {
  const _Info(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(text, textAlign: TextAlign.center),
    ),
  );
}
