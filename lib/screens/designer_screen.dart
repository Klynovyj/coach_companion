import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../models/designer_data.dart';
import '../models/enums.dart';
import '../models/match.dart';
import '../models/match_event.dart';
import '../models/player.dart';
import '../state/app_state.dart';
import '../widgets/team_logo.dart';
import 'startelf_graphic_screen.dart';

/// Zentraler Designer (Mehr → Designer): Grafiken unabhängig von Spieltag/
/// Startelf/Ergebnis gestalten – Tor, Spieler des Spiels, Anlass oder frei –
/// mit allen Funktionen des Grafik-Editors. Darunter „Meine Designs".
class DesignerScreen extends StatefulWidget {
  const DesignerScreen({super.key});

  @override
  State<DesignerScreen> createState() => _DesignerScreenState();
}

class _DesignerScreenState extends State<DesignerScreen> {
  late final AppState _app = context.read<AppState>();
  List<Map<String, Object?>> _designs = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _app.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    _app.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    final list = await _app.designerDesigns();
    if (!mounted) return;
    setState(() {
      _designs = list;
      _loading = false;
    });
  }

  // ------------------------------------------------------------- Öffnen

  /// Editor für [d] öffnen (neu oder gespeichert).
  Future<void> _openEditor(DesignerData d) async {
    final team = _app.ownTeam;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => StartelfGraphicScreen(
          teamName: team?.name ?? 'Mein Verein',
          teamLogo: team?.logoPath,
          teamId: team?.id,
          matchId: d.matchId,
          starters: const [],
          benchNames: const [],
          matchDate: d.matchDate,
          isHome: d.isHome,
          opponentName: d.opponentName,
          opponentLogo: d.opponentLogo,
          announcement: const AnnouncementData(),
          designer: d,
        ),
      ),
    );
    await _reload();
  }

  /// Gespeichertes Design aus der Liste öffnen.
  Future<void> _openSaved(Map<String, Object?> row) async {
    final id = row['id'] as String;
    final json = await _app.loadAnnouncementDesign(id);
    DesignerData? d;
    if (json != null) {
      try {
        d = DesignerData.fromJson(
          (jsonDecode(json) as Map<String, dynamic>)['designer'],
        );
      } catch (_) {}
    }
    d ??= DesignerData(
      id: id,
      template: (row['kind'] as String?) ?? 'free',
      title: (row['title'] as String?) ?? '',
      matchId: row['match_id'] as String?,
    );
    // Titel aus der Liste ist maßgeblich (evtl. dort umbenannt).
    final listTitle = (row['title'] as String?)?.trim() ?? '';
    if (listTitle.isNotEmpty) d = d.copyWith(title: listTitle);
    if (!mounted) return;
    await _openEditor(d);
  }

  String _newId() => 'designer:${const Uuid().v4()}';

  // ------------------------------------------------------------ Vorlagen

  Future<void> _create(String template) async {
    final d = switch (template) {
      'goal' => await _wizardGoal(),
      'motm' => await _wizardMotm(),
      'occasion' => await _wizardOccasion(),
      'fupa' => await _wizardFupa(),
      _ => DesignerData(
        id: _newId(),
        template: 'free',
        title: 'Freies Design ${DateFormat('dd.MM.').format(DateTime.now())}',
      ),
    };
    if (d == null || !mounted) return;
    await _openEditor(d);
  }

  /// Tor: Spiel wählen → eigenes Tor wählen → Angaben prüfen/ändern.
  Future<DesignerData?> _wizardGoal() async {
    final match = await _pickMatch(onlyWithGoals: true);
    if (match == null || !mounted) return null;
    final team = _app.ownTeam;
    final events = await _app.eventsOf(match.id);
    final players = team == null ? <Player>[] : await _app.playersOf(team.id);
    // Alle Tore nach Minute: wer hat getroffen (eigenes Team?).
    final goals = <({MatchEvent e, bool own})>[];
    for (final e in events) {
      final isOwnTeam = team != null && e.teamId == team.id;
      if (e.type == MatchEventType.goal || e.type == MatchEventType.penalty) {
        goals.add((e: e, own: isOwnTeam));
      } else if (e.type == MatchEventType.ownGoal) {
        goals.add((e: e, own: !isOwnTeam)); // Eigentor zählt für die anderen
      }
    }
    goals.sort((a, b) => a.e.minute.compareTo(b.e.minute));
    final ownGoalIdx = [
      for (var i = 0; i < goals.length; i++)
        if (goals[i].own && goals[i].e.type != MatchEventType.ownGoal) i,
    ];
    if (!mounted) return null;
    if (ownGoalIdx.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('In diesem Spiel gibt es keine eigenen Tore.'),
        ),
      );
      return null;
    }
    Player? playerOf(String? id) =>
        id == null ? null : players.where((p) => p.id == id).firstOrNull;
    final scoreList = [for (final g in goals) (minute: g.e.minute, own: g.own)];
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text(
                'Welches Tor?',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            for (final i in ownGoalIdx)
              () {
                final g = goals[i];
                final p = playerOf(g.e.playerId);
                final s = scoreAfterGoal(scoreList, i);
                return ListTile(
                  leading: CircleAvatar(child: Text("${g.e.minute}'")),
                  title: Text(p?.fullName ?? 'Torschütze unbekannt'),
                  subtitle: Text('Stand danach ${s.own}:${s.opp}'),
                  onTap: () => Navigator.pop(ctx, i),
                );
              }(),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return null;
    final g = goals[picked];
    final p = playerOf(g.e.playerId);
    final s = scoreAfterGoal(scoreList, picked);
    final home = match.venue == Venue.home;
    final stand = home ? '${s.own}:${s.opp}' : '${s.opp}:${s.own}';
    final name = p?.fullName ?? '';
    final edited = await _editFields(
      title: 'Tor – Angaben',
      fields: {
        'Torschütze': name,
        'Minute': '${g.e.minute}',
        'Spielstand': stand,
      },
    );
    if (edited == null) return null;
    final n = edited['Torschütze']!.trim();
    final short = scorerShortName(n);
    final info = [
      if (short.isNotEmpty) short,
      if (edited['Minute']!.trim().isNotEmpty) "${edited['Minute']!.trim()}'",
      if (edited['Spielstand']!.trim().isNotEmpty) edited['Spielstand']!.trim(),
    ].join(' · ');
    return DesignerData(
      id: _newId(),
      template: 'goal',
      title: 'Tor ${n.isEmpty ? '' : '$n '}vs ${match.opponentName}'.trim(),
      headline: 'TOR!',
      infoLine: info,
      matchId: match.id,
      playerPhoto: p?.photoPath,
      opponentName: match.opponentName,
      opponentLogo: match.opponentLogoPath,
      isHome: home,
      matchDate: match.kickoff,
    );
  }

  /// Spieler des Spiels: Spiel wählen → Spieler wählen.
  /// FuPa-Foto: Spieler wählen → Editor im FuPa-Format (960×1200), dort
  /// Foto aufnehmen und freistellen; fertig → als Spielerfoto übernehmen.
  Future<DesignerData?> _wizardFupa() async {
    final p = await _pickPlayer(title: 'FuPa-Foto für');
    if (p == null || !mounted) return null;
    return DesignerData(
      id: _newId(),
      template: 'fupa',
      title: 'FuPa ${p.fullName}',
      playerId: p.id,
    );
  }

  Future<DesignerData?> _wizardMotm() async {
    final match = await _pickMatch(onlyWithGoals: false);
    if (match == null || !mounted) return null;
    final p = await _pickPlayer(title: 'Spieler des Spiels');
    if (p == null || !mounted) return null;
    final home = match.venue == Venue.home;
    final finished = match.status == MatchStatus.finished;
    final info = [
      p.fullName.toUpperCase(),
      if (finished)
        '${match.ownScore}:${match.opponentScore} gegen '
            '${match.opponentName.toUpperCase()}'
      else
        'gegen ${match.opponentName.toUpperCase()}',
    ].join(' · ');
    return DesignerData(
      id: _newId(),
      template: 'motm',
      title: 'Spieler des Spiels ${p.fullName}',
      headline: 'SPIELER DES SPIELS',
      infoLine: info,
      matchId: match.id,
      playerPhoto: p.photoPath,
      opponentName: match.opponentName,
      opponentLogo: match.opponentLogoPath,
      isHome: home,
      matchDate: match.kickoff,
    );
  }

  /// Anlass: Anlass wählen → optional Spieler.
  Future<DesignerData?> _wizardOccasion() async {
    const occasions = <(String, String)>[
      ('Geburtstag', 'HAPPY BIRTHDAY'),
      ('Neuzugang', 'WILLKOMMEN'),
      ('Vertragsverlängerung', 'VERLÄNGERT'),
      ('Gute Besserung', 'GUTE BESSERUNG'),
      ('Eigener Anlass', ''),
    ];
    final occ = await showModalBottomSheet<(String, String)>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text(
                'Welcher Anlass?',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            for (final o in occasions)
              ListTile(
                leading: const Icon(Icons.celebration_outlined),
                title: Text(o.$1),
                subtitle: o.$2.isEmpty
                    ? const Text('Überschrift selbst wählen')
                    : Text(o.$2),
                onTap: () => Navigator.pop(ctx, o),
              ),
          ],
        ),
      ),
    );
    if (occ == null || !mounted) return null;
    var headline = occ.$2;
    if (headline.isEmpty) {
      final e = await _editFields(
        title: 'Eigener Anlass',
        fields: {'Überschrift': ''},
      );
      if (e == null) return null;
      headline = e['Überschrift']!.trim().toUpperCase();
    }
    if (!mounted) return null;
    final p = await _pickPlayer(title: 'Für wen? (optional)', optional: true);
    if (!mounted) return null;
    return DesignerData(
      id: _newId(),
      template: 'occasion',
      title: '${occ.$1}${p == null ? '' : ' ${p.fullName}'}',
      headline: headline,
      infoLine: p?.fullName.toUpperCase() ?? '',
      playerPhoto: p?.photoPath,
    );
  }

  // ------------------------------------------------------------ Auswahl

  /// Spiel wählen (neueste zuerst). [onlyWithGoals] → nur Spiele mit eigenen
  /// Toren bzw. laufende/beendete Spiele.
  Future<GameMatch?> _pickMatch({required bool onlyWithGoals}) {
    final now = DateTime.now();
    final list =
        _app.matches
            .where(
              (m) => onlyWithGoals
                  ? (m.status != MatchStatus.scheduled && m.ownScore > 0)
                  : (m.kickoff == null ||
                        m.kickoff!.isBefore(now.add(const Duration(days: 1)))),
            )
            .toList()
          ..sort(
            (a, b) => (b.kickoff ?? DateTime(2000)).compareTo(
              a.kickoff ?? DateTime(2000),
            ),
          );
    if (list.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            onlyWithGoals
                ? 'Noch keine Spiele mit eigenen Toren.'
                : 'Noch keine Spiele vorhanden.',
          ),
        ),
      );
      return Future.value(null);
    }
    return showModalBottomSheet<GameMatch>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.7,
          ),
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(
                title: Text(
                  'Welches Spiel?',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              for (final m in list)
                ListTile(
                  leading: SizedBox(
                    width: 36,
                    height: 36,
                    child: m.opponentLogoPath != null
                        ? TeamLogo(logoPath: m.opponentLogoPath, size: 36)
                        : const Icon(Icons.sports_soccer),
                  ),
                  title: Text('vs ${m.opponentName}'),
                  subtitle: Text(
                    [
                      if (m.kickoff != null)
                        DateFormat(
                          'EEE, dd.MM.yyyy',
                          'de_DE',
                        ).format(m.kickoff!.toLocal()),
                      if (m.status != MatchStatus.scheduled)
                        '${m.ownScore}:${m.opponentScore}',
                    ].join(' · '),
                  ),
                  onTap: () => Navigator.pop(ctx, m),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Spieler aus dem Kader wählen. [optional] → zusätzlich „Ohne Spieler".
  Future<Player?> _pickPlayer({
    required String title,
    bool optional = false,
  }) async {
    final team = _app.ownTeam;
    if (team == null) return null;
    final players =
        (await _app.playersOf(
            team.id,
            onlyActive: true,
          )).where((p) => !p.isStaffOnly).toList()
          ..sort((a, b) => a.fullName.compareTo(b.fullName));
    if (!mounted) return null;
    return showModalBottomSheet<Player>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.7,
          ),
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                title: Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              if (optional)
                ListTile(
                  leading: const Icon(Icons.person_off_outlined),
                  title: const Text('Ohne Spieler'),
                  onTap: () => Navigator.pop(ctx),
                ),
              for (final p in players)
                ListTile(
                  leading: SizedBox(
                    width: 36,
                    height: 36,
                    child: p.photoPath != null
                        ? ClipOval(
                            child: TeamLogo(logoPath: p.photoPath, size: 36),
                          )
                        : const Icon(Icons.person),
                  ),
                  title: Text(p.fullName),
                  subtitle: p.number != null ? Text('#${p.number}') : null,
                  onTap: () => Navigator.pop(ctx, p),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Kleiner Dialog mit Textfeldern (vorbelegt, änderbar). null = abgebrochen.
  Future<Map<String, String>?> _editFields({
    required String title,
    required Map<String, String> fields,
  }) {
    final ctrls = {
      for (final e in fields.entries)
        e.key: TextEditingController(text: e.value),
    };
    return showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final e in ctrls.entries) ...[
                TextField(
                  controller: e.value,
                  decoration: InputDecoration(
                    labelText: e.key,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, {
              for (final e in ctrls.entries) e.key: e.value.text,
            }),
            child: const Text('Weiter'),
          ),
        ],
      ),
    );
  }

  // ----------------------------------------------------- Liste verwalten

  Future<void> _renameSaved(Map<String, Object?> row) async {
    final ctrl = TextEditingController(text: (row['title'] as String?) ?? '');
    final t = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Design umbenennen'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
    if (t == null || t.trim().isEmpty) return;
    await _app.renameAnnouncementDesign(row['id'] as String, t.trim());
  }

  Future<void> _deleteSaved(Map<String, Object?> row) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Design löschen?'),
        content: Text(
          '„${(row['title'] as String?) ?? 'Design'}" wird gelöscht – auch auf '
          'den anderen Geräten. Das lässt sich nicht rückgängig machen.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _app.deleteAnnouncementDesign(row['id'] as String);
  }

  // ------------------------------------------------------------- Aufbau

  @override
  Widget build(BuildContext context) {
    const templates = <(String, IconData, String, String)>[
      ('goal', Icons.sports_soccer, 'Tor', 'Foto + Torschütze, Minute, Stand'),
      (
        'motm',
        Icons.emoji_events_outlined,
        'Spieler des Spiels',
        'Foto + Name, Ergebnis',
      ),
      (
        'occasion',
        Icons.celebration_outlined,
        'Anlass',
        'Geburtstag, Neuzugang …',
      ),
      (
        'fupa',
        Icons.portrait_outlined,
        'FuPa-Foto',
        'Spieler freistellen · 960×1200',
      ),
      (
        'free',
        Icons.brush_outlined,
        'Freies Design',
        'Eigenes Foto, eigene Texte',
      ),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Designer')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Text('Neu erstellen', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (ctx, c) {
              final cols = c.maxWidth > 700 ? 4 : 2;
              final w = (c.maxWidth - (cols - 1) * 10) / cols;
              return Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final t in templates)
                    SizedBox(
                      width: w,
                      child: Card(
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () => _create(t.$1),
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(t.$2, size: 30),
                                const SizedBox(height: 8),
                                Text(
                                  t.$3,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 15,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  t.$4,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Theme.of(ctx).hintColor,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 20),
          Text('Meine Designs', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else if (_designs.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                'Noch keine Designs. Oben eine Vorlage wählen – fertige Grafiken '
                'erscheinen hier und lassen sich jederzeit weiterbearbeiten.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).hintColor),
              ),
            )
          else
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [for (final d in _designs) _designTile(d)],
            ),
        ],
      ),
    );
  }

  Widget _designTile(Map<String, Object?> row) {
    final thumb = TeamLogo.decode(row['thumb'] as String?);
    final title = (row['title'] as String?) ?? 'Design';
    final kind = DesignerData.labelOf((row['kind'] as String?) ?? 'free');
    final at = DateTime.tryParse((row['updated_at'] as String?) ?? '');
    return SizedBox(
      width: 150,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _openSaved(row),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AspectRatio(
                aspectRatio: 9 / 12,
                child: thumb != null
                    ? Image.memory(
                        thumb,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                      )
                    : ColoredBox(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHighest,
                        child: const Icon(Icons.image_outlined, size: 40),
                      ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 0, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 12.5,
                            ),
                          ),
                          Text(
                            [
                              kind,
                              if (at != null)
                                DateFormat('dd.MM.').format(at.toLocal()),
                            ].join(' · '),
                            style: TextStyle(
                              fontSize: 11,
                              color: Theme.of(context).hintColor,
                            ),
                          ),
                        ],
                      ),
                    ),
                    PopupMenuButton<String>(
                      padding: EdgeInsets.zero,
                      onSelected: (v) {
                        if (v == 'rename') _renameSaved(row);
                        if (v == 'delete') _deleteSaved(row);
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: 'rename',
                          child: Text('Umbenennen'),
                        ),
                        PopupMenuItem(value: 'delete', child: Text('Löschen')),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
