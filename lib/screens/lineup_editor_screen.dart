import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/enums.dart';
import '../models/lineup.dart';
import '../models/match.dart';
import '../models/player.dart';
import '../models/player_stat.dart';
import '../services/share_service.dart';
import '../state/app_state.dart';
import '../widgets/pitch_field.dart';
import '../widgets/player_avatar.dart';
import 'nomination_screen.dart';
import 'startelf_graphic_screen.dart';

/// Aufstellungs-Editor mit frei bespielbarem Feld (Spieler überall platzieren).
/// Auswahl kommt aus den zugesagten Spielern. Die Formation dient nur als
/// Startanordnung – danach verschiebst du alles frei.
class LineupEditorScreen extends StatefulWidget {
  const LineupEditorScreen({
    super.key,
    required this.matchId,
    required this.teamId,
    required this.teamName,
    this.lineupId,
    this.readOnly = false,
  });

  final String matchId;
  final String teamId;
  final String teamName;

  /// Bestimmte Aufstellung öffnen (statt der eigenen). Für Ansehen fremder.
  final String? lineupId;

  /// Nur ansehen (fremde Aufstellung) – keine Bearbeitung/Speichern.
  final bool readOnly;

  @override
  State<LineupEditorScreen> createState() => _LineupEditorScreenState();
}

class _LineupEditorScreenState extends State<LineupEditorScreen> {
  // Interne Standard-Formation nur für die Default-Position beim Einteilen
  // über die Liste (kein UI-Auswahlfeld mehr – es wird frei platziert).
  static const _defaultFormation = '4-4-2';

  final GlobalKey _pitchKey = GlobalKey();
  final GlobalKey _boundaryKey = GlobalKey(); // Feld-Grafik zum Teilen

  Lineup? _lineup;
  String _formation = '4-4-2';
  final Map<String, Player> _byId = {};
  // Abweichende Rückennummern für dieses Spiel (Spieler-ID → Nummer).
  Map<String, int> _matchNumbers = {};
  GameMatch? _match;
  // FuPa-Saisonstatistik je Spieler (für die Spielminuten), nach dedupKey.
  Map<String, PlayerStat> _statByKey = {};
  List<Player> _nominated = [];
  final Map<String, Offset> _starters = {}; // playerId -> relative Position
  final Set<String> _bench = {};
  bool _loading = true;
  bool _restricted = false;
  // Start immer in der Listen-Ansicht (wie SpielerPlus): erst Start/Bank
  // einteilen, danach im Feld frei anordnen.
  bool _listMode = true;

  late final AppState _app = context.read<AppState>();

  @override
  void initState() {
    super.initState();
    // Bewusst KEIN AppState-Listener: der Editor ist eine lokale Bearbeitungs-
    // Sitzung. Würde er bei jeder Cloud-/Realtime-Benachrichtigung neu laden,
    // überschriebe er die noch nicht gespeicherten Start/Bank-Änderungen – dann
    // „reagiert" das Verschieben erst nach mehreren Versuchen. Reload passiert
    // nur gezielt (Start, Rückkehr aus der Nominierung).
    _load();
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    final lineup = widget.lineupId != null
        ? (await state.getLineupById(widget.lineupId!) ??
              await state.ensureLineup(widget.matchId, widget.teamId))
        : await state.ensureLineup(widget.matchId, widget.teamId);
    // Reines Trainerteam steht nicht in der Aufstellung (spielender Co-Trainer schon).
    final players = (await state.playersOf(
      widget.teamId,
    )).where((p) => !p.isStaffOnly).toList();
    final noms = await state.nominationsOf(widget.matchId);
    final entries = await state.lineupEntries(lineup.id);
    final matchNumbers = await state.matchNumbers(widget.matchId);
    final match = await state.getMatch(widget.matchId);
    final statsList = await state.statsOf(widget.teamId);
    final statByKey = <String, PlayerStat>{
      for (final s in statsList)
        '${s.firstName.trim().toLowerCase()}|${s.lastName.trim().toLowerCase()}':
            s,
    };

    // Zugesagte UND „unter Vorbehalt" nominierte Spieler stehen zur Aufstellung
    // zur Verfügung.
    final nominated = players
        .where(
          (p) =>
              noms[p.id] == NominationStatus.zugesagt ||
              noms[p.id] == NominationStatus.unterVorbehalt,
        )
        .toList();
    final pool = nominated.isEmpty ? players : nominated;
    final slots = slotsForFormation(lineup.formation);

    if (!mounted) return;
    setState(() {
      _lineup = lineup;
      _formation = lineup.formation;
      _byId
        ..clear()
        ..addEntries(players.map((p) => MapEntry(p.id, p)));
      _nominated = pool;
      _matchNumbers = matchNumbers;
      _match = match;
      _statByKey = statByKey;
      _restricted = nominated.isNotEmpty;
      _starters.clear();
      _bench.clear();
      var idx = 0;
      for (final e in entries) {
        if (!_byId.containsKey(e.playerId)) continue;
        if (e.role == LineupRole.starter) {
          final x = e.posX;
          final y = e.posY;
          if (x != null && y != null) {
            _starters[e.playerId] = Offset(x, y);
          } else {
            // Altbestand ohne Position -> auf Formations-Slot setzen.
            final s = idx < slots.length ? slots[idx] : null;
            _starters[e.playerId] = s != null
                ? Offset(s.x, s.y)
                : const Offset(0.5, 0.5);
          }
          idx++;
        } else if (e.role == LineupRole.substitute) {
          _bench.add(e.playerId);
        }
      }
      // Nominierung ist maßgeblich: steht sie fest (zugesagt/unter Vorbehalt),
      // dürfen nur nominierte Spieler in Start/Bank stehen. Früher platzierte,
      // inzwischen nicht mehr nominierte Spieler fliegen hier raus – sonst zeigen
      // Feld, Liste und Startelf-Grafik „falsche" Spieler, die die Nominierung
      // längst entfernt hat. (Ohne Zusagen bleibt alles, da dann der ganze Kader
      // zur Verfügung steht.)
      if (nominated.isNotEmpty) {
        final allowed = {for (final p in nominated) p.id};
        _starters.removeWhere((pid, _) => !allowed.contains(pid));
        _bench.removeWhere((pid) => !allowed.contains(pid));
      }
      _loading = false;
    });
  }

  List<Player> get _pool => _nominated
      .where((p) => !_starters.containsKey(p.id) && !_bench.contains(p.id))
      .toList();

  void _removeEverywhere(String pid) {
    _starters.remove(pid);
    _bench.remove(pid);
  }

  void _placeAt(String pid, Offset rel) {
    setState(() {
      _bench.remove(pid);
      _starters[pid] = Offset(
        rel.dx.clamp(0.05, 0.95),
        rel.dy.clamp(0.05, 0.95),
      );
    });
  }

  void _toBench(String pid) => setState(() {
    _removeEverywhere(pid);
    _bench.add(pid);
  });

  void _toPool(String pid) => setState(() => _removeEverywhere(pid));

  /// Position eines Drop-Punkts (global) in relative Feldkoordinaten.
  Offset? _relFromGlobal(Offset global) {
    final box = _pitchKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return null;
    final local = box.globalToLocal(global);
    return Offset(local.dx / box.size.width, local.dy / box.size.height);
  }

  /// Fügt einen Spieler (aus der Liste) als Starter an einer freien Position ein.
  void _addStarterDefault(String pid) {
    final slots = slotsForFormation(_defaultFormation);
    final idx = _starters.length;
    final pos = idx < slots.length
        ? Offset(slots[idx].x, slots[idx].y)
        : const Offset(0.5, 0.5);
    setState(() {
      _bench.remove(pid);
      _starters[pid] = pos;
    });
  }

  /// Aus der Ansehen-Ansicht eine eigene Kopie der (fremden) Aufstellung
  /// erstellen und bearbeitbar weitermachen.
  Future<void> _duplicatePlan() async {
    final orig = _lineup;
    if (orig == null) return;
    final navigator = Navigator.of(context);
    final base = orig.name?.trim();
    final copy = await _app.createLineup(
      widget.matchId,
      widget.teamId,
      name: 'Kopie von ${(base != null && base.isNotEmpty) ? base : 'Aufstellung'}',
      copyFrom: orig,
    );
    if (!mounted) return;
    navigator.pushReplacement(
      MaterialPageRoute(
        builder: (_) => LineupEditorScreen(
          matchId: widget.matchId,
          teamId: widget.teamId,
          teamName: widget.teamName,
          lineupId: copy.id,
          readOnly: false,
        ),
      ),
    );
  }

  Future<void> _save() async {
    final lineup = _lineup!;
    final entries = <LineupEntry>[];
    var i = 0;
    // Deterministische Eintrags-ID pro (Aufstellung, Spieler): erneutes Speichern
    // upsertet in-place, nur wirklich entnommene Spieler gelten als „entfernt".
    _starters.forEach((pid, pos) {
      entries.add(
        LineupEntry(
          id: 'le_${lineup.id}_$pid',
          lineupId: lineup.id,
          playerId: pid,
          role: LineupRole.starter,
          orderIndex: i++,
          posX: pos.dx,
          posY: pos.dy,
        ),
      );
    });
    for (final pid in _bench) {
      entries.add(
        LineupEntry(
          id: 'le_${lineup.id}_$pid',
          lineupId: lineup.id,
          playerId: pid,
          role: LineupRole.substitute,
          orderIndex: 100 + i++,
        ),
      );
    }
    await context.read<AppState>().saveLineup(
      lineup.copyWith(formation: _formation),
      entries,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Aufstellung gespeichert.')));
    Navigator.pop(context);
  }

  Future<void> _resetLineup() async {
    final state = context.read<AppState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Aufstellung zurücksetzen?'),
        content: const Text(
          'Alle Spieler werden vom Feld und der Bank entfernt.',
        ),
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
    if (ok != true) return;
    setState(() {
      _starters.clear();
      _bench.clear();
    });
    // Leere Aufstellung speichern, damit der Reset auch persistent ist.
    await state.saveLineup(_lineup!.copyWith(formation: _formation), const []);
  }

  /// Teilt – in der Feld-Ansicht die Aufstellungs-Grafik, in der Liste den
  /// Kader als Text (Namen alphabetisch) via WhatsApp.
  Future<void> _shareLineup() async {
    if (_listMode) {
      // Zwei Varianten: Trainer (mit Start/Bank) oder Mannschaft (nur Infos).
      final who = await showModalBottomSheet<String>(
        context: context,
        builder: (_) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Kader teilen',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.sports),
                title: const Text('Für Trainer-Kollegen'),
                subtitle: const Text('Mit Startelf und Ersatzbank'),
                onTap: () => Navigator.pop(context, 'trainer'),
              ),
              ListTile(
                leading: const Icon(Icons.groups),
                title: const Text('Für die Mannschaft'),
                subtitle: const Text('Nur Kader & Infos – ohne Start/Bank'),
                onTap: () => Navigator.pop(context, 'team'),
              ),
              ListTile(
                leading: const Icon(Icons.image),
                title: const Text('Als Grafik (Story/Post)'),
                subtitle: const Text(
                  'Startelf-Bild mit Sponsoren für Instagram/WhatsApp',
                ),
                onTap: () => Navigator.pop(context, 'graphic'),
              ),
            ],
          ),
        ),
      );
      if (who == 'trainer') {
        await shareViaWhatsApp(_squadText());
      } else if (who == 'team' && mounted) {
        await _shareForTeam();
      } else if (who == 'graphic' && mounted) {
        await _shareAsGraphic();
      }
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    try {
      final boundary =
          _boundaryKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) return;
      final image = await boundary.toImage(pixelRatio: 3);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return;
      final savedPath = await shareOrSaveImage(
        data.buffer.asUint8List(),
        'Aufstellung_${widget.teamName}',
        text: 'Aufstellung – ${widget.teamName}',
      );
      if (savedPath != null && mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: Text('Als Bild gespeichert und geöffnet:\n$savedPath'),
            duration: const Duration(seconds: 6),
          ),
        );
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Teilen fehlgeschlagen: $e')),
      );
    }
  }

  /// Öffnet die Startelf-Grafik (Instagram-Format) mit Startelf + Bank und den
  /// hinterlegten Sponsoren. Spieler nach Rückennummer sortiert.
  Future<void> _shareAsGraphic() async {
    final team = _app.ownTeam;
    int? numOf(String id) => _matchNumbers[id] ?? _byId[id]?.number;
    // Torwart erkennen (Positionsliste „TW" oder Freitext „Tor…/Keeper").
    bool isGk(Player p) {
      if (p.positions.any((x) => x.toUpperCase() == 'TW')) return true;
      final pos = (p.position ?? '').toLowerCase();
      return pos.contains('tor') || pos == 'tw' || pos.contains('keeper');
    }

    int byNumber(String a, String b) {
      final na = numOf(a), nb = numOf(b);
      if (na == null && nb == null) {
        return _byId[a]!.fullName.compareTo(_byId[b]!.fullName);
      }
      if (na == null) return 1; // ohne Nummer nach hinten
      if (nb == null) return -1;
      return na.compareTo(nb);
    }

    // Startelf: Torwart zuerst, danach nach Rückennummer.
    final starterIds = _starters.keys.where(_byId.containsKey).toList()
      ..sort((a, b) {
        final ga = isGk(_byId[a]!), gb = isGk(_byId[b]!);
        if (ga != gb) return ga ? -1 : 1;
        return byNumber(a, b);
      });
    final benchIds = _bench.where(_byId.containsKey).toList()..sort(byNumber);
    final starters = [
      for (final id in starterIds)
        StartelfPlayer(
          numOf(id),
          _byId[id]!.fullName,
          position: isGk(_byId[id]!) ? 'Torwart' : null,
        ),
    ];
    final bench = [for (final id in benchIds) _byId[id]!.fullName];
    // Spielinfos (Datum/Heim-Auswärts/Gegner) fürs Grafik-Banner.
    final match = await _app.getMatch(widget.matchId);
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => StartelfGraphicScreen(
          // Offizieller (voller) Name als Default-Titel; in der Grafik frei
          // anpassbar.
          teamName: team?.name ?? widget.teamName,
          teamLogo: team?.logoPath,
          starters: starters,
          benchNames: bench,
          matchDate: match?.kickoff,
          isHome: match?.venue == Venue.home,
          opponentName: match?.opponentName ?? '',
          opponentLogo: match?.opponentLogoPath,
        ),
      ),
    );
  }

  /// Kader als Text: Startelf + Ersatzbank, Namen alphabetisch sortiert.
  String _squadText() {
    List<String> names(Iterable<String> ids) =>
        ids
            .where(_byId.containsKey)
            .map((id) => _byId[id]!.shortOrFullName)
            .toList()
          ..sort();
    final start = names(_starters.keys);
    final bench = names(_bench);
    final b = StringBuffer();
    b.writeln('Kader – ${widget.teamName}');
    if (start.isNotEmpty) {
      b.writeln('\nStartelf (${start.length}):');
      b.writeln(start.join('\n'));
    }
    if (bench.isNotEmpty) {
      b.writeln('\nErsatzbank (${bench.length}):');
      b.writeln(bench.join('\n'));
    }
    return b.toString().trim();
  }

  /// Alle Spieler des Kaders (Start + Bank) – alphabetisch, ohne Unterscheidung.
  List<String> _allSquadNames() {
    final ids = {..._starters.keys, ..._bench};
    return ids
        .where(_byId.containsKey)
        .map((id) => _byId[id]!.shortOrFullName)
        .toList()
      ..sort();
  }

  /// Mannschafts-Variante: fragt Spielstätte/Adresse/Treffpunkt ab (gemerkt je
  /// Spiel) und teilt NUR allgemeine Infos – ohne Start/Bank.
  Future<void> _shareForTeam() async {
    final state = context.read<AppState>();
    final match = await state.getMatch(widget.matchId);
    final info = await state.matchShareInfo(widget.matchId);
    if (!mounted) return;
    final venueCtrl = TextEditingController(text: info['venue'] ?? '');
    final addrCtrl = TextEditingController(text: info['address'] ?? '');
    final treffCtrl = TextEditingController(text: info['treff'] ?? '');
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Infos für die Mannschaft',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Start/Bank wird nicht geteilt.',
                  style: TextStyle(fontSize: 12.5, color: Colors.grey),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: venueCtrl,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Spielstätte',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: addrCtrl,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Adresse / Anfahrt',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: treffCtrl,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Treffpunkt (Ort/Zeit)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () => Navigator.pop(ctx, true),
                  icon: const Icon(Icons.share),
                  label: const Text('An die Mannschaft teilen'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (ok != true || !mounted) return;
    final venue = venueCtrl.text.trim();
    final addr = addrCtrl.text.trim();
    final treff = treffCtrl.text.trim();
    await state.saveMatchShareInfo(widget.matchId, {
      'venue': venue,
      'address': addr,
      'treff': treff,
    });
    await shareViaWhatsApp(_teamShareText(match, venue, addr, treff));
  }

  String _teamShareText(
    GameMatch? match,
    String venue,
    String addr,
    String treff,
  ) {
    final df = DateFormat('EEEE, dd.MM.yyyy · HH:mm', 'de_DE');
    final b = StringBuffer();
    b.writeln('${widget.teamName} – Infos zum Spiel');
    if (match != null) {
      b.writeln(
        [
          'gegen ${match.opponentName}',
          match.venue.label,
          if (match.kickoff != null)
            'Anpfiff ${df.format(match.kickoff!.toLocal())}',
        ].join(' · '),
      );
    }
    final names = _allSquadNames();
    if (names.isNotEmpty) {
      b.writeln('\nKader (${names.length}):');
      b.writeln(names.join(', '));
    }
    if (venue.isNotEmpty) b.writeln('\nSpielstätte: $venue');
    if (addr.isNotEmpty) b.writeln('Adresse: $addr');
    if (treff.isNotEmpty) b.writeln('Treffpunkt: $treff');
    return b.toString().trim();
  }

  Future<void> _openNomination() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => NominationScreen(
          matchId: widget.matchId,
          teamId: widget.teamId,
          title: widget.teamName,
        ),
      ),
    );
    await _load();
  }

  /// Titel = Plannamen oder Default „Aufstellung".
  String _planTitle() {
    final n = _lineup?.name?.trim();
    return (n != null && n.isNotEmpty) ? n : 'Aufstellung';
  }

  /// Plan direkt im Editor umbenennen (Titel antippen).
  Future<void> _renamePlan() async {
    final lineup = _lineup;
    if (lineup == null) return;
    final ctrl = TextEditingController(text: lineup.name ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Aufstellung umbenennen'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'Name',
            hintText: 'z. B. Plan A offensiv',
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
    if (result == null || !mounted) return;
    await _app.renameLineup(lineup, result);
    if (!mounted) return;
    setState(() {
      _lineup = result.isEmpty
          ? lineup.copyWith(clearName: true)
          : lineup.copyWith(name: result);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final starters = _starters.length;
    return Scaffold(
      appBar: AppBar(
        // Titel nah an den Zurück-Pfeil rücken, damit lange Plannamen Platz
        // haben.
        titleSpacing: 0,
        title: widget.readOnly
            ? Text(_planTitle(), maxLines: 1, overflow: TextOverflow.ellipsis)
            : InkWell(
                onTap: _renamePlan,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        _planTitle(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 18),
                      ),
                    ),
                    const SizedBox(width: 6),
                    const Icon(Icons.edit, size: 15, color: Colors.white70),
                  ],
                ),
              ),
        // Nur Speichern/Duplizieren bleibt sichtbar; Ansicht umschalten, Teilen
        // und Zurücksetzen liegen im ⋮-Menü – so hat der Plannamen oben Platz.
        actions: [
          if (!widget.readOnly)
            TextButton(
              onPressed: _save,
              child: const Text(
                'Speichern',
                style: TextStyle(color: Colors.white),
              ),
            )
          else
            TextButton(
              onPressed: _duplicatePlan,
              child: const Text(
                'Duplizieren',
                style: TextStyle(color: Colors.white),
              ),
            ),
          PopupMenuButton<String>(
            tooltip: 'Mehr',
            onSelected: (v) {
              if (v == 'view') {
                setState(() => _listMode = !_listMode);
              } else if (v == 'share') {
                _shareLineup();
              } else if (v == 'reset') {
                _resetLineup();
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'view',
                child: ListTile(
                  leading: Icon(_listMode ? Icons.grid_view : Icons.view_list),
                  title: Text(_listMode ? 'Feld-Ansicht' : 'Listen-Ansicht'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'share',
                child: ListTile(
                  leading: const Icon(Icons.share),
                  title: Text(_listMode ? 'Kader teilen' : 'Aufstellung teilen'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              if (!widget.readOnly)
                const PopupMenuItem(
                  value: 'reset',
                  child: ListTile(
                    leading: Icon(Icons.restart_alt),
                    title: Text('Zurücksetzen'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
            ],
          ),
        ],
      ),
      body: ListView(
        children: [
          _banner(),
          if (_listMode)
            _listEditor()
          else ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Startelf',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    '$starters/11',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: starters == 11
                          ? Colors.green.shade700
                          : Colors.orange.shade800,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: RepaintBoundary(key: _boundaryKey, child: _pitch()),
            ),
            _benchSection(),
            _poolSection(),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _banner() {
    return Container(
      width: double.infinity,
      color: Theme.of(
        context,
      ).colorScheme.primaryContainer.withValues(alpha: 0.4),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(
            Icons.how_to_reg,
            size: 18,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              !_restricted
                  ? 'Noch keine Zusagen – es wird der ganze Kader gezeigt'
                  : _listMode
                  ? 'Erst Start/Bank einteilen – dann im Feld anordnen'
                  : 'Ziehe die Spieler frei auf das Feld',
            ),
          ),
          TextButton(
            onPressed: _openNomination,
            child: const Text('Nominierung'),
          ),
        ],
      ),
    );
  }

  // --------------------------------------------------------------- Feld-Modus
  Widget _pitch() {
    // Responsiv: Feld füllt die verfügbare Breite, Höhe folgt dem
    // Seitenverhältnis – aber gedeckelt an die Viewport-Höhe, damit das ganze
    // Feld auf Mobilgeräten sichtbar bleibt. Spieler-Chips skalieren mit.
    return LayoutBuilder(
      builder: (context, outer) {
        final media = MediaQuery.of(context);
        final maxW = outer.maxWidth.isFinite
            ? outer.maxWidth
            : media.size.width - 24;
        final maxH = media.size.height * 0.60;
        const ratio = 0.66; // Breite / Höhe
        var w = maxW;
        var h = w / ratio;
        if (h > maxH) {
          h = maxH;
          w = h * ratio;
        }
        final chip = (w * 0.145).clamp(40.0, 58.0);
        final chipH = chip + chip * 0.32;
        return Center(
          child: SizedBox(
            width: w,
            height: h,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Stack(
                key: _pitchKey,
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: PitchFieldPainter(
                        Colors.white.withValues(alpha: 0.85),
                        const Color(0xFF2E7D4F),
                        const Color(0xFF2A744A),
                      ),
                    ),
                  ),
                  // Ganzflächiges Drop-Ziel: Spieler landen dort, wo du loslässt.
                  Positioned.fill(
                    child: DragTarget<String>(
                      onWillAcceptWithDetails: (_) => true,
                      // Live mitziehen: Chip folgt dem Finger, dadurch stufenlos
                      // fein justierbar (nicht erst beim Loslassen springen).
                      onMove: (d) {
                        final rel = _relFromGlobal(d.offset);
                        if (rel != null) _placeAt(d.data, rel);
                      },
                      onAcceptWithDetails: (d) {
                        final rel = _relFromGlobal(d.offset);
                        if (rel != null) _placeAt(d.data, rel);
                      },
                      builder: (context, cand, rej) => const SizedBox.expand(),
                    ),
                  ),
                  for (final entry in _starters.entries)
                    if (_byId.containsKey(entry.key))
                      Positioned(
                        // Anker = Avatar-Mitte (chip/2); muss mit dem Greif-Anker
                        // im _draggable übereinstimmen, sonst springt der Spieler
                        // beim Ablegen um die Labelhöhe nach oben.
                        left: entry.value.dx * w - chip / 2,
                        top: entry.value.dy * h - chip / 2,
                        width: chip,
                        height: chipH,
                        child: _draggable(
                          _byId[entry.key]!,
                          _pitchChip(_byId[entry.key]!, chip),
                          anchor: chip / 2,
                        ),
                      ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _pitchChip(Player p, double chip) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        PlayerAvatar(player: p, radius: chip * 0.38),
        Container(
          margin: const EdgeInsets.only(top: 2),
          padding: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            p.pitchName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white,
              fontSize: (chip * 0.19).clamp(8.0, 12.0),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  /// Draggable mit pointer-Anker: Drop-Punkt = Zeigerposition. Antippen (ohne
  /// Ziehen) zeigt die Spieler-Info.
  Widget _draggable(Player p, Widget child, {double anchor = 26}) {
    final tappable = GestureDetector(
      onTap: () => _showPlayerInfo(p),
      child: child,
    );
    if (widget.readOnly) return tappable; // Nur ansehen – kein Ziehen, aber Info.
    return Draggable<String>(
      data: p.id,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Transform.translate(
        offset: Offset(-anchor, -anchor),
        child: Material(color: Colors.transparent, child: child),
      ),
      childWhenDragging: Opacity(opacity: 0.3, child: child),
      child: tappable,
    );
  }

  String _strongFootLabel(String? f) => switch (f) {
    'links' => 'Links',
    'rechts' => 'Rechts',
    'beide' => 'Beide',
    _ => '–',
  };

  /// Info-Dialog zu einem Spieler (Tap in der Aufstellung).
  void _showPlayerInfo(Player p) {
    final stat = _statByKey[p.dedupKey];
    final nr = _numberFor(p);
    final positions = p.positions.isNotEmpty
        ? p.positions.join(', ')
        : (p.position ?? '–');
    final suspended =
        _match != null && _app.isSuspendedForMatch(p, _match!);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            PlayerAvatar(player: p, radius: 20),
            const SizedBox(width: 10),
            Expanded(child: Text(p.fullName)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (suspended)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  '⛔ Gesperrt für dieses Spiel',
                  style: TextStyle(
                    color: Colors.red,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            _infoRow('Nummer', nr != null ? '$nr' : '–'),
            _infoRow('Position', positions),
            if (p.wishPosition != null && p.wishPosition!.isNotEmpty)
              _infoRow('Wunschposition', p.wishPosition!),
            _infoRow('Starker Fuß', _strongFootLabel(p.strongFoot)),
            if (stat != null) _infoRow('Saison', '${stat.minutes} Min'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Schließen'),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 120,
          child: Text(
            label,
            style: TextStyle(color: Theme.of(context).hintColor),
          ),
        ),
        Expanded(
          child: Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
      ],
    ),
  );

  Widget _benchSection() => _dropZone(
    title: 'Ersatzbank',
    empty: 'Spieler hierher ziehen',
    players: _bench.where(_byId.containsKey).map((id) => _byId[id]!).toList(),
    onAccept: _toBench,
    highlightColor: Theme.of(context).colorScheme.secondaryContainer,
  );

  Widget _poolSection() => _dropZone(
    title: 'Verfügbar',
    empty: 'Alle zugesagten Spieler sind eingeteilt.',
    players: _pool,
    onAccept: _toPool,
    highlightColor: Theme.of(context).colorScheme.surfaceContainerHighest,
  );

  Widget _dropZone({
    required String title,
    required String empty,
    required List<Player> players,
    required void Function(String) onAccept,
    required Color highlightColor,
  }) {
    return DragTarget<String>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (d) => onAccept(d.data),
      builder: (context, cand, rej) => Container(
        margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: cand.isNotEmpty
              ? highlightColor
              : Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$title (${players.length})',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            if (players.isEmpty)
              Text(empty, style: const TextStyle(color: Colors.grey))
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: players
                    .map((p) => _draggable(p, _compactChip(p)))
                    .toList(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _compactChip(Player p) {
    final name = p.pitchName;
    return Container(
      constraints: const BoxConstraints(maxWidth: 170),
      padding: const EdgeInsets.fromLTRB(4, 4, 10, 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PlayerAvatar(player: p, radius: 13),
          const SizedBox(width: 6),
          if (_numberFor(p) != null) ...[
            Text(
              '${_numberFor(p)}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------- Listen-Modus
  Widget _listEditor() {
    // Gruppiert wie bei SpielerPlus: Startelf, Ersatzbank, Verfügbar.
    // WICHTIG: Start/Bank zeigen ALLE eingeteilten Spieler – auch solche, die
    // (nicht mehr) nominiert sind. Sonst weicht die Liste von Feld, gespeicherter
    // Aufstellung und der Startelf-Grafik ab (dort wird nur über _byId gefiltert).
    final nomIds = {for (final p in _nominated) p.id};
    List<Player> group(Iterable<String> ids) => [
      // Nominierte zuerst (stabile Reihenfolge), dann eingeteilte Nicht-Nominierte.
      for (final p in _nominated)
        if (ids.contains(p.id)) p,
      for (final id in ids)
        if (_byId.containsKey(id) && !nomIds.contains(id)) _byId[id]!,
    ];
    final starters = group(_starters.keys);
    final bench = group(_bench);
    final available = _pool;
    return Column(
      children: [
        _listGroup('Startelf', starters, countLabel: '${starters.length}/11'),
        _listGroup('Ersatzbank', bench),
        _listGroup(
          'Verfügbar',
          available,
          emptyHint: 'Alle Spieler sind eingeteilt.',
        ),
      ],
    );
  }

  Widget _listGroup(
    String title,
    List<Player> players, {
    String? countLabel,
    String? emptyHint,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
          child: Row(
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                countLabel ?? '${players.length}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        if (players.isEmpty && emptyHint != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
            child: Text(emptyHint, style: const TextStyle(color: Colors.grey)),
          )
        else
          for (final p in players) _listRow(p),
      ],
    );
  }

  /// Rückennummer für dieses Spiel (Override, sonst Standard).
  int? _numberFor(Player p) => _matchNumbers[p.id] ?? p.number;

  /// Antippbare Nummer – pro Spiel änderbar; leer/Standard entfernt den Override.
  Widget _numberChip(Player p) {
    final scheme = Theme.of(context).colorScheme;
    final n = _numberFor(p);
    final overridden = _matchNumbers.containsKey(p.id);
    const accent = Color(0xFFEF6C00);
    return InkWell(
      onTap: widget.readOnly ? null : () => _editNumber(p),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: 30,
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: (overridden ? accent : scheme.primary).withValues(alpha: 0.14),
          shape: BoxShape.circle,
          border: Border.all(
            color: overridden ? accent : scheme.primary.withValues(alpha: 0.4),
            width: overridden ? 1.5 : 1,
          ),
        ),
        child: Text(
          n != null ? '$n' : '–',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: overridden ? accent : scheme.primary,
          ),
        ),
      ),
    );
  }

  /// Spitzname direkt aus der Aufstellung pflegen (leer = entfernen).
  Future<void> _editNickname(Player p) async {
    final ctrl = TextEditingController(text: p.nickname ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Spitzname'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(
            labelText: 'Spitzname',
            hintText: '${p.fullName} (leer = kein Spitzname)',
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
    if (result == null || !mounted) return;
    final state = context.read<AppState>();
    final updated = result.isEmpty
        ? p.copyWith(clearNickname: true)
        : p.copyWith(nickname: result);
    await state.updatePlayer(updated);
    if (mounted) setState(() => _byId[p.id] = updated);
  }

  Future<void> _editNumber(Player p) async {
    final ctrl = TextEditingController(text: _numberFor(p)?.toString() ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nummer für dieses Spiel'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: 'Rückennummer',
            hintText: p.number != null
                ? 'Standard: ${p.number} (leer = Standard)'
                : 'leer = keine',
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
    if (result == null || !mounted) return;
    final state = context.read<AppState>();
    final n = result.isEmpty ? null : int.tryParse(result);
    // Leer oder gleich der Standard-Nummer → Override entfernen.
    if (n == null || n == p.number) {
      await state.setMatchNumber(widget.matchId, p.id, null);
      if (mounted) setState(() => _matchNumbers.remove(p.id));
    } else {
      await state.setMatchNumber(widget.matchId, p.id, n);
      if (mounted) setState(() => _matchNumbers[p.id] = n);
    }
  }

  Widget _listRow(Player p) {
    final isStarter = _starters.containsKey(p.id);
    final onBench = _bench.contains(p.id);
    // Nur Start oder Bank wählbar. Noch nicht eingeteilte (verfügbare) Spieler
    // haben keine Auswahl, bis Start/Bank getippt wird.
    final selected = <String>{if (isStarter) 'start' else if (onBench) 'bank'};
    final stat = _statByKey[p.dedupKey];
    final sub = [
      if (p.position != null && p.position!.isNotEmpty) p.position!,
      if (stat != null) '${stat.minutes} Min',
    ].join('  ·  ');
    return ListTile(
      leading: PlayerAvatar(player: p, radius: 18),
      title: InkWell(
        onTap: widget.readOnly ? null : () => _editNickname(p),
        child: Row(
          children: [
            Flexible(
              child: Text(
                p.shortOrFullName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.edit, size: 12, color: Theme.of(context).hintColor),
            if (_match != null && _app.isSuspendedForMatch(p, _match!)) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.error,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  '⛔',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      subtitle: sub.isEmpty ? null : Text(sub),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _numberChip(p),
          const SizedBox(width: 6),
          SegmentedButton<String>(
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            segments: const [
              ButtonSegment(value: 'start', label: Text('Start')),
              ButtonSegment(value: 'bank', label: Text('Bank')),
            ],
            selected: selected,
            emptySelectionAllowed: true,
            showSelectedIcon: false,
            onSelectionChanged: widget.readOnly
                ? null
                : (s) {
                    if (s.isEmpty) {
                      // Erneutes Tippen auf Start/Bank → raus aus dem Kader
                      // (zurück zu „Verfügbar").
                      _toPool(p.id);
                      return;
                    }
                    final v = s.first;
                    if (v == 'start') {
                      if (!isStarter) _addStarterDefault(p.id);
                    } else if (v == 'bank') {
                      _toBench(p.id);
                    }
                  },
          ),
        ],
      ),
    );
  }
}
