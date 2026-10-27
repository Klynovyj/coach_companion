import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/enums.dart';
import '../models/match.dart';
import '../models/player.dart';
import '../services/share_service.dart';
import '../state/app_state.dart';
import '../widgets/availability_controls.dart';
import '../widgets/team_logo.dart';

class NominationScreen extends StatefulWidget {
  const NominationScreen({
    super.key,
    required this.matchId,
    required this.teamId,
    required this.title,
    this.readOnly = false,
  });

  final String matchId;
  final String teamId;
  final String title;

  /// Nur-Lese-Modus (z.B. Spiel beendet): keine Änderungen möglich.
  final bool readOnly;

  @override
  State<NominationScreen> createState() => _NominationScreenState();
}

class _NominationScreenState extends State<NominationScreen> {
  List<Player> _players = [];
  Map<String, NominationStatus> _status = {};
  GameMatch? _match;
  bool _loading = true;

  late final AppState _app = context.read<AppState>();

  @override
  void initState() {
    super.initState();
    // Live-Updates anderer Trainer (Realtime) sofort übernehmen.
    _app.addListener(_onChanged);
    _load();
  }

  void _onChanged() {
    if (mounted) _load();
  }

  @override
  void dispose() {
    _app.removeListener(_onChanged);
    super.dispose();
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    // Reines Trainerteam wird nicht nominiert (spielender Co-Trainer schon).
    final players = (await state.playersOf(widget.teamId))
        .where(
          (p) => !p.isStaffOnly && p.active && p.status != PlayerStatus.inaktiv,
        )
        .toList();
    final noms = await state.nominationsOf(widget.matchId);
    final match = await state.getMatch(widget.matchId);
    if (!mounted) return;
    setState(() {
      _players = players;
      _match = match;
      _status = {
        for (final p in players) p.id: noms[p.id] ?? NominationStatus.open,
      };
      _loading = false;
    });
  }

  NominationStatus _statusOf(Player p) =>
      _status[p.id] ?? NominationStatus.open;

  Future<void> _set(Player p, NominationStatus s) async {
    setState(() => _status[p.id] = s);
    await context.read<AppState>().setNomination(widget.matchId, p.id, s);
  }

  int _count(NominationStatus s) =>
      _players.where((p) => _statusOf(p) == s).length;

  Future<void> _share() async {
    final match = await context.read<AppState>().getMatch(widget.matchId);
    final text = buildNominationText(
      title: 'vs ${widget.title}',
      kickoff: match?.kickoff?.toLocal(),
      players: _players,
      status: _status,
    );
    final ok = await shareViaWhatsApp(text);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('WhatsApp konnte nicht geöffnet werden.')),
      );
    }
  }

  Future<void> _resetNomination() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Nominierung zurücksetzen?'),
        content: const Text('Alle Spieler werden auf „offen" gesetzt.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Zurücksetzen'),
          ),
        ],
      ),
    );
    if (ok == true) _bulk(NominationStatus.open);
  }

  Future<void> _bulk(NominationStatus s) async {
    setState(() {
      for (final p in _players) {
        _status[p.id] = s;
      }
    });
    await context.read<AppState>().setNominationBulk(
      widget.matchId,
      _players.map((p) => p.id).toList(),
      s,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(
        title: Text('Nominierung · ${widget.title}'),
        actions: [
          IconButton(
            tooltip: 'Nominierung teilen (WhatsApp)',
            icon: const Icon(Icons.share),
            onPressed: _share,
          ),
          if (!widget.readOnly)
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'all_in') _bulk(NominationStatus.zugesagt);
                if (v == 'reset') _resetNomination();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'all_in', child: Text('Alle zusagen')),
                PopupMenuItem(
                  value: 'reset',
                  child: Text('Nominierung zurücksetzen'),
                ),
              ],
            ),
        ],
      ),
      body: _players.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Noch keine Spieler im Kader.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : Column(
              children: [
                if (widget.readOnly) _readOnlyBanner(context),
                _summary(),
                const Divider(height: 1),
                Expanded(
                  child: ListView.separated(
                    itemCount: _players.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) => _row(_players[i]),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _summary() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: AvailabilitySummary(
        counts: {for (final s in NominationStatus.values) s: _count(s)},
      ),
    );
  }

  Widget _row(Player p) {
    final suspended = _match != null && _app.isSuspendedForMatch(p, _match!);
    final absent =
        p.status != PlayerStatus.fit && p.status != PlayerStatus.inaktiv;
    // Status am Foto (Icon oben, Text darunter): Sperre hat Vorrang, sonst
    // Verletzt/Krank/Urlaub. Spieler bleibt in allen Fällen wählbar.
    final String? statusEmoji = suspended
        ? '⛔'
        : (absent ? p.status.symbol : null);
    final String? statusLabel = suspended
        ? 'Gesperrt${p.suspendedGames > 0 ? ' ${p.suspendedGames}' : ''}'
        : (absent ? p.status.label : null);
    final Color statusColor = suspended
        ? Theme.of(context).colorScheme.error
        : const Color(0xFF8A4B00);
    final pos = p.position;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 56,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _playerPhoto(p, emoji: statusEmoji),
                if (statusLabel != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    statusLabel,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 9,
                      height: 1.0,
                      fontWeight: FontWeight.w800,
                      color: statusColor,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p.fullName,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if (pos != null && pos.isNotEmpty)
                  Text(pos, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          const SizedBox(width: 8),
          widget.readOnly
              ? _statusChip(_statusOf(p))
              : AvailabilityChoices(
                  current: _statusOf(p),
                  onChanged: (s) => _set(p, s),
                ),
        ],
      ),
    );
  }

  /// Quadratisches Spielerfoto (abgerundete Ecken) mit optionalem Status-Icon
  /// in der Ecke; Rückfall auf Initiale.
  Widget _playerPhoto(Player p, {String? emoji}) {
    final bytes = TeamLogo.decode(p.photoPath);
    final fallback = p.lastName.isNotEmpty
        ? p.lastName[0].toUpperCase()
        : (p.firstName.isNotEmpty ? p.firstName[0].toUpperCase() : '?');
    return Stack(
      clipBehavior: Clip.none,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 44,
            height: 44,
            child: bytes != null
                ? Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true)
                : Container(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    alignment: Alignment.center,
                    child: Text(
                      fallback,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
          ),
        ),
        if (emoji != null)
          Positioned(
            top: -4,
            right: -4,
            child: Container(
              padding: const EdgeInsets.all(1),
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
              child: Text(emoji, style: const TextStyle(fontSize: 13)),
            ),
          ),
      ],
    );
  }

  /// Hinweiszeile im Nur-Lese-Modus.
  Widget _readOnlyBanner(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Icon(Icons.lock_outline, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Spiel beendet – Nominierung nur zur Ansicht.',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  /// Nur-Lese-Statuschip (Zu/Unsicher/Vorbehalt/Ab/Offen).
  Widget _statusChip(NominationStatus s) {
    final c = availabilityColor(s);
    final label = switch (s) {
      NominationStatus.zugesagt => 'Zu',
      NominationStatus.unsicher => 'Unsicher',
      NominationStatus.unterVorbehalt => 'Vorbehalt',
      NominationStatus.abgesagt => 'Ab',
      NominationStatus.open => 'Offen',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: c.withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        style: TextStyle(color: c, fontWeight: FontWeight.w600, fontSize: 12),
      ),
    );
  }
}
