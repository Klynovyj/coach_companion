import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/peer_rating.dart';
import '../models/player.dart';
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

/// Teilen/Kopieren/Neu erzeugen für den Link eines Spielers. Gibt den
/// (ggf. neuen) Token zurück; `null` bei Abbruch/Fehler.
Future<String?> peerLinkAction(
  BuildContext context,
  Player p,
  String teamId,
  String? token,
  String action, // share | copy | renew
) async {
  final messenger = ScaffoldMessenger.of(context);
  var t = token;
  if (action == 'renew' && t != null) {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Neuen Link erzeugen?'),
        content: Text(
          'Der bisherige Link von ${p.fullName} funktioniert danach nicht mehr. '
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
    t = await PeerRatingService.createLink(p.id, teamId);
    if (t == null) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Link konnte nicht angelegt werden (online? Cloud-Stufe 59 ausgeführt?).',
          ),
        ),
      );
      return null;
    }
  }
  if (action == 'copy') {
    await Clipboard.setData(ClipboardData(text: peerRatingLink(t)));
    messenger.showSnackBar(const SnackBar(content: Text('Link kopiert.')));
  } else if (action == 'share') {
    await shareText(peerLinkMessage(p, t));
  } else {
    messenger.showSnackBar(
      const SnackBar(content: Text('Neuer Link erzeugt – bitte neu teilen.')),
    );
  }
  return t;
}

/// Alle persönlichen Bewertungs-Links des Teams: anlegen, teilen, kopieren,
/// neu erzeugen. Jeder Spieler bekommt seinen Link einmal – er gilt dauerhaft.
class PeerLinksScreen extends StatefulWidget {
  const PeerLinksScreen({super.key});

  @override
  State<PeerLinksScreen> createState() => _PeerLinksScreenState();
}

class _PeerLinksScreenState extends State<PeerLinksScreen> {
  List<Player> _players = [];
  Map<String, String>? _links;
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
    final players =
        (await s.playersOf(
          teamId,
          onlyActive: true,
        )).where((p) => !p.isStaffOnly).toList()..sort((a, b) {
          final an = a.number ?? 9999, bn = b.number ?? 9999;
          return an != bn ? an.compareTo(bn) : a.lastName.compareTo(b.lastName);
        });
    final links = await PeerRatingService.links(teamId);
    if (!mounted) return;
    setState(() {
      _players = players;
      _links = links;
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
    final missing = links == null
        ? 0
        : _players.where((p) => !links.containsKey(p.id)).length;
    return Scaffold(
      appBar: AppBar(title: const Text('Spieler-Links (Bewertung)')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : teamId == null
          ? const _Info('Spieler-Links gibt es nur mit einem Cloud-Team.')
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
                          'Jeder Spieler bekommt einmal seinen persönlichen '
                          'Link (z. B. per WhatsApp). Er gilt dauerhaft und '
                          'zeigt nach jedem Spiel die offene Bewertung – nur '
                          'für Spieler mit Einsatz, bis 3 Tage nach Spielende. '
                          'Nach dem Spiel reicht eine Nachricht in die Gruppe '
                          '(„Gruppe benachrichtigen" in der Spielauswertung).',
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
                for (final p in _players) _row(context, p, teamId, links),
              ],
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
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Link teilen',
            icon: const Icon(Icons.share),
            onPressed: () => _act(p, teamId, token, 'share'),
          ),
          PopupMenuButton<String>(
            onSelected: (v) => _act(p, teamId, token, v),
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
      ),
    );
  }

  Future<void> _act(Player p, String teamId, String? token, String a) async {
    final t = await peerLinkAction(context, p, teamId, token, a);
    if (t != null && mounted) setState(() => _links?[p.id] = t);
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
