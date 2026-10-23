import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/enums.dart';
import '../models/material_duty_config.dart';
import '../models/player.dart';
import '../services/material_duty.dart';
import '../services/share_service.dart';
import '../state/app_state.dart';
import '../widgets/player_avatar.dart';

/// Ball-/Materialdienst: Spieler in Alters-Gruppen (max. 5), wöchentliche
/// Rotation, Urlaube aus den „Urlaub"-Abwesenheiten markiert.
class MaterialDutyScreen extends StatefulWidget {
  const MaterialDutyScreen({
    super.key,
    required this.teamId,
    required this.teamName,
  });

  final String teamId;
  final String teamName;

  @override
  State<MaterialDutyScreen> createState() => _MaterialDutyScreenState();
}

class _MaterialDutyScreenState extends State<MaterialDutyScreen> {
  static final _dShort = DateFormat('dd.MM.', 'de_DE');
  static final _dLong = DateFormat('dd.MM.yyyy', 'de_DE');

  MaterialDutyConfig? _config;
  List<Player> _players = [];
  List<DutyVacation> _vacations = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    // Inaktive Spieler und das Trainerteam fliegen raus.
    final players = (await state.playersOf(widget.teamId))
        .where((p) =>
            p.active && p.status != PlayerStatus.inaktiv && !p.isStaff)
        .toList();
    final config = await state.materialDutyConfig(widget.teamId);
    final vac = await state.materialDutyVacations(widget.teamId);
    if (!mounted) return;
    setState(() {
      _players = players;
      _config = config;
      _vacations = vac;
      _loading = false;
    });
  }

  // ── abgeleitete Werte ───────────────────────────────────────────────
  List<Player> get _sorted => sortPlayersByBirthDesc(_players);
  List<List<Player>> get _groups =>
      buildGroups(_sorted, overrides: _config!.overrides);
  List<ScheduleEntry> get _schedule => buildSchedule(
        weeks: listWeeks(_config!.printFrom, _config!.printTo),
        groups: _groups,
        rotationStart: _config!.rotationStart,
        vacations: _vacations,
        startGroup: _config!.startGroupIndex,
      );

  int get _currentGroupIdx {
    final groups = _groups;
    if (groups.isEmpty) return 0;
    return groupIndexForWeek(
        startOfIsoWeek(DateTime.now()), _config!.rotationStart, groups.length,
        startGroup: _config!.startGroupIndex);
  }

  Player? _byId(String id) =>
      _players.where((p) => p.id == id).cast<Player?>().firstWhere(
            (p) => p != null,
            orElse: () => null,
          );

  Future<void> _saveConfig(MaterialDutyConfig c) async {
    setState(() => _config = c);
    await context.read<AppState>().saveMaterialDutyConfig(widget.teamId, c);
  }

  void _setOverride(String playerId, int? groupIndex) {
    final others =
        _config!.overrides.where((o) => o.playerId != playerId).toList();
    if (groupIndex != null) others.add(DutyOverride(playerId, groupIndex));
    _saveConfig(_config!.copyWith(overrides: others));
  }

  // ── Zusätzliche Spieler je Woche (z.B. Strafe) ──────────────────────
  String _weekKey(DateTime monday) =>
      '${monday.year.toString().padLeft(4, '0')}-'
      '${monday.month.toString().padLeft(2, '0')}-'
      '${monday.day.toString().padLeft(2, '0')}';

  List<Player> _extrasFor(DateTime monday) {
    final ids = _config!.extras[_weekKey(monday)] ?? const [];
    return ids.map(_byId).whereType<Player>().toList();
  }

  /// Auswahl-Dialog: welche Spieler sind in dieser Woche zusätzlich dran.
  Future<void> _editExtras(DateTime monday) async {
    final key = _weekKey(monday);
    final selected = {...(_config!.extras[key] ?? const <String>[])};
    final all = [..._players]
      ..sort((a, b) =>
          a.fullName.toLowerCase().compareTo(b.fullName.toLowerCase()));
    final result = await showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final maxH = MediaQuery.of(ctx).size.height * 0.82;
          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxH),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
                    child: Text(
                        'Zusätzlich (Strafe) · KW ${isoWeek(monday).week}',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 16)),
                  ),
                  const Divider(height: 1),
                  Flexible(
                    child: ListView(
                      children: [
                        for (final p in all)
                          CheckboxListTile(
                            value: selected.contains(p.id),
                            secondary: PlayerAvatar(player: p),
                            title: Text(p.fullName),
                            onChanged: (v) => setSheet(() {
                              if (v == true) {
                                selected.add(p.id);
                              } else {
                                selected.remove(p.id);
                              }
                            }),
                          ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () => Navigator.pop(ctx, selected),
                        child: const Text('Übernehmen'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (result == null) return;
    final map = {..._config!.extras};
    if (result.isEmpty) {
      map.remove(key);
    } else {
      map[key] = result.toList();
    }
    await _saveConfig(_config!.copyWith(extras: map));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Ball-/Materialdienst')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_players.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Ball-/Materialdienst')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Noch keine Spieler im Kader.\n'
              'Lege zuerst Spieler an (am besten mit Geburtsdatum).',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Ball-/Materialdienst'),
          actions: [
            IconButton(
              tooltip: 'Plan teilen',
              icon: const Icon(Icons.share),
              onPressed: _share,
            ),
          ],
          bottom: TabBar(
            labelColor: Theme.of(context).colorScheme.onPrimary,
            unselectedLabelColor:
                Theme.of(context).colorScheme.onPrimary.withValues(alpha: 0.7),
            indicatorColor: Theme.of(context).colorScheme.onPrimary,
            indicatorWeight: 3,
            tabs: const [
              Tab(text: 'Gruppen'),
              Tab(text: 'Wochenplan'),
              Tab(text: 'Einstellungen'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _groupsTab(),
            _scheduleTab(),
            _settingsTab(),
          ],
        ),
      ),
    );
  }

  // ── Reiter: Gruppen ─────────────────────────────────────────────────
  Widget _groupsTab() {
    final groups = _groups;
    final missingBirth = _players.where((p) => p.birthdate == null).length;
    return Column(
      children: [
        // Fixierter Kopf: immer sichtbar, kein Scrollen nötig.
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: _currentWeekCard(),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
            children: [
              if (missingBirth > 0)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    '$missingBirth Spieler ohne Geburtsdatum stehen hinten – '
                    'Datum im Spielerprofil nachtragen.',
                    style:
                        TextStyle(fontSize: 12.5, color: Colors.orange.shade800),
                  ),
                ),
              for (var g = 0; g < groups.length; g++)
                _groupCard(g, groups[g], g == _currentGroupIdx),
            ],
          ),
        ),
      ],
    );
  }

  /// Oben fixierte Karte „Diese Woche" (ohne Scrollen sichtbar) inkl.
  /// WhatsApp-Meldung für die aktuelle Woche.
  Widget _currentWeekCard() {
    final scheme = Theme.of(context).colorScheme;
    final groups = _groups;
    if (groups.isEmpty) return const SizedBox.shrink();
    final idx = _currentGroupIdx;
    final members = groups[idx];
    final mon = startOfIsoWeek(DateTime.now());
    final sun = mon.add(const Duration(days: 6));
    final iw = isoWeek(mon);
    final entry = ScheduleEntry(
      monday: mon,
      sunday: sun,
      week: iw.week,
      year: iw.year,
      groupIdx: idx,
      vacationingIds: vacationingInWeek(members, mon, sun, _vacations),
    );
    final vac = entry.vacationingIds.toSet();
    final extras = _extrasFor(mon);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      color: scheme.primaryContainer.withValues(alpha: 0.45),
      shape: RoundedRectangleBorder(
        side: BorderSide(color: scheme.primary, width: 2),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.today, color: scheme.primary, size: 20),
                const SizedBox(width: 6),
                Text('Diese Woche · KW ${entry.week}',
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: scheme.primary,
                        fontSize: 15)),
                const Spacer(),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(8)),
                  child: Text('Gruppe ${idx + 1}',
                      style: TextStyle(
                          color: scheme.onPrimary,
                          fontWeight: FontWeight.bold,
                          fontSize: 12)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 2,
              children: [
                for (final p in members)
                  Text(p.fullName,
                      style: TextStyle(
                        decoration: vac.contains(p.id)
                            ? TextDecoration.lineThrough
                            : null,
                        color: vac.contains(p.id) ? Colors.red : null,
                      )),
              ],
            ),
            if (extras.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Zusätzlich (Strafe):',
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.bold,
                      color: Colors.red.shade700)),
              Wrap(
                spacing: 10,
                runSpacing: 2,
                children: [
                  for (final p in extras)
                    Text(p.fullName,
                        style: TextStyle(color: Colors.red.shade700)),
                ],
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _editExtras(mon),
                    icon: const Icon(Icons.person_add_alt, size: 18),
                    label: Text(extras.isEmpty
                        ? 'Zusätzlich'
                        : 'Zusätzlich (${extras.length})'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    onPressed: () => _sendWeek(entry, members),
                    icon: const Icon(Icons.share, size: 18),
                    label: const Text('Per WhatsApp'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Baut die WhatsApp-Meldung für eine Woche (Format wie vom Nutzer gewünscht:
  /// Anrede, Einleitung, GRUPPE N, dann „Nachname, Vorname" je Zeile).
  String _weekMessage(ScheduleEntry e, List<Player> members) {
    final isCurrent =
        e.monday.isAtSameMomentAs(startOfIsoWeek(DateTime.now()));
    final when = isCurrent
        ? 'diese Woche'
        : 'KW ${e.week} (${_dShort.format(e.monday)}–${_dShort.format(e.sunday)})';
    final b = StringBuffer();
    b.writeln('Guten Morgen zusammen,');
    b.writeln('');
    b.writeln('für $when sind die folgenden Spieler für den Ball- und '
        'Materialdienst eingeteilt:');
    b.writeln('_');
    b.writeln('GRUPPE ${e.groupIdx + 1}');
    for (final p in members) {
      b.writeln(_nameLastFirst(p));
    }
    final extras = _extrasFor(e.monday);
    if (extras.isNotEmpty) {
      b.writeln('_');
      b.writeln('ZUSÄTZLICH:');
      for (final p in extras) {
        b.writeln(_nameLastFirst(p));
      }
    }
    return b.toString().trimRight();
  }

  String _nameLastFirst(Player p) {
    final last = p.lastName.trim();
    final first = p.firstName.trim();
    return last.isEmpty ? first : (first.isEmpty ? last : '$last, $first');
  }

  Future<void> _sendWeek(ScheduleEntry e, List<Player> members) async {
    final ok = await shareViaWhatsApp(_weekMessage(e, members));
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Teilen nicht möglich.')));
    }
  }

  Widget _groupCard(int index, List<Player> members, bool onDuty) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: onDuty
          ? RoundedRectangleBorder(
              side: BorderSide(color: scheme.primary, width: 2),
              borderRadius: BorderRadius.circular(12))
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 4),
            child: Row(
              children: [
                Text('Gruppe ${index + 1}',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(width: 8),
                Text('(${members.length})',
                    style: TextStyle(color: Colors.grey.shade600)),
                if (onDuty) ...[
                  const Spacer(),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text('Diese Woche',
                        style: TextStyle(
                            color: scheme.onPrimary,
                            fontSize: 11,
                            fontWeight: FontWeight.bold)),
                  ),
                ],
              ],
            ),
          ),
          for (final p in members) _memberTile(p, index),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _memberTile(Player p, int groupIndex) {
    final age = _age(p.birthdate);
    final sub = [
      if (p.birthdate != null) '${_dLong.format(p.birthdate!)} (${age}J)',
      if (p.birthdate == null) 'kein Geburtsdatum',
      if (p.number != null) 'Nr. ${p.number}',
    ].join('  ·  ');
    final isFixed = _config!.overrides.any((o) => o.playerId == p.id);
    return ListTile(
      dense: true,
      leading: PlayerAvatar(player: p),
      title: Text(p.fullName),
      subtitle: Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: PopupMenuButton<int>(
        tooltip: 'In Gruppe verschieben',
        icon: Icon(isFixed ? Icons.push_pin : Icons.more_vert,
            size: 18, color: isFixed ? Theme.of(context).colorScheme.primary : null),
        onSelected: (v) => _setOverride(p.id, v < 0 ? null : v),
        itemBuilder: (context) => [
          const PopupMenuItem(value: -1, child: Text('Automatisch zuteilen')),
          for (var g = 0; g < _groups.length; g++)
            PopupMenuItem(
                value: g,
                enabled: g != groupIndex || !isFixed,
                child: Text('Fest in Gruppe ${g + 1}')),
        ],
      ),
    );
  }

  // ── Reiter: Wochenplan ──────────────────────────────────────────────
  Widget _scheduleTab() {
    final schedule = _schedule;
    final groups = _groups;
    if (schedule.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Kein Zeitraum gewählt.\nUnter „Einstellungen" einstellen.',
              textAlign: TextAlign.center),
        ),
      );
    }
    final thisMonday = startOfIsoWeek(DateTime.now());
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      itemCount: schedule.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final e = schedule[i];
        final isCurrent = e.monday.isAtSameMomentAs(thisMonday);
        final members =
            e.groupIdx < groups.length ? groups[e.groupIdx] : <Player>[];
        return _weekCard(e, members, isCurrent);
      },
    );
  }

  Widget _weekCard(ScheduleEntry e, List<Player> members, bool isCurrent) {
    final scheme = Theme.of(context).colorScheme;
    final vac = e.vacationingIds.toSet();
    return Card(
      margin: EdgeInsets.zero,
      shape: isCurrent
          ? RoundedRectangleBorder(
              side: BorderSide(color: scheme.primary, width: 2),
              borderRadius: BorderRadius.circular(12))
          : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('KW ${e.week}',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15)),
                const SizedBox(width: 8),
                Text('${_dShort.format(e.monday)}–${_dShort.format(e.sunday)}',
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
                const Spacer(),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text('Gruppe ${e.groupIdx + 1}',
                      style: TextStyle(
                          color: scheme.primary,
                          fontWeight: FontWeight.bold,
                          fontSize: 12)),
                ),
                IconButton(
                  icon: const Icon(Icons.person_add_alt, size: 18),
                  tooltip: 'Zusätzlich (Strafe) einteilen',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _editExtras(e.monday),
                ),
                IconButton(
                  icon: const Icon(Icons.share, size: 18),
                  tooltip: 'Diese Woche per WhatsApp melden',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _sendWeek(e, members),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 2,
              children: [
                for (final p in members)
                  Text(
                    p.fullName,
                    style: TextStyle(
                      fontSize: 13,
                      decoration: vac.contains(p.id)
                          ? TextDecoration.lineThrough
                          : null,
                      color: vac.contains(p.id) ? Colors.red : null,
                    ),
                  ),
              ],
            ),
            if (vac.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Im Urlaub: ${vac.map((id) => _byId(id)?.fullName ?? '?').join(', ')}',
                  style: TextStyle(fontSize: 11.5, color: Colors.red.shade700),
                ),
              ),
            if (_extrasFor(e.monday).isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Zusätzlich (Strafe): '
                  '${_extrasFor(e.monday).map((p) => p.fullName).join(', ')}',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Colors.red.shade700),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ── Reiter: Einstellungen ───────────────────────────────────────────
  Widget _settingsTab() {
    final c = _config!;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        _dateRow('Rotations-Start', c.rotationStart, (d) {
          _saveConfig(c.copyWith(rotationStart: d));
        }, help: 'Bezugswoche, ab der gezählt wird.'),
        const SizedBox(height: 16),
        _startGroupRow(),
        const SizedBox(height: 16),
        _dateRow('Plan von', c.printFrom, (d) {
          _saveConfig(c.copyWith(printFrom: d));
        }),
        const SizedBox(height: 16),
        _dateRow('Plan bis', c.printTo, (d) {
          _saveConfig(c.copyWith(printTo: d));
        }),
        const SizedBox(height: 20),
        _RulesField(
          initial: c.rules,
          onSave: (v) => _saveConfig(c.copyWith(rules: v)),
        ),
        const SizedBox(height: 20),
        if (c.overrides.isNotEmpty)
          OutlinedButton.icon(
            onPressed: () => _saveConfig(c.copyWith(overrides: const [])),
            icon: const Icon(Icons.restart_alt),
            label: Text('Feste Zuteilungen zurücksetzen (${c.overrides.length})'),
          ),
      ],
    );
  }

  /// Dropdown „Diese Woche ist dran: Gruppe X" – damit sich eine bereits
  /// laufende Rotation deklarieren lässt (Rotations-Start bleibt unberührt).
  Widget _startGroupRow() {
    final n = _groups.length;
    if (n <= 0) return const SizedBox.shrink();
    final current = _currentGroupIdx.clamp(0, n - 1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<int>(
          initialValue: current,
          decoration: const InputDecoration(
            labelText: 'Diese Woche ist dran',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.flag_outlined),
          ),
          items: [
            for (var g = 0; g < n; g++)
              DropdownMenuItem(value: g, child: Text('Gruppe ${g + 1}')),
          ],
          onChanged: (v) {
            if (v == null) return;
            final thisMonday = startOfIsoWeek(DateTime.now());
            final off = weekOffset(_config!.rotationStart, thisMonday);
            final newStart = (((v - off) % n) + n) % n;
            _saveConfig(_config!.copyWith(startGroupIndex: newStart));
          },
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4, left: 4),
          child: Text(
            'Stelle ein, welche Gruppe aktuell dran ist – die Rotation läuft '
            'von hier aus weiter.',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
        ),
      ],
    );
  }

  Widget _dateRow(String label, DateTime value, ValueChanged<DateTime> onPick,
      {String? help}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () async {
            final d = await showDatePicker(
              context: context,
              initialDate: value,
              firstDate: DateTime(value.year - 2),
              lastDate: DateTime(value.year + 3),
              helpText: label,
            );
            if (d != null) onPick(d);
          },
          borderRadius: BorderRadius.circular(4),
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: label,
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.event),
            ),
            child: Text(_dLong.format(value)),
          ),
        ),
        if (help != null)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 4),
            child: Text(help,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
          ),
      ],
    );
  }

  int? _age(DateTime? b) {
    if (b == null) return null;
    final n = DateTime.now();
    var a = n.year - b.year;
    if (n.month < b.month || (n.month == b.month && n.day < b.day)) a--;
    return a;
  }

  // ── Teilen ──────────────────────────────────────────────────────────
  Future<void> _share() async {
    final groups = _groups;
    final schedule = _schedule;
    final b = StringBuffer();
    b.writeln('Ball-/Materialdienst – ${widget.teamName}');
    b.writeln('Diese Woche: Gruppe ${_currentGroupIdx + 1}');
    b.writeln('');
    for (var g = 0; g < groups.length; g++) {
      b.writeln('Gruppe ${g + 1}: '
          '${groups[g].map((p) => p.fullName).join(', ')}');
    }
    // Nächste Wochen ab heute (max. 8).
    final thisMonday = startOfIsoWeek(DateTime.now());
    final upcoming =
        schedule.where((e) => !e.monday.isBefore(thisMonday)).take(8).toList();
    if (upcoming.isNotEmpty) {
      b.writeln('');
      b.writeln('Nächste Wochen:');
      for (final e in upcoming) {
        b.writeln('KW ${e.week} (${_dShort.format(e.monday)}'
            '–${_dShort.format(e.sunday)}): Gruppe ${e.groupIdx + 1}');
      }
    }
    if (_config!.rules.trim().isNotEmpty) {
      b.writeln('');
      b.writeln('Regeln: ${_config!.rules.trim()}');
    }
    final ok = await shareViaWhatsApp(b.toString().trim());
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Teilen nicht möglich.')));
    }
  }
}

/// Mehrzeiliges Regeln-Feld mit Speichern bei Fokusverlust.
class _RulesField extends StatefulWidget {
  const _RulesField({required this.initial, required this.onSave});
  final String initial;
  final ValueChanged<String> onSave;

  @override
  State<_RulesField> createState() => _RulesFieldState();
}

class _RulesFieldState extends State<_RulesField> {
  late final TextEditingController _ctrl;
  late final FocusNode _focus;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initial);
    _focus = FocusNode();
    _focus.addListener(() {
      if (!_focus.hasFocus && _ctrl.text != widget.initial) {
        widget.onSave(_ctrl.text);
      }
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _ctrl,
      focusNode: _focus,
      minLines: 3,
      maxLines: 8,
      textCapitalization: TextCapitalization.sentences,
      decoration: const InputDecoration(
        labelText: 'Regeln / Zuständigkeiten',
        hintText: 'z.B. Bälle, Leibchen, Hütchen mitbringen …',
        border: OutlineInputBorder(),
        alignLabelWithHint: true,
      ),
    );
  }
}
