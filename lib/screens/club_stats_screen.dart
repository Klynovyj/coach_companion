import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';

import '../services/fupa/fupa_dtos.dart';
import '../services/share_service.dart';
import '../state/app_state.dart';
import '../widgets/player_avatar.dart';
import 'club_player_career_screen.dart';

enum _ClubSort { games, goals, assists, scorer, name }

enum _View { players, staff, all }

/// Vereins-Bilanz aller Spieler aus der FuPa-Laufbahn: Spiele/Tore/Vorlagen/
/// Scorer beim aktuellen Verein (offizielle Pflichtspiele – FuPa führt in der
/// Laufbahn keine Freundschaftsspiele) plus Saison-Minuten. Pro Spieler ein
/// FuPa-Abruf beim Öffnen.
class ClubStatsScreen extends StatefulWidget {
  const ClubStatsScreen({super.key});

  @override
  State<ClubStatsScreen> createState() => _ClubStatsScreenState();
}

class _ClubStatsScreenState extends State<ClubStatsScreen> {
  _ClubSort _sort = _ClubSort.scorer;
  _View _view = _View.players;
  List<PlayerClubStats> _rows = [];
  bool _loading = true;
  bool _sharing = false;
  final GlobalKey _tableKey = GlobalKey();
  String _teamName = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    final team = state.ownTeam;
    if (team == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final (rows, _) = await state.squadFupaClubStats(team.id);
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _teamName = team.name;
      _loading = false;
    });
  }

  /// Teilt die Tabelle als Bild (RepaintBoundary → PNG → WhatsApp/Download).
  Future<void> _share() async {
    if (_sharing) return;
    setState(() => _sharing = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final b =
          _tableKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (b == null) return;
      final image = await b.toImage(pixelRatio: 2.5);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return;
      final name = _teamName.isEmpty ? 'Team' : _teamName;
      final path = await shareOrSaveImage(
        data.buffer.asUint8List(),
        'Vereins-Bilanz_$name',
        text: 'Vereins-Bilanz – $name',
      );
      if (path != null && mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Als Bild gespeichert:\n$path')),
        );
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Teilen fehlgeschlagen: $e')),
      );
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  // FuPa listet in der Laufbahn nur offizielle Spiele (Liga/Pokal) – das sind
  // bereits die Pflichtspiele; Freundschaftsspiele gibt es dort nicht.
  FupaClubTotal _t(PlayerClubStats r) => r.all;

  List<PlayerClubStats> _sorted() {
    final list = _rows.where((r) {
      switch (_view) {
        case _View.players:
          return r.isFieldPlayer;
        case _View.staff:
          return r.isStaff;
        case _View.all:
          return true;
      }
    }).toList();
    // Trainer-Ansicht: nach Punkten (Trainer-Bilanz).
    if (_view == _View.staff) {
      list.sort((a, b) {
        final c = b.coachPoints.compareTo(a.coachPoints);
        return c != 0 ? c : b.coachMatches.compareTo(a.coachMatches);
      });
      return list;
    }
    int cmp(PlayerClubStats a, PlayerClubStats b) {
      switch (_sort) {
        case _ClubSort.games:
          return _t(b).matches.compareTo(_t(a).matches);
        case _ClubSort.goals:
          return _t(b).goals.compareTo(_t(a).goals);
        case _ClubSort.assists:
          return _t(b).assists.compareTo(_t(a).assists);
        case _ClubSort.scorer:
          return _t(b).scorerPoints.compareTo(_t(a).scorerPoints);
        case _ClubSort.name:
          return a.player.fullName.toLowerCase().compareTo(
            b.player.fullName.toLowerCase(),
          );
      }
    }

    list.sort(cmp);
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sorted = _sorted();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Vereins-Bilanz (FuPa)'),
        actions: [
          IconButton(
            tooltip: 'Als Bild teilen (WhatsApp)',
            icon: _sharing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.ios_share),
            onPressed: (_loading || _rows.isEmpty || _sharing) ? null : _share,
          ),
        ],
      ),
      body: _loading
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 12),
                  Text('FuPa-Laufbahn aller Spieler wird geladen …'),
                ],
              ),
            )
          : _rows.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('Keine Spieler.', textAlign: TextAlign.center),
              ),
            )
          : Column(
              children: [
                _controls(),
                const Divider(height: 1),
                Expanded(
                  child: SingleChildScrollView(
                    child: RepaintBoundary(
                      key: _tableKey,
                      child: Container(
                        color: scheme.surface,
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Column(
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      'Vereins-Bilanz · ${_teamName.isEmpty ? 'Verein' : _teamName}',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                        fontSize: 14,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            _headerRow(),
                            const Divider(height: 1),
                            for (final r in sorted) ...[
                              _row(r),
                              const Divider(height: 1),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _controls() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<_View>(
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: const [
                ButtonSegment(value: _View.players, label: Text('Spieler')),
                ButtonSegment(value: _View.staff, label: Text('Trainer')),
                ButtonSegment(value: _View.all, label: Text('Alle')),
              ],
              selected: {_view},
              onSelectionChanged: (s) => setState(() => _view = s.first),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  _view == _View.staff
                      ? 'Trainer-Bilanz (Karriere): Sp·S·U·N·Punkte'
                      : 'Pflichtspiele beim Verein (Liga + Pokal)',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              if (_view != _View.staff) ...[
                const SizedBox(width: 8),
                const Text('Sortieren: '),
                DropdownButton<_ClubSort>(
                  value: _sort,
                  onChanged: (v) => setState(() => _sort = v ?? _sort),
                  items: const [
                    DropdownMenuItem(
                      value: _ClubSort.scorer,
                      child: Text('Scorer'),
                    ),
                    DropdownMenuItem(
                      value: _ClubSort.games,
                      child: Text('Spiele'),
                    ),
                    DropdownMenuItem(
                      value: _ClubSort.goals,
                      child: Text('Tore'),
                    ),
                    DropdownMenuItem(
                      value: _ClubSort.assists,
                      child: Text('Vorlagen'),
                    ),
                    DropdownMenuItem(
                      value: _ClubSort.name,
                      child: Text('Name'),
                    ),
                  ],
                ),
              ],
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              _view == _View.staff
                  ? 'Trainer-Werte über die gesamte Trainerlaufbahn (FuPa, alle Vereine).'
                  : 'FuPa führt in der Laufbahn nur offizielle Spiele – '
                        'Freundschafts-/Testspiele sind dort nicht enthalten.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  static const _w = 34.0;

  Widget _num(String t, {bool header = false, Color? color}) => SizedBox(
    width: _w,
    child: Text(
      t,
      textAlign: TextAlign.center,
      maxLines: 1,
      style: TextStyle(
        fontSize: header ? 12 : 13,
        fontWeight: header ? FontWeight.bold : FontWeight.w600,
        color: color,
      ),
    ),
  );

  Widget _headerRow() {
    final staff = _view == _View.staff;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Row(
        children: [
          const SizedBox(width: 26),
          Expanded(
            child: Text(
              staff ? 'Trainer' : 'Spieler',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
            ),
          ),
          if (staff) ...[
            _num('Sp', header: true),
            _num('S', header: true),
            _num('U', header: true),
            _num('N', header: true),
            _num('Pkt', header: true),
          ] else ...[
            _num('Sp', header: true),
            _num('⚽', header: true),
            _num('🅰', header: true),
            _num('Scr', header: true),
          ],
        ],
      ),
    );
  }

  Widget _row(PlayerClubStats r) {
    final staff = _view == _View.staff;
    final t = _t(r);
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ClubPlayerCareerScreen(player: r.player),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          children: [
            SizedBox(
              width: 26,
              child: PlayerAvatar(player: r.player, radius: 13),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    r.player.fullName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  if (staff)
                    Text(
                      '${(r.player.staffRole?.isNotEmpty ?? false) ? r.player.staffRole : 'Trainer'} · Trainer-Bilanz (Karriere)',
                      style: TextStyle(
                        fontSize: 10,
                        color: scheme.onSurfaceVariant,
                      ),
                    )
                  else ...[
                    if (r.spell?.sinceYear != null)
                      Text(
                        'beim Verein seit ${r.spell!.sinceYear} · '
                        '${r.spell!.yearsUntil(DateTime.now().year)} J.',
                        style: TextStyle(
                          fontSize: 10,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    if (!r.hasFupa)
                      Text(
                        'keine FuPa-Daten',
                        style: TextStyle(fontSize: 10, color: scheme.error),
                      ),
                  ],
                ],
              ),
            ),
            if (staff) ...[
              _num('${r.coachMatches}'),
              _num('${r.coachWins}'),
              _num('${r.coachDraws}'),
              _num('${r.coachLosses}'),
              _num('${r.coachPoints}', color: scheme.primary),
            ] else ...[
              _num('${t.matches}'),
              _num('${t.goals}'),
              _num('${t.assists}'),
              _num('${t.scorerPoints}', color: scheme.primary),
            ],
          ],
        ),
      ),
    );
  }
}
