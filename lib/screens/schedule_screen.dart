import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/enums.dart';
import '../models/match.dart';
import '../state/app_state.dart';
import '../widgets/team_logo.dart';
import '../widgets/ui_bits.dart';
import 'match_center_screen.dart';

class ScheduleScreen extends StatelessWidget {
  const ScheduleScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final matches = state.matches;
    final df = DateFormat("HH:mm 'Uhr'", 'de_DE');

    return Scaffold(
      appBar: AppBar(
        title: const Text('Spielplan'),
        actions: [
          IconButton(
            tooltip: 'FuPa-Spielplan importieren',
            icon: const Icon(Icons.cloud_download),
            onPressed: () => _importSchedule(context),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addMatch(context),
        icon: const Icon(Icons.add),
        label: const Text('Spiel'),
      ),
      body: matches.isEmpty
          ? const _EmptySchedule()
          : ListView.builder(
              padding: const EdgeInsets.only(bottom: 88),
              itemCount: matches.length,
              itemBuilder: (context, i) =>
                  _MatchCard(match: matches[i], df: df, onTap: () => _open(context, matches[i])),
            ),
    );
  }

  Future<void> _importSchedule(BuildContext context) async {
    final controller = TextEditingController(
        text: context.read<AppState>().ownTeam?.fupaUrl ?? '');
    final url = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('FuPa-Spielplan importieren'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
                'FuPa-Teamlink einfügen – die Spiele (inkl. Ergebnisse und '
                'Gegner-Wappen) werden geladen. Doppelte Spiele werden erkannt.'),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'FuPa-Teamlink',
                hintText: 'https://www.fupa.net/team/...',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('Importieren')),
        ],
      ),
    );
    if (url == null || url.isEmpty || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(children: [
          CircularProgressIndicator(),
          SizedBox(width: 16),
          Expanded(child: Text('Spielplan wird geladen …')),
        ]),
      ),
    );
    try {
      final added = await context.read<AppState>().importSchedule(url);
      if (context.mounted) Navigator.pop(context); // Ladedialog schließen
      messenger.showSnackBar(SnackBar(
          content: Text('Spielplan importiert: $added neue Spiele.')));
    } catch (e) {
      if (context.mounted) Navigator.pop(context);
      messenger.showSnackBar(SnackBar(
          content: Text('Import fehlgeschlagen: $e'),
          backgroundColor: Colors.red.shade700));
    }
  }

  Future<void> _open(BuildContext context, GameMatch match) async {
    // Beim Öffnen: Gegner sicherstellen (import oder Platzhalter).
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MatchCenterScreen(matchId: match.id),
      ),
    );
  }

  Future<void> _addMatch(BuildContext context) async {
    final result = await showModalBottomSheet<_NewMatchData>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _NewMatchSheet(),
    );
    if (result == null || !context.mounted) return;
    final match = await context.read<AppState>().addMatch(
          opponentName: result.opponent,
          kickoff: result.kickoff,
          venue: result.venue,
          competition: result.competition,
        );
    if (!context.mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => MatchCenterScreen(matchId: match.id)),
    );
  }
}

class _MatchCard extends StatelessWidget {
  const _MatchCard({required this.match, required this.df, required this.onTap});
  final GameMatch match;
  final DateFormat df;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final played = match.status != MatchStatus.scheduled ||
        match.ownScore != 0 ||
        match.opponentScore != 0;
    final live = match.status == MatchStatus.live;

    Widget trailing;
    if (live) {
      trailing = Column(mainAxisSize: MainAxisSize.min, children: [
        Text('${match.ownScore}:${match.opponentScore}',
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 20)),
        const Pill(text: 'LIVE', color: Colors.red, filled: true),
      ]);
    } else if (played) {
      final win = match.ownScore > match.opponentScore;
      final draw = match.ownScore == match.opponentScore;
      final c = win
          ? const Color(0xFF2E7D32)
          : draw
              ? const Color(0xFF9E9E9E)
              : const Color(0xFFC62828);
      trailing =
          Pill(text: '${match.ownScore}:${match.opponentScore}', color: c, filled: true);
    } else {
      trailing = Pill(
        text: match.venue == Venue.home ? 'Heim' : 'Auswärts',
        color: match.venue == Venue.home
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.tertiary,
      );
    }

    return Card(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              DateBlock(date: match.kickoff?.toLocal(), highlight: live),
              const SizedBox(width: 12),
              if (match.opponentLogoPath != null) ...[
                TeamLogo(logoPath: match.opponentLogoPath, size: 32),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(match.opponentName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 15)),
                    const SizedBox(height: 2),
                    Text([
                      if (match.kickoff != null)
                        df.format(match.kickoff!.toLocal()),
                      if (match.competition != null) match.competition!,
                    ].join('  ·  '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              trailing,
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptySchedule extends StatelessWidget {
  const _EmptySchedule();
  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.event_busy, size: 56, color: Colors.grey),
            SizedBox(height: 12),
            Text(
              'Noch keine Spiele.\nFüge ein Spiel hinzu oder verbinde einen '
              'FuPa-Link in den Einstellungen.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _NewMatchData {
  final String opponent;
  final DateTime? kickoff;
  final Venue venue;
  final String? competition;
  _NewMatchData(this.opponent, this.kickoff, this.venue, this.competition);
}

class _NewMatchSheet extends StatefulWidget {
  const _NewMatchSheet();
  @override
  State<_NewMatchSheet> createState() => _NewMatchSheetState();
}

class _NewMatchSheetState extends State<_NewMatchSheet> {
  final _opp = TextEditingController();
  final _comp = TextEditingController();
  DateTime? _kickoff;
  Venue _venue = Venue.home;

  @override
  void dispose() {
    _opp.dispose();
    _comp.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final df = DateFormat('dd.MM.yyyy HH:mm', 'de_DE');
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Neues Spiel',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          TextField(
            controller: _opp,
            decoration: const InputDecoration(labelText: 'Gegner'),
          ),
          const SizedBox(height: 12),
          SegmentedButton<Venue>(
            segments: const [
              ButtonSegment(value: Venue.home, label: Text('Heim')),
              ButtonSegment(value: Venue.away, label: Text('Auswärts')),
            ],
            selected: {_venue},
            onSelectionChanged: (s) => setState(() => _venue = s.first),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _pickDate,
            icon: const Icon(Icons.schedule),
            label: Text(_kickoff == null
                ? 'Anstoßzeit wählen'
                : df.format(_kickoff!)),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _comp,
            decoration:
                const InputDecoration(labelText: 'Wettbewerb (optional)'),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () {
              if (_opp.text.trim().isEmpty) return;
              Navigator.pop(
                context,
                _NewMatchData(
                  _opp.text.trim(),
                  _kickoff,
                  _venue,
                  _comp.text.trim().isEmpty ? null : _comp.text.trim(),
                ),
              );
            },
            child: const Text('Spiel anlegen'),
          ),
        ],
      ),
    );
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 2),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 15, minute: 0),
    );
    setState(() {
      _kickoff = DateTime(
        date.year,
        date.month,
        date.day,
        time?.hour ?? 15,
        time?.minute ?? 0,
      );
    });
  }
}
