import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../widgets/player_avatar.dart';

/// Karten & Sperren: je Feldspieler die FuPa-Saisonkarten (offiziell) und die
/// eigenen erfassten Karten, dazu „noch X Gelbe bis zur Sperre" (Schwelle 5)
/// und eine manuell gepflegte Sperre („gesperrt für N Spiele").
class CardsSuspensionsScreen extends StatefulWidget {
  const CardsSuspensionsScreen({super.key});

  @override
  State<CardsSuspensionsScreen> createState() => _CardsSuspensionsScreenState();
}

class _CardsSuspensionsScreenState extends State<CardsSuspensionsScreen> {
  late final AppState _app = context.read<AppState>();
  List<PlayerCardSummary> _rows = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _app.addListener(_onChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
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
    final team = _app.ownTeam;
    if (team == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final rows = await _app.cardSummaries(team.id);
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _loading = false;
    });
  }

  Future<void> _setSuspension(PlayerCardSummary s, int games) async {
    await _app.setSuspendedGames(s.player, games);
    // _load() wird über den Listener ausgelöst.
  }

  /// Dialog: Wettbewerb + Startdatum + Anzahl Spiele einer Sperre eintragen.
  Future<void> _editSuspension(PlayerCardSummary s) async {
    final p = s.player;
    final comps = _app.competitionsInSchedule();
    String? comp =
        p.suspensionCompetition ?? (comps.isNotEmpty ? comps.first : null);
    var from = p.suspensionFrom ?? DateTime.now();
    var games = p.suspendedGames > 0 ? p.suspendedGames : 1;
    final df = DateFormat('dd.MM.yyyy', 'de_DE');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text('Sperre – ${p.fullName}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (comps.isEmpty)
                const Text(
                  'Kein Wettbewerb im Spielplan gefunden – '
                  'die Sperre gilt dann für alle Spiele.',
                )
              else
                DropdownButtonFormField<String>(
                  initialValue: comp,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Wettbewerb'),
                  items: [
                    for (final c in comps)
                      DropdownMenuItem(value: c, child: Text(c)),
                  ],
                  onChanged: (v) => setD(() => comp = v),
                ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Text('Gesperrt ab: '),
                  TextButton(
                    onPressed: () async {
                      final d = await showDatePicker(
                        context: ctx,
                        initialDate: from,
                        firstDate: DateTime(2020),
                        lastDate: DateTime(2100),
                        helpText: 'Sperre ab',
                      );
                      if (d != null) setD(() => from = d);
                    },
                    child: Text(df.format(from)),
                  ),
                ],
              ),
              Row(
                children: [
                  const Text('Anzahl Spiele: '),
                  IconButton(
                    onPressed: () => setD(() {
                      if (games > 1) games--;
                    }),
                    icon: const Icon(Icons.remove_circle_outline),
                    visualDensity: VisualDensity.compact,
                  ),
                  Text(
                    '$games',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  IconButton(
                    onPressed: () => setD(() => games++),
                    icon: const Icon(Icons.add_circle_outline),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Speichern'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      await _app.setSuspension(p, games: games, competition: comp, from: from);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Karten & Sperren')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _rows.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Keine Spieler.\nKader importieren bzw. anlegen.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                _legend(context),
                for (final s in _rows) _row(context, s),
              ],
            ),
    );
  }

  Widget _legend(BuildContext context) {
    final subtle = Theme.of(context).textTheme.bodySmall?.color;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        'FuPa = offizielle Saisonkarten (zählt der Verband) · Eigene = von euch '
        'erfasst. Sperre fällig ab der 5. Gelben. Sperren trägst du manuell ein.',
        style: TextStyle(fontSize: 12, color: subtle),
      ),
    );
  }

  Widget _row(BuildContext context, PlayerCardSummary s) {
    final scheme = Theme.of(context).colorScheme;
    final p = s.player;
    final suspended = p.suspendedGames > 0;
    final banDue = s.yellowBanDue;
    final warn = s.yellowWarn;

    // Farbliche Hervorhebung nach Gefährdung: gesperrt (rot) → Sperre fällig
    // (kräftiges Orange) → gefährdet ab 3 Gelben (helles Amber).
    final Color? cardColor = suspended
        ? scheme.errorContainer
        : banDue
        ? const Color(0xFFFFE0B2)
        : warn
        ? const Color(0xFFFFF8E1)
        : null;

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      color: cardColor,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PlayerAvatar(player: p, radius: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          p.displayName,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (suspended)
                        _badge(
                          'GESPERRT · noch ${p.suspendedGames}',
                          scheme.error,
                          Colors.white,
                        )
                      else if (banDue)
                        _badge(
                          'SPERRE FÄLLIG',
                          const Color(0xFFEF6C00),
                          Colors.white,
                        )
                      else if (warn)
                        _badge(
                          'GEFÄHRDET',
                          const Color(0xFFF9A825),
                          Colors.white,
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  _cardsLine(
                    context,
                    'FuPa',
                    s.fupaYellow,
                    s.fupaYellowRed,
                    s.fupaRed,
                  ),
                  const SizedBox(height: 2),
                  _cardsLine(
                    context,
                    'Eigene',
                    s.ownYellow,
                    s.ownYellowRed,
                    s.ownRed,
                  ),
                  if (!suspended && s.yellowToBan > 0 && s.fupaYellow > 0) ...[
                    const SizedBox(height: 4),
                    Text(
                      'noch ${s.yellowToBan} Gelbe bis zur Sperre',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).textTheme.bodySmall?.color,
                      ),
                    ),
                  ],
                  const SizedBox(height: 6),
                  _suspensionControls(context, s),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cardsLine(
    BuildContext context,
    String label,
    int yellow,
    int yellowRed,
    int red,
  ) {
    final subtle = Theme.of(context).textTheme.bodySmall?.color;
    return Row(
      children: [
        SizedBox(
          width: 52,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: subtle,
            ),
          ),
        ),
        _chip('🟨', yellow),
        const SizedBox(width: 10),
        _chip('🟨🟥', yellowRed),
        const SizedBox(width: 10),
        _chip('🟥', red),
      ],
    );
  }

  Widget _chip(String symbol, int count) {
    return Text(
      '$symbol $count',
      style: TextStyle(
        fontSize: 13,
        fontWeight: count > 0 ? FontWeight.w700 : FontWeight.w400,
        color: count > 0 ? null : Colors.grey,
      ),
    );
  }

  Widget _suspensionControls(BuildContext context, PlayerCardSummary s) {
    final p = s.player;
    if (p.suspendedGames <= 0) {
      return Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: () => _editSuspension(s),
          icon: const Icon(Icons.block, size: 16),
          label: const Text('Sperre eintragen'),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            visualDensity: VisualDensity.compact,
          ),
        ),
      );
    }
    final df = DateFormat('dd.MM.yyyy', 'de_DE');
    final info = [
      if (p.suspensionCompetition != null) p.suspensionCompetition!,
      if (p.suspensionFrom != null) 'ab ${df.format(p.suspensionFrom!)}',
    ].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (info.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(
              info,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).hintColor,
              ),
            ),
          ),
        Row(
          children: [
            const Text(
              'Gesperrt für',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            IconButton(
              onPressed: () => _setSuspension(s, p.suspendedGames - 1),
              icon: const Icon(Icons.remove_circle_outline),
              visualDensity: VisualDensity.compact,
              tooltip: 'Ein Spiel weniger',
            ),
            Text(
              '${p.suspendedGames} Spiel(e)',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            IconButton(
              onPressed: () => _setSuspension(s, p.suspendedGames + 1),
              icon: const Icon(Icons.add_circle_outline),
              visualDensity: VisualDensity.compact,
              tooltip: 'Ein Spiel mehr',
            ),
            TextButton(
              onPressed: () => _editSuspension(s),
              child: const Text('Ändern'),
            ),
            TextButton(
              onPressed: () => _setSuspension(s, 0),
              child: const Text('Aufheben'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _badge(String text, Color bg, Color fg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(color: fg, fontSize: 11, fontWeight: FontWeight.w800),
      ),
    );
  }
}
