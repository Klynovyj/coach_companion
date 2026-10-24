import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/card_entry.dart';
import '../models/enums.dart';
import '../models/match.dart';
import '../models/match_event.dart';
import '../models/note_category.dart';
import '../models/player.dart';
import '../models/player_absence.dart';
import '../models/player_note.dart';
import '../models/player_rating.dart';
import '../models/player_stat.dart';
import '../state/app_state.dart';
import '../widgets/availability_controls.dart';
import '../widgets/player_avatar.dart';
import '../widgets/rich_note_view.dart';
import '../widgets/star_rating.dart';
import 'live_match_screen.dart';
import 'note_editor_screen.dart';

/// Spielerprofil – alles nach Kategorien geordnet und direkt im Profil
/// bearbeitbar (Felder antippen, Änderungen werden sofort gespeichert).
class PlayerDetailScreen extends StatefulWidget {
  const PlayerDetailScreen({super.key, required this.player});
  final Player player;

  @override
  State<PlayerDetailScreen> createState() => _PlayerDetailScreenState();
}

class _PlayerDetailScreenState extends State<PlayerDetailScreen> {
  late Player _player;

  /// Sortierrichtung der Bewertungen nach Datum (false = neueste zuerst).
  bool _ratingsSortAsc = false;

  @override
  void initState() {
    super.initState();
    _player = widget.player;
  }

  /// Übernimmt eine Änderung am Spieler: sofort speichern + Ansicht aktualisieren.
  Future<void> _apply(Player updated) async {
    setState(() => _player = updated);
    await context.read<AppState>().updatePlayer(updated);
  }

  /// Spielerfoto wählen: Datei/Galerie (Desktop & Handy), Kamera (nur Handy),
  /// oder vorhandenes Foto entfernen. Wird als Data-URL am Spieler gespeichert.
  Future<void> _changePhoto() async {
    final isMobile = Platform.isAndroid || Platform.isIOS;
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isMobile)
              ListTile(
                leading: const Icon(Icons.photo_camera),
                title: const Text('Kamera'),
                onTap: () => Navigator.pop(context, 'camera'),
              ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: Text(isMobile ? 'Galerie' : 'Bild auswählen'),
              onTap: () => Navigator.pop(context, 'gallery'),
            ),
            if (_player.photoPath != null)
              ListTile(
                leading:
                    const Icon(Icons.delete_outline, color: Colors.red),
                title: const Text('Foto entfernen'),
                onTap: () => Navigator.pop(context, 'remove'),
              ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'remove') {
      await _apply(_player.copyWith(clearPhotoPath: true));
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    try {
      final file = await ImagePicker().pickImage(
        source: choice == 'camera' ? ImageSource.camera : ImageSource.gallery,
        maxWidth: 800,
        maxHeight: 800,
        imageQuality: 80,
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      final dataUrl = 'data:image/jpeg;base64,${base64Encode(bytes)}';
      if (!mounted) return;
      await _apply(_player.copyWith(photoPath: dataUrl));
    } catch (e) {
      messenger.showSnackBar(
          SnackBar(content: Text('Foto konnte nicht geladen werden: $e')));
    }
  }

  /// Statuswechsel: Abwesenheiten (Verletzt/Krank/Gesperrt/Urlaub) fragen den
  /// Zeitraum + Grund ab und werden protokolliert; sonst direkt setzen.
  Future<void> _setStatus(PlayerStatus s) async {
    if (!s.isAbsence) {
      await _apply(_player.copyWith(status: s));
      return;
    }
    final res = await _showAbsenceDialog(s);
    if (res == null || !mounted) return;
    await context.read<AppState>().addAbsence(
          player: _player,
          status: s,
          from: res.$1,
          until: res.$2,
          note: res.$3,
        );
    if (mounted) setState(() => _player = _player.copyWith(status: s));
  }

  Future<void> _editAbsence(PlayerAbsence a) async {
    final res = await _showAbsenceDialog(a.status,
        initialFrom: a.from, initialUntil: a.until, initialNote: a.note);
    if (res == null || !mounted) return;
    await context.read<AppState>().updateAbsence(PlayerAbsence(
          id: a.id,
          playerId: a.playerId,
          status: a.status,
          from: res.$1,
          until: res.$2,
          note: res.$3,
          createdAt: a.createdAt,
        ));
    if (mounted) setState(() {});
  }

  /// Dialog für Zeitraum (von–bis) + optionalen Grund einer Abwesenheit.
  Future<(DateTime, DateTime, String?)?> _showAbsenceDialog(
    PlayerStatus s, {
    DateTime? initialFrom,
    DateTime? initialUntil,
    String? initialNote,
  }) async {
    final df = DateFormat('dd.MM.yyyy', 'de_DE');
    var from = initialFrom ?? DateTime.now();
    var until = initialUntil ?? DateTime.now().add(const Duration(days: 7));
    final noteCtrl = TextEditingController(text: initialNote ?? '');
    return showDialog<(DateTime, DateTime, String?)>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text('${s.symbol} ${s.label}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.event, size: 18),
                      label: Text('Von: ${df.format(from)}'),
                      onPressed: () async {
                        final d = await showDatePicker(
                          context: context,
                          initialDate: from,
                          firstDate: DateTime(from.year - 1),
                          lastDate: DateTime(from.year + 2),
                        );
                        if (d != null) {
                          setLocal(() {
                            from = d;
                            if (until.isBefore(from)) until = from;
                          });
                        }
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.event_available, size: 18),
                      label: Text('Bis: ${df.format(until)}'),
                      onPressed: () async {
                        final d = await showDatePicker(
                          context: context,
                          initialDate: until,
                          firstDate: from,
                          lastDate: DateTime(from.year + 2),
                        );
                        if (d != null) setLocal(() => until = d);
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: noteCtrl,
                decoration: const InputDecoration(
                  labelText: 'Grund (optional)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Abbrechen')),
            FilledButton(
              onPressed: () => Navigator.pop(context, (
                from,
                until,
                noteCtrl.text.trim().isEmpty ? null : noteCtrl.text.trim()
              )),
              child: const Text('Speichern'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final df = DateFormat('dd.MM.yyyy', 'de_DE');
    final p = _player;

    // Karteikarten: weniger auf einen Blick, kein endloses Scrollen.
    return DefaultTabController(
      length: 7,
      child: Scaffold(
        appBar: AppBar(
          title: Text(p.fullName.isEmpty ? 'Spieler' : p.fullName),
          actions: [
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'delete') _deletePlayer();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'delete', child: Text('Spieler löschen')),
              ],
            ),
          ],
        ),
        body: Column(
          children: [
            _header(context),
            Material(
              color: Theme.of(context).colorScheme.surface,
              child: TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: const [
                  Tab(text: 'Profil'),
                  Tab(text: 'Abwesenheit'),
                  Tab(text: 'Karten'),
                  Tab(text: 'Tore'),
                  Tab(text: 'Ereignisse'),
                  Tab(text: 'Notizen'),
                  Tab(text: 'Bewertungen'),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: TabBarView(
                children: [
                  _tabList([_stammdatenCard(context)]),
                  _tabList([_absencesCard(context, state)]),
                  _tabList([
                    _cardsCard(context, state, df),
                    _fupaCardsCard(context, state),
                  ]),
                  _tabList([
                    _fupaStatCard(context, state),
                    _goalsCard(context, state, df),
                  ]),
                  _tabList([_eventsCard(context, state, df)]),
                  _tabList([_notesCard(context, state, df)]),
                  _tabList([_bewertungenCard(context, state, df)]),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Ein Reiter-Inhalt als scrollbare Liste mit etwas Abstand unten.
  Widget _tabList(List<Widget> children) => ListView(
        padding: const EdgeInsets.only(bottom: 28),
        children: children,
      );

  // ------------------------------------------------------------------ Header
  Widget _header(BuildContext context) {
    final p = _player;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Row(
        children: [
          GestureDetector(
            onTap: _changePhoto,
            child: Stack(
              children: [
                PlayerAvatar(player: p, radius: 34),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      shape: BoxShape.circle,
                      border: Border.all(color: scheme.surface, width: 1.5),
                    ),
                    child: Icon(Icons.photo_camera,
                        size: 13, color: scheme.onPrimary),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(p.fullName.isEmpty ? 'Neuer Spieler' : p.fullName,
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 2),
                Text([
                  if (p.number != null) 'Nr. ${p.number}',
                  if (p.position != null) p.position!,
                ].join('  ·  ')),
                const SizedBox(height: 8),
                // Status & Rolle direkt im Kopf – antippen zum Ändern.
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _statusMenu(context, p),
                    _captainMenu(context, p),
                    _starterChip(context, p),
                    _ratingChip(context),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Stamm-11-Schalter direkt im Kopf (antippen = an/aus).
  Widget _starterChip(BuildContext context, Player p) {
    return FilterChip(
      label: const Text('Stamm 11'),
      selected: p.isStarter,
      showCheckmark: true,
      visualDensity: VisualDensity.compact,
      onSelected: (v) => _apply(p.copyWith(isStarter: v)),
    );
  }

  Widget _ratingChip(BuildContext context) {
    return FutureBuilder<(double?, int)>(
      future: context.read<AppState>().ratingAverage(_player.id),
      builder: (context, snap) {
        if (!snap.hasData) return const SizedBox.shrink();
        final (avg, count) = snap.data!;
        if (avg == null || count == 0) return const SizedBox.shrink();
        return Chip(
          avatar: Icon(Icons.star, size: 16, color: Colors.amber.shade700),
          label: Text('${avg.toStringAsFixed(1)} ($count)'),
          visualDensity: VisualDensity.compact,
        );
      },
    );
  }

  /// Antippbarer Status-Chip (öffnet die Status-Auswahl).
  Widget _statusMenu(BuildContext context, Player p) {
    return PopupMenuButton<PlayerStatus>(
      tooltip: 'Status ändern',
      onSelected: _setStatus,
      itemBuilder: (_) => [
        for (final s in PlayerStatus.values)
          PopupMenuItem(value: s, child: Text('${s.symbol} ${s.label}')),
      ],
      child: _editChip(
        context,
        leading: Text(p.status.symbol, style: const TextStyle(fontSize: 12)),
        label: p.status.label,
        side: playerStatusColor(p.status),
      ),
    );
  }

  /// Antippbarer Kapitäns-Chip (öffnet die Rollen-Auswahl).
  Widget _captainMenu(BuildContext context, Player p) {
    final c = p.captainRole;
    return PopupMenuButton<CaptainRole>(
      tooltip: 'Kapitäns-Rolle ändern',
      onSelected: (r) => _apply(p.copyWith(captainRole: r)),
      itemBuilder: (_) => [
        for (final r in CaptainRole.values)
          PopupMenuItem(
              value: r,
              child: Text(
                  r == CaptainRole.none ? 'Keine Rolle' : '${r.badge} ${r.label}')),
      ],
      child: _editChip(
        context,
        label: c == CaptainRole.none ? 'Rolle' : '${c.badge} ${c.label}',
        side: c == CaptainRole.none
            ? Theme.of(context).colorScheme.outline
            : Theme.of(context).colorScheme.primary,
      ),
    );
  }

  /// Chip-Optik mit Dropdown-Pfeil, signalisiert „antippbar".
  Widget _editChip(BuildContext context,
      {Widget? leading, required String label, required Color side}) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 5, 6, 5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: side),
        color: Theme.of(context).colorScheme.surface,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (leading != null) ...[leading, const SizedBox(width: 6)],
          Text(label),
          const Icon(Icons.arrow_drop_down, size: 18),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- Stammdaten
  Widget _stammdatenCard(BuildContext context) {
    final p = _player;
    return _SectionCard(
      icon: Icons.badge_outlined,
      title: 'Stammdaten',
      child: Column(
        children: [
          _EditableField(
            label: 'Vorname',
            initial: p.firstName,
            onSave: (v) => _apply(p.copyWith(firstName: v.trim())),
          ),
          const SizedBox(height: 10),
          _EditableField(
            label: 'Nachname',
            initial: p.lastName,
            onSave: (v) => _apply(p.copyWith(lastName: v.trim())),
          ),
          const SizedBox(height: 10),
          _EditableField(
            label: 'Spitzname',
            initial: p.nickname ?? '',
            onSave: (v) {
              final t = v.trim();
              _apply(t.isEmpty
                  ? p.copyWith(clearNickname: true)
                  : p.copyWith(nickname: t));
            },
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 80,
                child: _EditableField(
                  label: 'Nr.',
                  initial: p.number?.toString() ?? '',
                  keyboardType: TextInputType.number,
                  onSave: (v) {
                    final t = v.trim();
                    if (t.isEmpty) {
                      _apply(p.copyWith(clearNumber: true));
                    } else {
                      final n = int.tryParse(t);
                      if (n != null) _apply(p.copyWith(number: n));
                    }
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _EditableField(
                  label: 'Position',
                  initial: p.position ?? '',
                  onSave: (v) {
                    final t = v.trim();
                    _apply(t.isEmpty
                        ? p.copyWith(clearPosition: true)
                        : p.copyWith(position: t));
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _EditableField(
            label: 'Wunschposition',
            initial: p.wishPosition ?? '',
            onSave: (v) {
              final t = v.trim();
              _apply(t.isEmpty
                  ? p.copyWith(clearWishPosition: true)
                  : p.copyWith(wishPosition: t));
            },
          ),
          const SizedBox(height: 14),
          _positionsField(context, p),
          const SizedBox(height: 14),
          _birthdateField(context, p),
        ],
      ),
    );
  }

  /// Aktuelle Position(en) als Mehrfachauswahl (zusätzlich zum Freitext oben).
  Widget _positionsField(BuildContext context, Player p) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Text('Aktuelle Position(en)',
              style:
                  TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
        ),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final pos in kPositionOptions)
              FilterChip(
                label: Text(pos),
                selected: p.positions.contains(pos),
                showCheckmark: true,
                visualDensity: VisualDensity.compact,
                onSelected: (sel) {
                  final next = [...p.positions];
                  if (sel) {
                    if (!next.contains(pos)) next.add(pos);
                  } else {
                    next.remove(pos);
                  }
                  _apply(p.copyWith(positions: next));
                },
              ),
          ],
        ),
      ],
    );
  }

  int? _ageOf(DateTime? b) {
    if (b == null) return null;
    final n = DateTime.now();
    var a = n.year - b.year;
    if (n.month < b.month || (n.month == b.month && n.day < b.day)) a--;
    return a;
  }

  Widget _birthdateField(BuildContext context, Player p) {
    final df = DateFormat('dd.MM.yyyy', 'de_DE');
    final age = _ageOf(p.birthdate);
    return InkWell(
      onTap: () async {
        final now = DateTime.now();
        final d = await showDatePicker(
          context: context,
          initialDate: p.birthdate ?? DateTime(now.year - 18),
          firstDate: DateTime(1950),
          lastDate: now,
          helpText: 'Geburtsdatum wählen',
        );
        if (d != null) await _apply(p.copyWith(birthdate: d));
      },
      borderRadius: BorderRadius.circular(4),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: 'Geburtstag & Alter',
          border: const OutlineInputBorder(),
          prefixIcon: const Icon(Icons.cake_outlined),
          suffixIcon: p.birthdate == null
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  tooltip: 'Entfernen',
                  onPressed: () => _apply(p.copyWith(clearBirthdate: true)),
                ),
        ),
        child: Text(
          p.birthdate == null
              ? 'Nicht gesetzt'
              : '${df.format(p.birthdate!)}  ·  $age Jahre',
          style: p.birthdate == null
              ? TextStyle(color: Theme.of(context).hintColor)
              : null,
        ),
      ),
    );
  }

  // ------------------------------------------------------- Abwesenheiten
  Widget _absencesCard(BuildContext context, AppState state) {
    final df = DateFormat('dd.MM.yyyy', 'de_DE');
    return _SectionCard(
      icon: Icons.event_busy,
      title: 'Abwesenheiten',
      child: FutureBuilder<List<PlayerAbsence>>(
        future: state.absencesOf(_player.id),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Padding(
              padding: EdgeInsets.all(8),
              child: LinearProgressIndicator(),
            );
          }
          final list = snap.data!;
          if (list.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                    'Keine Einträge. Status Verletzt/Krank/Gesperrt/Urlaub '
                    'oben setzen – mit Zeitraum.',
                    style: TextStyle(color: Colors.grey)),
              ),
            );
          }
          final now = DateTime.now();
          final today = DateTime(now.year, now.month, now.day);
          return Column(
            children: [
              for (final a in list)
                Dismissible(
                  key: ValueKey(a.id),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    color: Colors.red,
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 20),
                    child: const Icon(Icons.delete, color: Colors.white),
                  ),
                  onDismissed: (_) => state.deleteAbsence(a.id),
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Text(a.status.symbol,
                        style: const TextStyle(fontSize: 20)),
                    title: Text(
                        '${a.status.label} · ${df.format(a.from)} – ${df.format(a.until)}'),
                    subtitle: a.note == null
                        ? null
                        : Text(a.note!,
                            maxLines: 2, overflow: TextOverflow.ellipsis),
                    trailing: a.until.isBefore(today)
                        ? const Text('abgelaufen',
                            style:
                                TextStyle(color: Colors.grey, fontSize: 12))
                        : Icon(Icons.circle,
                            size: 10, color: playerStatusColor(a.status)),
                    onTap: () => _editAbsence(a),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  // ------------------------------------------------------------------ Karten
  Widget _cardsCard(BuildContext context, AppState state, DateFormat df) {
    return _SectionCard(
      icon: Icons.style_outlined,
      title: 'Karten',
      action: TextButton.icon(
        onPressed: () => _addCard(context),
        icon: const Icon(Icons.add),
        label: const Text('Karte'),
      ),
      child: FutureBuilder<(List<CardEntry>, Map<String, GameMatch>)>(
        future: _loadCards(state),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Padding(
              padding: EdgeInsets.all(8),
              child: LinearProgressIndicator(),
            );
          }
          final cards = snap.data!.$1;
          final matches = snap.data!.$2;
          return Column(
            children: [
              _cardSummary(context, cards),
              if (cards.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Noch keine Karten erfasst.',
                        style: TextStyle(color: Colors.grey)),
                  ),
                )
              else
                ...cards.map((c) => Dismissible(
                      key: ValueKey(c.id),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        color: Colors.red,
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 20),
                        child: const Icon(Icons.delete, color: Colors.white),
                      ),
                      onDismissed: (_) =>
                          context.read<AppState>().deleteCard(c.id),
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Text(c.type.symbol,
                            style: const TextStyle(fontSize: 22)),
                        title: Text(c.type.label),
                        subtitle: Text(_context(
                          df: df,
                          date: c.date,
                          match: c.matchId == null ? null : matches[c.matchId],
                          minuteLabel: c.minuteLabel,
                          note: c.note,
                        )),
                        onTap: () => _editCard(context, c),
                      ),
                    )),
            ],
          );
        },
      ),
    );
  }

  // -------------------------------------------------- FuPa-Saisonstatistik
  Widget _fupaStatCard(BuildContext context, AppState state) {
    return _SectionCard(
      icon: Icons.insights,
      title: 'Saison (FuPa)',
      child: FutureBuilder<PlayerStat?>(
        future: state.playerSeasonStat(_player.teamId, _player.dedupKey),
        builder: (context, snap) {
          if (!snap.hasData && snap.connectionState != ConnectionState.done) {
            return const Padding(
              padding: EdgeInsets.all(8),
              child: LinearProgressIndicator(),
            );
          }
          final s = snap.data;
          if (s == null) {
            return const Padding(
              padding: EdgeInsets.all(8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                    'Keine FuPa-Statistik. In den Einstellungen/Kader über '
                    '„Statistik" importieren.',
                    style: TextStyle(color: Colors.grey)),
              ),
            );
          }
          Widget stat(String label, String value) => Column(
                children: [
                  Text(value,
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.bold)),
                  Text(label,
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              );
          // Karten stehen im Karten-Reiter; hier nur Tor-/Einsatz-Stats.
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              stat('Spiele', '${s.matches}'),
              stat('Tore', '${s.goals}'),
              stat('Vorlagen', '${s.assists}'),
              stat('Minuten', '${s.minutes}'),
              stat('⭐ Top11', '${s.topEleven}'),
            ],
          );
        },
      ),
    );
  }

  /// FuPa-Saison-Karten im Karten-Reiter – klar als FuPa-Quelle deklariert.
  Widget _fupaCardsCard(BuildContext context, AppState state) {
    return _SectionCard(
      icon: Icons.insights,
      title: 'Karten – Saison (FuPa)',
      child: FutureBuilder<PlayerStat?>(
        future: state.playerSeasonStat(_player.teamId, _player.dedupKey),
        builder: (context, snap) {
          if (!snap.hasData && snap.connectionState != ConnectionState.done) {
            return const Padding(
              padding: EdgeInsets.all(8),
              child: LinearProgressIndicator(),
            );
          }
          final s = snap.data;
          if (s == null) {
            return const Padding(
              padding: EdgeInsets.all(8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Keine FuPa-Statistik.',
                    style: TextStyle(color: Colors.grey)),
              ),
            );
          }
          Widget stat(String label, String value) => Column(
                children: [
                  Text(value,
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.bold)),
                  Text(label, style: Theme.of(context).textTheme.bodySmall),
                ],
              );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  stat('🟨 Gelb', '${s.yellowCards}'),
                  stat('🟨🟥 Gelb-Rot', '${s.yellowRedCards}'),
                  stat('🟥 Rot', '${s.redCards}'),
                ],
              ),
              const SizedBox(height: 8),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text('Quelle: FuPa-Saisonstatistik',
                    style: TextStyle(fontSize: 11.5, color: Colors.grey)),
              ),
            ],
          );
        },
      ),
    );
  }

  // --------------------------------------------------------- Tore & Vorlagen
  Widget _goalsCard(BuildContext context, AppState state, DateFormat df) {
    return _SectionCard(
      icon: Icons.sports_soccer,
      title: 'Tore & Vorlagen',
      child: FutureBuilder<(List<MatchEvent>, Map<String, GameMatch>)>(
        future: _loadEvents(state),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Padding(
              padding: EdgeInsets.all(8),
              child: LinearProgressIndicator(),
            );
          }
          final events = snap.data!.$1
              .where((e) => e.type == MatchEventType.goal)
              .toList();
          if (events.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Noch keine Tore/Vorlagen erfasst.',
                    style: TextStyle(color: Colors.grey)),
              ),
            );
          }
          final matches = snap.data!.$2;
          return Column(
            children: events.map((e) {
              final isScorer = e.playerId == _player.id;
              final m = matches[e.matchId];
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Text(isScorer ? '⚽' : '🅰️',
                    style: const TextStyle(fontSize: 20)),
                title: Text(isScorer ? 'Tor' : 'Vorlage'),
                subtitle: Text(_context(
                  df: df,
                  date: m?.kickoff,
                  match: m,
                  minuteLabel: e.minuteLabel,
                  note: null,
                )),
              );
            }).toList(),
          );
        },
      ),
    );
  }

  // -------------------------------------------------- Ereignis-Chronik
  /// Alle dem Spieler zugeordneten Live-Ereignisse (Tore, Karten, Wechsel,
  /// Großchance, Foul, Ecke, Freistoß, Elfmeter …) – chronologisch.
  Widget _eventsCard(BuildContext context, AppState state, DateFormat df) {
    return FutureBuilder<(List<MatchEvent>, Map<String, GameMatch>)>(
      future: _loadEvents(state),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const _SectionCard(
            icon: Icons.timeline,
            title: 'Ereignis-Chronik',
            child: Padding(
                padding: EdgeInsets.all(8), child: LinearProgressIndicator()),
          );
        }
        final matches = snap.data!.$2;
        final events = snap.data!.$1;
        if (events.isEmpty) {
          return const _SectionCard(
            icon: Icons.timeline,
            title: 'Ereignis-Chronik',
            child: Padding(
              padding: EdgeInsets.all(8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Noch keine Ereignisse erfasst.',
                    style: TextStyle(color: Colors.grey)),
              ),
            ),
          );
        }
        // Nach Spiel gruppieren, neueste Spiele zuerst.
        final byMatch = <String, List<MatchEvent>>{};
        for (final e in events) {
          byMatch.putIfAbsent(e.matchId, () => []).add(e);
        }
        final matchIds = byMatch.keys.toList()
          ..sort((a, b) {
            final ka = matches[a]?.kickoff ?? DateTime(1970);
            final kb = matches[b]?.kickoff ?? DateTime(1970);
            return kb.compareTo(ka);
          });
        return Column(
          children: [
            for (final mid in matchIds)
              _matchEventsCard(
                  context, state, df, matches[mid], mid, byMatch[mid]!),
          ],
        );
      },
    );
  }

  /// Ein Karten-Abschnitt je Spiel – klar voneinander getrennt.
  Widget _matchEventsCard(BuildContext context, AppState state, DateFormat df,
      GameMatch? m, String matchId, List<MatchEvent> evs) {
    final head = m == null ? 'Spiel' : 'vs ${m.opponentName}';
    final date = m?.kickoff == null ? '' : df.format(m!.kickoff!.toLocal());
    final sorted = [...evs]..sort((a, b) => a.minute.compareTo(b.minute));
    return _SectionCard(
      icon: Icons.sports_soccer,
      title: date.isEmpty ? head : '$head  ·  $date',
      child: Column(
        children: [
          for (final e in sorted) _chronRow(context, state, df, e, m),
        ],
      ),
    );
  }

  Widget _chronRow(BuildContext context, AppState state, DateFormat df,
      MatchEvent e, GameMatch? m) {
    final (symbol, label) = _eventLabel(e);
    final sub = [
      e.minuteLabel,
      if (e.note != null && e.note!.isNotEmpty) e.note!,
    ].join('  ·  ');
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Text(symbol, style: const TextStyle(fontSize: 20)),
      title: Text(label),
      subtitle: sub.isEmpty ? null : Text(sub),
      trailing: const Icon(Icons.more_vert, size: 20),
      onTap: () => _eventActions(context, state, e, m),
    );
  }

  Future<void> _eventActions(BuildContext context, AppState state,
      MatchEvent e, GameMatch? m) async {
    final navigator = Navigator.of(context);
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (m != null)
              ListTile(
                leading: const Icon(Icons.open_in_new),
                title: const Text('Zum Spiel'),
                onTap: () => Navigator.pop(context, 'match'),
              ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Korrigieren'),
              onTap: () => Navigator.pop(context, 'edit'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('Löschen'),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'match':
        await navigator.push(MaterialPageRoute(
            builder: (_) => LiveMatchScreen(matchId: e.matchId)));
        if (mounted) setState(() {});
      case 'edit':
        await _editChronEvent(state, e);
      case 'delete':
        await state.deleteEvent(e.matchId, e.id);
        if (mounted) setState(() {});
    }
  }

  /// Minute + Notiz eines Ereignisses direkt im Profil korrigieren.
  Future<void> _editChronEvent(AppState state, MatchEvent e) async {
    final minCtrl = TextEditingController(text: '${e.minute}');
    final noteCtrl = TextEditingController(text: e.note ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Ereignis korrigieren'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: minCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'Spielminute', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: noteCtrl,
              minLines: 1,
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                  labelText: 'Notiz', border: OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Speichern')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final newMin = int.tryParse(minCtrl.text.trim()) ?? e.minute;
    final note = noteCtrl.text.trim();
    await state.updateEvent(MatchEvent(
      id: e.id,
      matchId: e.matchId,
      teamId: e.teamId,
      minute: newMin,
      minuteExtra: e.minuteExtra,
      type: e.type,
      playerId: e.playerId,
      assistPlayerId: e.assistPlayerId,
      note: note.isEmpty ? null : note,
      createdAt: e.createdAt,
    ));
    if (mounted) setState(() {});
  }

  /// Symbol + Beschriftung eines Ereignisses aus Sicht dieses Spielers.
  (String, String) _eventLabel(MatchEvent e) {
    if (e.type == MatchEventType.goal &&
        e.assistPlayerId == _player.id &&
        e.playerId != _player.id) {
      return ('🅰️', 'Vorlage');
    }
    if (e.type == MatchEventType.substitution) {
      final ein = e.playerId == _player.id;
      return (e.type.symbol, ein ? 'Wechsel ein' : 'Wechsel raus');
    }
    return (e.type.symbol, e.type.label);
  }

  // ----------------------------------------------------------------- Notizen
  Widget _notesCard(BuildContext context, AppState state, DateFormat df) {
    return _SectionCard(
      icon: Icons.sticky_note_2_outlined,
      title: 'Notizen',
      action: TextButton.icon(
        onPressed: () => _addNote(context),
        icon: const Icon(Icons.add),
        label: const Text('Notiz'),
      ),
      child: FutureBuilder<
          (List<PlayerNote>, List<NoteCategory>, Map<String, GameMatch>)>(
        future: _loadNotes(state),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Padding(
              padding: EdgeInsets.all(8),
              child: LinearProgressIndicator(),
            );
          }
          final notes = snap.data!.$1;
          final cats = snap.data!.$2;
          final matches = snap.data!.$3;
          if (notes.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Noch keine Notizen.',
                    style: TextStyle(color: Colors.grey)),
              ),
            );
          }
          // Nach Rubrik gruppieren – Reihenfolge wie in den Einstellungen,
          // „Ohne Rubrik" ganz unten.
          final byCat = <String?, List<PlayerNote>>{};
          final known = {for (final c in cats) c.id};
          for (final n in notes) {
            final key = (n.categoryId != null && known.contains(n.categoryId))
                ? n.categoryId
                : null;
            byCat.putIfAbsent(key, () => []).add(n);
          }
          final groups = <(String, List<PlayerNote>)>[
            for (final c in cats)
              if (byCat[c.id] != null) (c.name, byCat[c.id]!),
            if (byCat[null] != null) ('Ohne Kategorie', byCat[null]!),
          ];
          return Column(
            children: [
              for (final g in groups) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(0, 8, 0, 0),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(g.$1,
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                            color: Theme.of(context).colorScheme.primary)),
                  ),
                ),
                for (final n in g.$2)
                  Dismissible(
                    key: ValueKey(n.id),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      color: Colors.red,
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 20),
                      child: const Icon(Icons.delete, color: Colors.white),
                    ),
                    onDismissed: (_) =>
                        context.read<AppState>().deleteNote(n.id),
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.sticky_note_2_outlined),
                      title: RichNoteView(stored: n.text),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text([
                          df.format(n.createdAt),
                          if (n.matchId != null && matches[n.matchId] != null)
                            'vs ${matches[n.matchId]!.opponentName}',
                        ].join('  ·  ')),
                      ),
                      trailing: const Icon(Icons.edit, size: 18),
                      onTap: () => _editNote(context, n),
                    ),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }

  // -------------------------------------------------------------- Bewertungen
  Widget _bewertungenCard(BuildContext context, AppState state, DateFormat df) {
    return _SectionCard(
      icon: Icons.star_border,
      title: 'Bewertungen',
      child: FutureBuilder<
          (List<GameMatch>, Map<String, PlayerRating>, Set<String>)>(
        future: _loadRatings(state),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Padding(
              padding: EdgeInsets.all(8),
              child: LinearProgressIndicator(),
            );
          }
          final allMatches = snap.data!.$1;
          final ratings = snap.data!.$2;
          final played = snap.data!.$3;
          // Nur Spiele, in denen der Spieler gespielt hat (oder bereits bewertet).
          final matches = allMatches
              .where((m) => played.contains(m.id) || ratings.containsKey(m.id))
              .toList();
          if (matches.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                    'Noch keine Einsätze. Bewertbar sind nur Spiele, in denen '
                    'der Spieler gespielt hat.',
                    style: TextStyle(color: Colors.grey)),
              ),
            );
          }
          // Nach Datum sortieren – Richtung umschaltbar.
          final sorted = [...matches]..sort((a, b) {
              final cmp = (a.kickoff ?? a.createdAt)
                  .compareTo(b.kickoff ?? b.createdAt);
              return _ratingsSortAsc ? cmp : -cmp;
            });
          return Column(
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Sterne + Kommentar je Spiel – jederzeit bearbeitbar.',
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () =>
                        setState(() => _ratingsSortAsc = !_ratingsSortAsc),
                    icon: Icon(
                        _ratingsSortAsc
                            ? Icons.arrow_upward
                            : Icons.arrow_downward,
                        size: 16),
                    label: Text(_ratingsSortAsc ? 'Älteste' : 'Neueste'),
                  ),
                ],
              ),
              for (final m in sorted) _ratingRow(context, df, m, ratings[m.id]),
            ],
          );
        },
      ),
    );
  }

  Widget _ratingRow(
      BuildContext context, DateFormat df, GameMatch m, PlayerRating? rating) {
    final stars = rating?.rating.round() ?? 0;
    final note = rating?.note;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('vs ${m.opponentName}',
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(
                      m.kickoff != null ? df.format(m.kickoff!.toLocal()) : '—',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              StarRating(
                value: stars,
                size: 22,
                onTap: (s) => context.read<AppState>().setRating(
                    matchId: m.id, playerId: _player.id, rating: s.toDouble()),
              ),
              if (stars > 0)
                IconButton(
                  tooltip: 'Bewertung entfernen',
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: () =>
                      context.read<AppState>().removeRating(m.id, _player.id),
                ),
            ],
          ),
          // Kommentar – ansehen und bearbeiten (nur wenn bewertet).
          if (stars > 0)
            InkWell(
              onTap: () => _editRatingNote(m, rating!),
              child: Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 2),
                child: Row(
                  children: [
                    Icon(Icons.chat_bubble_outline,
                        size: 14,
                        color: Theme.of(context).colorScheme.primary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        (note != null && note.isNotEmpty)
                            ? note
                            : 'Kommentar hinzufügen …',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontStyle: (note == null || note.isEmpty)
                              ? FontStyle.italic
                              : FontStyle.normal,
                          color: (note == null || note.isEmpty)
                              ? Colors.grey
                              : null,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const Divider(height: 10),
        ],
      ),
    );
  }

  Future<void> _editRatingNote(GameMatch m, PlayerRating rating) async {
    final ctrl = TextEditingController(text: rating.note ?? '');
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Kommentar · vs ${m.opponentName}'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(hintText: 'Kurze Bewertung …'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () => Navigator.pop(context, ctrl.text.trim()),
              child: const Text('Speichern')),
        ],
      ),
    );
    if (text == null || !mounted) return;
    await context.read<AppState>().setRating(
          matchId: m.id,
          playerId: _player.id,
          rating: rating.rating,
          note: text.isEmpty ? null : text,
          keepNote: false,
        );
    if (mounted) setState(() {});
  }

  Future<(List<GameMatch>, Map<String, PlayerRating>, Set<String>)>
      _loadRatings(AppState s) async {
    final mm = await s.matchMap(_player.teamId);
    final list = mm.values.toList()
      ..sort((a, b) =>
          (b.kickoff ?? b.createdAt).compareTo(a.kickoff ?? a.createdAt));
    final ratings = await s.playerRatingsFull(_player.id);
    final played = await s.playedMatchIdsForPlayer(_player.id, _player.teamId);
    return (list, ratings, played);
  }

  // --------------------------------------------------------------- Aktionen
  Future<void> _deletePlayer() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Spieler löschen?'),
        content: Text('„${_player.fullName}" wirklich entfernen?'),
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
    if (ok != true || !mounted) return;
    await context.read<AppState>().deletePlayer(_player.id);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _addNote(BuildContext context) async {
    final matches = await _matchesFor(context);
    if (!context.mounted) return;
    final result = await Navigator.push<NoteEditResult>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            NoteEditorScreen(playerName: _player.fullName, matches: matches),
      ),
    );
    if (result == null || !context.mounted) return;
    await context.read<AppState>().addNote(_player.id, result.stored,
        categoryId: result.categoryId, matchId: result.matchId);
  }

  Future<void> _editNote(BuildContext context, PlayerNote note) async {
    final matches = await _matchesFor(context);
    if (!context.mounted) return;
    final result = await Navigator.push<NoteEditResult>(
      context,
      MaterialPageRoute(
        builder: (_) => NoteEditorScreen(
            playerName: _player.fullName, existing: note, matches: matches),
      ),
    );
    if (result == null || !context.mounted) return;
    await context.read<AppState>().updateNote(
          note.copyWith(
            text: result.stored,
            categoryId: result.categoryId,
            clearCategory: result.categoryId == null,
            matchId: result.matchId,
            clearMatch: result.matchId == null,
          ),
        );
  }

  Future<(List<PlayerNote>, List<NoteCategory>, Map<String, GameMatch>)>
      _loadNotes(AppState s) async {
    final notes = await s.notesOf(_player.id);
    final cats = await s.noteCategories();
    final mm = await s.matchMap(_player.teamId);
    return (notes, cats, mm);
  }

  Future<(List<CardEntry>, Map<String, GameMatch>)> _loadCards(
      AppState s) async {
    final cards = await s.cardsOf(_player.id);
    final mm = await s.matchMap(_player.teamId);
    return (cards, mm);
  }

  Future<(List<MatchEvent>, Map<String, GameMatch>)> _loadEvents(
      AppState s) async {
    final events = await s.playerMatchEvents(_player.id);
    final mm = await s.matchMap(_player.teamId);
    return (events, mm);
  }

  /// Baut die Kontextzeile: Datum · vs Gegner · Minute · Notiz.
  String _context({
    required DateFormat df,
    DateTime? date,
    GameMatch? match,
    required String minuteLabel,
    String? note,
  }) {
    final parts = <String>[
      if (date != null) df.format(date.toLocal()),
      if (match != null) 'vs ${match.opponentName}',
      if (minuteLabel.isNotEmpty) minuteLabel,
      if (note != null && note.isNotEmpty) note,
    ];
    return parts.join('  ·  ');
  }

  Widget _cardSummary(BuildContext context, List<CardEntry> cards) {
    int count(CardType t) => cards.where((c) => c.type == t).length;
    Widget pill(CardType t) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Chip(
            avatar: Text(t.symbol, style: const TextStyle(fontSize: 14)),
            label: Text('${count(t)}'),
            visualDensity: VisualDensity.compact,
          ),
        );
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          pill(CardType.yellow),
          pill(CardType.yellowRed),
          pill(CardType.red),
        ],
      ),
    );
  }

  Future<void> _addCard(BuildContext context) async {
    final matches = await _matchesFor(context);
    if (!context.mounted) return;
    final data = await showCardDialog(context, matches: matches);
    if (data == null || !context.mounted) return;
    await context.read<AppState>().addCard(
          playerId: _player.id,
          type: data.type,
          date: data.date,
          matchId: data.matchId,
          note: data.note,
        );
  }

  Future<void> _editCard(BuildContext context, CardEntry card) async {
    final matches = await _matchesFor(context);
    if (!context.mounted) return;
    final data = await showCardDialog(context, existing: card, matches: matches);
    if (data == null || !context.mounted) return;
    await context.read<AppState>().updateCard(
          card.copyWith(
            type: data.type,
            date: data.date,
            note: data.note,
            matchId: data.matchId,
            clearMatchId: data.matchId == null,
          ),
        );
  }

  /// Spiele des Teams, neueste zuerst – für die Spielauswahl im Kartendialog.
  Future<List<GameMatch>> _matchesFor(BuildContext context) async {
    final mm = await context.read<AppState>().matchMap(_player.teamId);
    final list = mm.values.toList()
      ..sort((a, b) => (b.kickoff ?? b.createdAt)
          .compareTo(a.kickoff ?? a.createdAt));
    return list;
  }
}

/// Karten-Abschnitt mit Icon-Titel und optionaler Aktion – für ein modernes,
/// nach Kategorien geordnetes Profil.
class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.icon,
    required this.title,
    required this.child,
    this.action,
  });

  final IconData icon;
  final String title;
  final Widget child;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                Text(title,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
                const Spacer(),
                ?action,
              ],
            ),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }
}

/// Einzelnes, direkt editierbares Feld: speichert automatisch beim Verlassen
/// (Fokusverlust) oder mit Enter – kein Extra-Bearbeiten-Modus.
class _EditableField extends StatefulWidget {
  const _EditableField({
    required this.label,
    required this.initial,
    required this.onSave,
    this.keyboardType,
  });

  final String label;
  final String initial;
  final ValueChanged<String> onSave;
  final TextInputType? keyboardType;

  @override
  State<_EditableField> createState() => _EditableFieldState();
}

class _EditableFieldState extends State<_EditableField> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  late String _lastSaved;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
    _lastSaved = widget.initial;
    _focusNode = FocusNode()..addListener(_onFocusChange);
  }

  void _onFocusChange() {
    if (!_focusNode.hasFocus) _commit();
  }

  void _commit() {
    if (_controller.text == _lastSaved) return;
    _lastSaved = _controller.text;
    widget.onSave(_controller.text);
  }

  @override
  void didUpdateWidget(covariant _EditableField old) {
    super.didUpdateWidget(old);
    // Externe Änderung (z.B. nach Speichern) übernehmen, solange nicht im Fokus.
    if (!_focusNode.hasFocus && widget.initial != _lastSaved) {
      _lastSaved = widget.initial;
      _controller.text = widget.initial;
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      focusNode: _focusNode,
      keyboardType: widget.keyboardType,
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => _commit(),
      onTapOutside: (_) {
        if (_focusNode.hasFocus) _focusNode.unfocus();
      },
      decoration: InputDecoration(
        labelText: widget.label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }
}

class CardDialogData {
  final CardType type;
  final DateTime date;
  final String? matchId;
  final String? note;
  const CardDialogData(this.type, this.date, this.matchId, this.note);
}

Future<CardDialogData?> showCardDialog(
  BuildContext context, {
  CardEntry? existing,
  List<GameMatch> matches = const [],
}) {
  var type = existing?.type ?? CardType.yellow;
  var date = existing?.date ?? DateTime.now();
  // Vorauswahl nur gültig, wenn das Spiel noch existiert.
  var matchId = (existing?.matchId != null &&
          matches.any((m) => m.id == existing!.matchId))
      ? existing!.matchId
      : null;
  final noteCtrl = TextEditingController(text: existing?.note ?? '');
  final df = DateFormat('dd.MM.yyyy', 'de_DE');

  String matchLabel(GameMatch m) {
    final d = m.kickoff == null ? '' : '${df.format(m.kickoff!.toLocal())} · ';
    return '$d${m.venue == Venue.home ? 'H' : 'A'} vs ${m.opponentName}';
  }

  return showDialog<CardDialogData>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(existing == null ? 'Karte hinzufügen' : 'Karte bearbeiten'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SegmentedButton<CardType>(
                segments: const [
                  ButtonSegment(value: CardType.yellow, label: Text('🟨')),
                  ButtonSegment(value: CardType.yellowRed, label: Text('🟨🟥')),
                  ButtonSegment(value: CardType.red, label: Text('🟥')),
                ],
                selected: {type},
                onSelectionChanged: (s) => setState(() => type = s.first),
              ),
              const SizedBox(height: 12),
              if (matches.isNotEmpty)
                DropdownButtonFormField<String?>(
                  initialValue: matchId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Spiel'),
                  items: [
                    const DropdownMenuItem<String?>(
                        value: null, child: Text('Kein Spiel')),
                    ...matches.map((m) => DropdownMenuItem<String?>(
                          value: m.id,
                          child: Text(matchLabel(m),
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                        )),
                  ],
                  onChanged: (v) => setState(() {
                    matchId = v;
                    // Datum aus dem gewählten Spiel übernehmen.
                    if (v != null) {
                      final m = matches.firstWhere((e) => e.id == v);
                      if (m.kickoff != null) date = m.kickoff!.toLocal();
                    }
                  }),
                ),
              if (matches.isNotEmpty) const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: date,
                    firstDate: DateTime(date.year - 2),
                    lastDate: DateTime(date.year + 1),
                  );
                  if (picked != null) setState(() => date = picked);
                },
                icon: const Icon(Icons.event),
                label: Text(df.format(date)),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: noteCtrl,
                decoration: const InputDecoration(labelText: 'Grund / Notiz'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Abbrechen')),
          FilledButton(
            onPressed: () => Navigator.pop(
              context,
              CardDialogData(type, date, matchId,
                  noteCtrl.text.trim().isEmpty ? null : noteCtrl.text.trim()),
            ),
            child: const Text('Speichern'),
          ),
        ],
      ),
    ),
  );
}
