import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/enums.dart';
import '../models/player.dart';
import '../models/team_event.dart';
import '../services/share_service.dart';
import '../state/app_state.dart';
import '../widgets/availability_controls.dart';
import '../widgets/player_avatar.dart';
import 'termine_screen.dart';

class EventDetailScreen extends StatefulWidget {
  const EventDetailScreen({super.key, required this.eventId});
  final String eventId;

  @override
  State<EventDetailScreen> createState() => _EventDetailScreenState();
}

class _EventDetailScreenState extends State<EventDetailScreen> {
  TeamEvent? _event;
  List<Player> _players = [];
  Map<String, NominationStatus> _status = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    final event = await state.getTeamEvent(widget.eventId);
    final own = state.ownTeam;
    final players = own == null ? <Player>[] : await state.playersOf(own.id);
    final att = await state.eventAttendance(widget.eventId);
    if (!mounted) return;
    setState(() {
      _event = event;
      _players = players;
      _status = {for (final p in players) p.id: att[p.id] ?? NominationStatus.open};
      _loading = false;
    });
  }

  NominationStatus _statusOf(Player p) =>
      _status[p.id] ?? NominationStatus.open;

  Future<void> _set(Player p, NominationStatus s) async {
    setState(() => _status[p.id] = s);
    await context.read<AppState>().setEventAttendance(widget.eventId, p.id, s);
  }

  int _count(NominationStatus s) =>
      _players.where((p) => _statusOf(p) == s).length;

  Future<void> _edit() async {
    final data = await showEventDialog(context, existing: _event);
    if (data == null || !mounted) return;
    await context.read<AppState>().updateTeamEvent(_event!.copyWith(
          title: data.title,
          type: data.type,
          date: data.date,
          location: data.location,
          note: data.note,
        ));
    await _load();
  }

  Future<void> _share() async {
    final e = _event;
    if (e == null) return;
    final text = buildEventText(event: e, players: _players, status: _status);
    final ok = await shareViaWhatsApp(text);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('WhatsApp konnte nicht geöffnet werden.')),
      );
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Termin löschen?'),
        content: Text('„${_event?.title}" wirklich entfernen?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Löschen')),
        ],
      ),
    );
    if (ok == true && mounted) {
      await context.read<AppState>().deleteTeamEvent(widget.eventId);
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final e = _event;
    if (e == null) {
      return const Scaffold(body: Center(child: Text('Termin nicht gefunden.')));
    }
    final df = DateFormat('EEEE, dd.MM.yyyy • HH:mm', 'de_DE');

    return Scaffold(
      appBar: AppBar(
        title: Text(e.title),
        actions: [
          IconButton(
              tooltip: 'Termin teilen (WhatsApp)',
              onPressed: _share,
              icon: const Icon(Icons.share)),
          IconButton(
              onPressed: _edit, icon: const Icon(Icons.edit)),
          IconButton(
              onPressed: _delete, icon: const Icon(Icons.delete_outline)),
        ],
      ),
      body: ListView(
        children: [
          Container(
            width: double.infinity,
            color: Theme.of(context).colorScheme.primary,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(e.type.symbol, style: const TextStyle(fontSize: 22)),
                    const SizedBox(width: 8),
                    Text(e.type.label,
                        style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onPrimary
                                .withValues(alpha: 0.9))),
                  ],
                ),
                const SizedBox(height: 8),
                Text(df.format(e.date),
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.onPrimary,
                        fontWeight: FontWeight.bold,
                        fontSize: 16)),
                if (e.location != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(children: [
                      Icon(Icons.place,
                          size: 16,
                          color: Theme.of(context).colorScheme.onPrimary),
                      const SizedBox(width: 4),
                      Text(e.location!,
                          style: TextStyle(
                              color:
                                  Theme.of(context).colorScheme.onPrimary)),
                    ]),
                  ),
                if (e.note != null && e.note!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(e.note!,
                        style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onPrimary
                                .withValues(alpha: 0.9))),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: AvailabilitySummary(counts: {
              for (final s in NominationStatus.values) s: _count(s),
            }),
          ),
          const Divider(height: 1),
          if (_players.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Noch keine Spieler im Kader.'),
            )
          else
            ..._players.map((p) => ListTile(
                  leading: PlayerAvatar(player: p, radius: 18),
                  title: Text(p.fullName),
                  trailing: AvailabilityChoices(
                    current: _statusOf(p),
                    onChanged: (s) => _set(p, s),
                  ),
                )),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
