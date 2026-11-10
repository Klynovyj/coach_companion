import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../models/prep_plan.dart';
import '../services/prep_plan_pdf.dart';
import '../services/share_service.dart';
import '../state/app_state.dart';
import '../utils/rich_note.dart';
import '../widgets/team_logo.dart';

const _uuid = Uuid();

// Farben je Anlass/Spielort (wie die Zeilen im Coach-Studio-Druck).
const _cHome = Color(0xFF16A34A);
const _cAway = Color(0xFFEA580C);
const _cTraining = Color(0xFF0EA5E9);
const _cOther = Color(0xFF8B5CF6);
const _cOpen = Color(0xFF64748B);
const _amber = Color(0xFFD97706);

Color _entryColor(PrepPlanEntry e) {
  if (e.isSpiel) {
    return switch (e.venue) {
      PrepVenue.home => _cHome,
      PrepVenue.away => _cAway,
      _ => _cOpen,
    };
  }
  return e.anlass == PrepAnlass.training ? _cTraining : _cOther;
}

IconData _anlassIcon(PrepAnlass a) => switch (a) {
  PrepAnlass.training => Icons.directions_run_rounded,
  PrepAnlass.spiel => Icons.sports_soccer_rounded,
  PrepAnlass.sonstiges => Icons.star_rounded,
};

/// Montag der ISO-Woche und deren Nummer.
(DateTime, int) _isoWeek(DateTime d) {
  final day = DateTime(d.year, d.month, d.day);
  final monday = day.subtract(Duration(days: day.weekday - 1));
  final thursday = monday.add(const Duration(days: 3));
  final week = (thursday.difference(DateTime(thursday.year, 1, 1)).inDays ~/ 7) + 1;
  return (monday, week);
}

/// Vorbereitungsplan bearbeiten – fürs Handy gebaut: Kopfkarte mit Bilanz,
/// PDF/WhatsApp als große Knöpfe, Hinweise eingeklappt, Termine nach
/// Kalenderwochen (automatisch sortiert), Wischen zum Löschen/Duplizieren.
class PrepPlanEditorScreen extends StatefulWidget {
  const PrepPlanEditorScreen({super.key, required this.plan});
  final PrepPlan plan;

  @override
  State<PrepPlanEditorScreen> createState() => _PrepPlanEditorScreenState();
}

class _PrepPlanEditorScreenState extends State<PrepPlanEditorScreen> {
  late PrepPlan _plan = widget.plan.copyWith(
    entries: sortedPrepEntries(widget.plan.entries),
  );
  late final AppState _state;
  Timer? _saveTimer;
  bool _dirty = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _state = context.read<AppState>();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    if (_dirty) _saveNow();
    super.dispose();
  }

  /// Änderung übernehmen (Termine bleiben chronologisch) + gedrosselt sichern.
  void _update(PrepPlan p) {
    setState(() => _plan = p.copyWith(entries: sortedPrepEntries(p.entries)));
    _dirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), _saveNow);
  }

  Future<void> _saveNow() async {
    if (!_dirty) return;
    _dirty = false;
    await _state.savePrepPlan(_plan, notify: false);
  }

  // ------------------------------------------------------------ Aktionen
  Future<void> _exportPdf() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _saveNow();
      final team = _state.ownTeam;
      final bytes = await PrepPlanPdf.build(
        plan: _plan,
        teamName: team?.name,
        logo: TeamLogo.decode(team?.logoPath),
      );
      final path = await shareOrSaveImage(
        bytes,
        _plan.title.isEmpty ? 'Vorbereitungsplan' : _plan.title,
        ext: 'pdf',
      );
      if (path != null) {
        messenger.showSnackBar(SnackBar(content: Text('PDF gespeichert: $path')));
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('PDF fehlgeschlagen: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _shareWhatsApp() async {
    final ctrl = TextEditingController(
      text: prepPlanWhatsAppText(_plan, teamName: _state.ownTeam?.name),
    );
    final text = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (ctx) => Scaffold(
          appBar: AppBar(
            title: const Text('WhatsApp-Text'),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilledButton.icon(
                  onPressed: () => Navigator.pop(ctx, ctrl.text),
                  icon: const Icon(Icons.share, size: 18),
                  label: const Text('Teilen'),
                ),
              ),
            ],
          ),
          body: Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: ctrl,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                helperText: 'Du kannst den Text vor dem Teilen anpassen.',
              ),
              style: const TextStyle(fontSize: 14),
            ),
          ),
        ),
      ),
    );
    if (text == null || text.trim().isEmpty) return;
    await shareText(text);
  }

  Future<void> _editHeader() async {
    if (!_state.isTrainerHere) return;
    final title = TextEditingController(text: _plan.title);
    final sub = TextEditingController(text: _plan.subtitle ?? '');
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          0,
          20,
          20 + MediaQuery.of(ctx).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Plan bearbeiten', style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: 16),
            TextField(
              controller: title,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Titel',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: sub,
              decoration: const InputDecoration(
                labelText: 'Untertitel',
                hintText: 'z. B. 1. Mannschaft, Saison 26/27',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Übernehmen'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      _update(
        _plan.copyWith(
          title: title.text.trim().isEmpty ? 'Vorbereitungsplan' : title.text.trim(),
          subtitle: sub.text.trim().isEmpty ? null : sub.text.trim(),
        ),
      );
    }
  }

  Future<void> _editNote({required bool top}) async {
    final res = await Navigator.push<_RichResult>(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => PrepRichTextPage(
          title: top ? 'Hinweis oben' : 'Hinweis unten',
          stored: top ? _plan.hint : _plan.footerText,
        ),
      ),
    );
    if (res == null) return;
    _update(
      top
          ? _plan.copyWith(hint: res.value)
          : _plan.copyWith(footerText: res.value),
    );
  }

  Future<void> _addEntry() async {
    final last = _plan.entries.isNotEmpty ? _plan.entries.last : null;
    final draft = PrepPlanEntry(
      id: 'entry-${_uuid.v4().substring(0, 8)}',
      date: last?.date ?? DateFormat('yyyy-MM-dd').format(DateTime.now()),
    );
    final res = await _openSheet(draft, isNew: true);
    if (res != null) _update(_plan.copyWith(entries: [..._plan.entries, res]));
  }

  Future<void> _editEntry(PrepPlanEntry e) async {
    if (!_state.isTrainerHere) return;
    final res = await _openSheet(e, isNew: false);
    if (res != null) _replaceEntry(res);
  }

  Future<PrepPlanEntry?> _openSheet(PrepPlanEntry e, {required bool isNew}) =>
      showModalBottomSheet<PrepPlanEntry>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        builder: (_) => _EntrySheet(entry: e, isNew: isNew),
      );

  void _replaceEntry(PrepPlanEntry e) => _update(
    _plan.copyWith(entries: [for (final x in _plan.entries) x.id == e.id ? e : x]),
  );

  void _removeEntry(PrepPlanEntry e) {
    final before = _plan.entries;
    _update(_plan.copyWith(entries: before.where((x) => x.id != e.id).toList()));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('${e.anlassLabel} gelöscht'),
          action: SnackBarAction(
            label: 'Rückgängig',
            onPressed: () => _update(_plan.copyWith(entries: before)),
          ),
        ),
      );
  }

  void _duplicate(PrepPlanEntry e) {
    final copy = PrepPlanEntry.fromJson({
      ...e.toJson(),
      'id': 'entry-${_uuid.v4().substring(0, 8)}',
    });
    _update(_plan.copyWith(entries: [..._plan.entries, copy]));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('${e.anlassLabel} dupliziert')));
  }

  Future<void> _entryMenu(PrepPlanEntry e) async {
    final v = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Bearbeiten'),
              onTap: () => Navigator.pop(ctx, 'edit'),
            ),
            ListTile(
              leading: const Icon(Icons.help_outline, color: _amber),
              title: Text(e.tentative ? 'Nicht mehr fraglich' : 'Als fraglich markieren'),
              onTap: () => Navigator.pop(ctx, 'tent'),
            ),
            ListTile(
              leading: const Icon(Icons.copy_all_outlined),
              title: const Text('Duplizieren'),
              onTap: () => Navigator.pop(ctx, 'dup'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('Löschen', style: TextStyle(color: Colors.red)),
              onTap: () => Navigator.pop(ctx, 'del'),
            ),
          ],
        ),
      ),
    );
    switch (v) {
      case 'edit':
        _editEntry(e);
      case 'tent':
        _replaceEntry(e.copyWith(tentative: !e.tentative));
      case 'dup':
        _duplicate(e);
      case 'del':
        _removeEntry(e);
    }
  }

  // -------------------------------------------------------------- Aufbau
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final canEdit = state.isTrainerHere;
    final team = state.ownTeam;

    // Termine nach Kalenderwochen gruppieren.
    final groups = <(DateTime?, int?), List<PrepPlanEntry>>{};
    for (final e in _plan.entries) {
      final d = e.day;
      final k = d == null ? (null, null) : _isoWeek(d);
      groups.putIfAbsent(k, () => []).add(e);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Vorbereitungsplan')),
      floatingActionButton: canEdit
          ? FloatingActionButton.extended(
              onPressed: _addEntry,
              icon: const Icon(Icons.add),
              label: const Text('Termin'),
            )
          : null,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 110),
            children: [
              _HeroCard(
                plan: _plan,
                teamName: team?.name,
                logoPath: team?.logoPath,
                onTap: canEdit ? _editHeader : null,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _exportPdf,
                      icon: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.picture_as_pdf_outlined),
                      label: const Text('PDF (A4)'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: _shareWhatsApp,
                      icon: const Icon(Icons.chat_outlined),
                      label: const Text('WhatsApp'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _NoteTile(
                label: 'Hinweis oben',
                stored: _plan.hint,
                canEdit: canEdit,
                onTap: () => _editNote(top: true),
              ),
              if (_plan.entries.isEmpty)
                _EmptyEntries(canEdit: canEdit)
              else
                for (final g in groups.entries) ...[
                  _WeekHeader(monday: g.key.$1, week: g.key.$2),
                  for (final e in g.value)
                    _EntryTile(
                      key: ValueKey(e.id),
                      entry: e,
                      canEdit: canEdit,
                      onTap: () => _editEntry(e),
                      onMenu: () => _entryMenu(e),
                      onDelete: () => _removeEntry(e),
                      onDuplicate: () => _duplicate(e),
                    ),
                ],
              const SizedBox(height: 8),
              _NoteTile(
                label: 'Hinweis unten',
                stored: _plan.footerText,
                canEdit: canEdit,
                onTap: () => _editNote(top: false),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ======================================================================
// Kopf: Logo, Titel, Untertitel + kompakte Bilanz
// ======================================================================

class _HeroCard extends StatelessWidget {
  const _HeroCard({
    required this.plan,
    required this.teamName,
    required this.logoPath,
    required this.onTap,
  });
  final PrepPlan plan;
  final String? teamName;
  final String? logoPath;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sub = plan.subtitle?.trim();
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      elevation: 0,
      color: scheme.primaryContainer.withValues(alpha: 0.55),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 12, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: TeamLogo(logoPath: logoPath, size: 48),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          plan.title,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            height: 1.15,
                          ),
                        ),
                        if (sub != null && sub.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              sub,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: scheme.primary,
                              ),
                            ),
                          ),
                        if (teamName != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              teamName!.toUpperCase(),
                              style: TextStyle(
                                fontSize: 11,
                                letterSpacing: 1,
                                fontWeight: FontWeight.w600,
                                color: Theme.of(context).hintColor,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (onTap != null)
                    Icon(Icons.edit_outlined, size: 20, color: scheme.primary),
                ],
              ),
              const SizedBox(height: 14),
              _StatsStrip(entries: plan.entries),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bilanz als schmale Zahlen-Leiste (gleich breite Felder).
class _StatsStrip extends StatelessWidget {
  const _StatsStrip({required this.entries});
  final List<PrepPlanEntry> entries;

  @override
  Widget build(BuildContext context) {
    final spiele = entries.where((e) => e.isSpiel).toList();
    final home = spiele.where((e) => e.venue == PrepVenue.home).length;
    final away = spiele.where((e) => e.venue == PrepVenue.away).length;
    final training = entries.where((e) => e.anlass == PrepAnlass.training).length;
    final sonst = entries.where((e) => e.anlass == PrepAnlass.sonstiges).length;
    final fraglich = entries.where((e) => e.tentative).length;

    Widget stat(String value, String label, Color color, {String? sub}) =>
        Expanded(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 3),
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border(bottom: BorderSide(color: color, width: 3)),
            ),
            child: Column(
              children: [
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w900,
                    height: 1.1,
                  ),
                ),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    sub ?? label,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).hintColor,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );

    return Row(
      children: [
        stat('${entries.length}', 'Termine', _cOpen),
        stat('${spiele.length}', 'Spiele', _cHome, sub: 'Spiele $home H/$away A'),
        stat('$training', 'Training', _cTraining),
        stat('$sonst', 'Sonder', _cOther),
        stat('$fraglich', 'Fraglich', _amber),
      ],
    );
  }
}

// ======================================================================
// Hinweise (eingeklappt) + Vollbild-Editor
// ======================================================================

class _NoteTile extends StatelessWidget {
  const _NoteTile({
    required this.label,
    required this.stored,
    required this.canEdit,
    required this.onTap,
  });
  final String label;
  final String? stored;
  final bool canEdit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = RichNote.plainText(stored);
    if (text.isEmpty && !canEdit) return const SizedBox.shrink();
    final hint = Theme.of(context).hintColor;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.5,
        ),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: canEdit ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
            child: Row(
              children: [
                Icon(
                  text.isEmpty ? Icons.add_comment_outlined : Icons.notes_rounded,
                  size: 20,
                  color: hint,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: hint,
                        ),
                      ),
                      Text(
                        text.isEmpty ? 'Antippen zum Hinzufügen' : text,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          color: text.isEmpty ? hint : null,
                          fontStyle: text.isEmpty ? FontStyle.italic : null,
                        ),
                      ),
                    ],
                  ),
                ),
                if (canEdit) Icon(Icons.chevron_right, color: hint),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RichResult {
  const _RichResult(this.value);
  final String? value;
}

/// Vollbild-Editor für einen Hinweis (Größe, Farbe, Hintergrund, Fett/
/// Kursiv/Unterstrichen, Listen). Zurück oder „Fertig" übernimmt.
class PrepRichTextPage extends StatefulWidget {
  const PrepRichTextPage({super.key, required this.title, this.stored});
  final String title;
  final String? stored;

  @override
  State<PrepRichTextPage> createState() => _PrepRichTextPageState();
}

class _PrepRichTextPageState extends State<PrepRichTextPage> {
  late final QuillController _c = QuillController(
    document: RichNote.documentFrom(widget.stored),
    selection: const TextSelection.collapsed(offset: 0),
  );
  final _focus = FocusNode();
  final _scroll = ScrollController();

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  _RichResult _result() {
    final s = RichNote.encode(_c.document);
    return _RichResult(RichNote.isEmpty(s) ? null : s);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, _result());
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.title),
          actions: [
            IconButton(
              tooltip: 'Leeren',
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: () => _c.clear(),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton(
                onPressed: () => Navigator.pop(context, _result()),
                child: const Text('Fertig'),
              ),
            ),
          ],
        ),
        body: Column(
          children: [
            QuillSimpleToolbar(
              controller: _c,
              config: const QuillSimpleToolbarConfig(
                showFontFamily: false,
                showInlineCode: false,
                showSubscript: false,
                showSuperscript: false,
                showSmallButton: false,
                showCodeBlock: false,
                showSearchButton: false,
                showLink: false,
                showStrikeThrough: false,
                showHeaderStyle: false,
                showQuote: false,
                showIndent: false,
                showAlignmentButtons: false,
                showListCheck: false,
                showDividers: false,
                showUndo: false,
                showRedo: false,
                showClearFormat: false,
                multiRowsDisplay: false,
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _focus.requestFocus(),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: QuillEditor.basic(
                    controller: _c,
                    focusNode: _focus,
                    scrollController: _scroll,
                    config: const QuillEditorConfig(
                      placeholder: 'z. B. Trainingsstätte noch in Klärung …',
                      padding: EdgeInsets.zero,
                      autoFocus: true,
                      expands: true,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ======================================================================
// Termine
// ======================================================================

class _WeekHeader extends StatelessWidget {
  const _WeekHeader({required this.monday, required this.week});
  final DateTime? monday;
  final int? week;

  @override
  Widget build(BuildContext context) {
    final m = monday;
    String label;
    if (m == null) {
      label = 'Ohne Datum';
    } else {
      final sun = m.add(const Duration(days: 6));
      final range = m.month == sun.month
          ? '${m.day}.–${DateFormat('d. MMMM', 'de_DE').format(sun)}'
          : '${DateFormat('d. MMM', 'de_DE').format(m)} – '
                '${DateFormat('d. MMM', 'de_DE').format(sun)}';
      label = 'KW $week · $range';
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w800,
          letterSpacing: 1,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

class _EmptyEntries extends StatelessWidget {
  const _EmptyEntries({required this.canEdit});
  final bool canEdit;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 40),
    child: Column(
      children: [
        Icon(
          Icons.event_note_outlined,
          size: 48,
          color: Theme.of(context).hintColor,
        ),
        const SizedBox(height: 8),
        Text(
          canEdit
              ? 'Noch keine Termine.\nTippe unten auf „Termin".'
              : 'Noch keine Termine.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Theme.of(context).hintColor),
        ),
      ],
    ),
  );
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({
    super.key,
    required this.entry,
    required this.canEdit,
    required this.onTap,
    required this.onMenu,
    required this.onDelete,
    required this.onDuplicate,
  });

  final PrepPlanEntry entry;
  final bool canEdit;
  final VoidCallback onTap;
  final VoidCallback onMenu;
  final VoidCallback onDelete;
  final VoidCallback onDuplicate;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final theme = Theme.of(context);
    final color = _entryColor(e);
    final d = e.day;
    final meetT = visiblePrepTime(e.meetTime);
    final startT = visiblePrepTime(e.time);
    final loc = e.meetLocation?.trim() ?? '';
    final opp = e.opponent?.trim() ?? '';
    final muted = e.tentative ? theme.hintColor : null;

    final card = Material(
      color: theme.colorScheme.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: e.tentative ? _amber : theme.dividerColor.withValues(alpha: 0.6),
          width: e.tentative ? 1.5 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: canEdit ? onTap : null,
        onLongPress: canEdit ? onMenu : null,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Datums-Spalte mit Farbstreifen.
              Container(
                width: 58,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  border: Border(left: BorderSide(color: color, width: 4)),
                ),
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      d == null
                          ? '–'
                          : DateFormat('E', 'de_DE')
                                .format(d)
                                .replaceAll('.', '')
                                .toUpperCase(),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: color,
                      ),
                    ),
                    Text(
                      d == null ? '' : '${d.day}',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        height: 1.1,
                        color: muted,
                      ),
                    ),
                    Text(
                      d == null
                          ? ''
                          : DateFormat('MMM', 'de_DE').format(d).replaceAll('.', ''),
                      style: TextStyle(fontSize: 10.5, color: theme.hintColor),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Row(
                        children: [
                          Icon(_anlassIcon(e.anlass), size: 18, color: color),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: e.anlassLabel,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  if (e.isSpiel && opp.isNotEmpty) ...[
                                    TextSpan(
                                      text: ' vs. ',
                                      style: TextStyle(color: theme.hintColor),
                                    ),
                                    TextSpan(
                                      text: opp,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 15,
                                color: muted,
                                fontStyle: e.tentative ? FontStyle.italic : null,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (e.zusatz != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            e.zusatz!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13, color: theme.hintColor),
                          ),
                        ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          if (e.tentative)
                            _chip('Fraglich', _amber, icon: Icons.help_outline),
                          if (e.isSpiel && e.venue != null)
                            _chip(e.venue!.label, color),
                          if (meetT != null || loc.isNotEmpty)
                            _chip(
                              [
                                if (meetT != null) 'Treff $meetT',
                                if (loc.isNotEmpty) loc,
                              ].join(' · '),
                              theme.hintColor,
                              icon: Icons.place_outlined,
                              subtle: true,
                            ),
                          if (e.isAway && (e.address?.trim().isNotEmpty ?? false))
                            _chip(
                              e.address!.trim(),
                              theme.hintColor,
                              icon: Icons.map_outlined,
                              subtle: true,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              // Beginn groß rechts.
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 10, 12, 10),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      startT ?? '–',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        color: muted,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    Text(
                      'Beginn',
                      style: TextStyle(fontSize: 10.5, color: theme.hintColor),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final padded = Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: card,
    );
    if (!canEdit) return padded;
    // Wischen: nach links = löschen, nach rechts = duplizieren.
    return Dismissible(
      key: ValueKey('dismiss-${e.id}'),
      background: _swipeBg(
        context,
        Icons.copy_all_outlined,
        'Duplizieren',
        Colors.blueGrey,
        Alignment.centerLeft,
      ),
      secondaryBackground: _swipeBg(
        context,
        Icons.delete_outline,
        'Löschen',
        Colors.red,
        Alignment.centerRight,
      ),
      confirmDismiss: (dir) async {
        if (dir == DismissDirection.startToEnd) {
          onDuplicate();
          return false;
        }
        return true;
      },
      onDismissed: (_) => onDelete(),
      child: padded,
    );
  }

  Widget _swipeBg(
    BuildContext context,
    IconData icon,
    String label,
    Color color,
    Alignment align,
  ) => Container(
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.symmetric(horizontal: 20),
    alignment: align,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: Colors.white),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
        ),
      ],
    ),
  );

  Widget _chip(String text, Color color, {IconData? icon, bool subtle = false}) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: subtle ? null : color.withValues(alpha: 0.12),
          border: subtle ? Border.all(color: color.withValues(alpha: 0.35)) : null,
          borderRadius: BorderRadius.circular(99),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 13, color: color),
              const SizedBox(width: 3),
            ],
            Flexible(
              child: Text(
                text,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: subtle ? null : color,
                ),
              ),
            ),
          ],
        ),
      );
}

// ======================================================================
// Termin anlegen / bearbeiten
// ======================================================================

class _EntrySheet extends StatefulWidget {
  const _EntrySheet({required this.entry, required this.isNew});
  final PrepPlanEntry entry;
  final bool isNew;

  @override
  State<_EntrySheet> createState() => _EntrySheetState();
}

class _EntrySheetState extends State<_EntrySheet> {
  late PrepPlanEntry _e = widget.entry;
  late final _custom = TextEditingController(text: widget.entry.customAnlassLabel ?? '');
  late final _opponent = TextEditingController(text: widget.entry.opponent ?? '');
  late final _address = TextEditingController(text: widget.entry.address ?? '');
  late final _meetLoc = TextEditingController(text: widget.entry.meetLocation ?? '');

  @override
  void dispose() {
    _custom.dispose();
    _opponent.dispose();
    _address.dispose();
    _meetLoc.dispose();
    super.dispose();
  }

  String? _t(TextEditingController c) =>
      c.text.trim().isEmpty ? null : c.text.trim();

  PrepPlanEntry _result() {
    final spiel = _e.anlass == PrepAnlass.spiel;
    return _e.copyWith(
      customAnlassLabel: _t(_custom),
      opponent: spiel ? _t(_opponent) : null,
      venue: spiel ? _e.venue : null,
      address: spiel && _e.venue == PrepVenue.away ? _t(_address) : null,
      meetLocation: _t(_meetLoc),
    );
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _e.day ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2040),
      locale: const Locale('de', 'DE'),
    );
    if (d != null) {
      setState(() => _e = _e.copyWith(date: DateFormat('yyyy-MM-dd').format(d)));
    }
  }

  Future<String?> _pickTime(String? current, int defaultHour) async {
    var init = TimeOfDay(hour: defaultHour, minute: 0);
    final v = visiblePrepTime(current);
    if (v != null) {
      final p = v.split(':');
      init = TimeOfDay(hour: int.parse(p[0]), minute: int.parse(p[1]));
    }
    final t = await showTimePicker(
      context: context,
      initialTime: init,
      builder: (ctx, child) => MediaQuery(
        data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (t == null) return null;
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  Widget _anlassTile(PrepAnlass a, String label) {
    final sel = _e.anlass == a;
    final color = switch (a) {
      PrepAnlass.training => _cTraining,
      PrepAnlass.spiel => _cHome,
      PrepAnlass.sonstiges => _cOther,
    };
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Material(
          color: sel ? color.withValues(alpha: 0.16) : null,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(
              color: sel ? color : Theme.of(context).dividerColor,
              width: sel ? 2 : 1,
            ),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => setState(() => _e = _e.copyWith(anlass: a)),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                children: [
                  Icon(_anlassIcon(a), color: color, size: 26),
                  const SizedBox(height: 4),
                  Text(
                    label,
                    style: TextStyle(
                      fontWeight: sel ? FontWeight.w800 : FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _pickerTile({
    required IconData icon,
    required String label,
    required String? value,
    required VoidCallback onTap,
    VoidCallback? onClear,
  }) {
    final theme = Theme.of(context);
    return Expanded(
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
            child: Row(
              children: [
                Icon(icon, size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: TextStyle(fontSize: 11, color: theme.hintColor),
                      ),
                      Text(
                        value ?? '–',
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                if (value != null && onClear != null)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Entfernen',
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: onClear,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  InputDecoration _dec(String label, {IconData? icon, String? hint}) =>
      InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: icon == null ? null : Icon(icon),
        filled: true,
        border: _noBorder,
        enabledBorder: _noBorder,
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(
            color: Theme.of(context).colorScheme.primary,
            width: 1.5,
          ),
        ),
      );

  static final _noBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(14),
    borderSide: BorderSide.none,
  );

  @override
  Widget build(BuildContext context) {
    final d = _e.day;
    final spiel = _e.anlass == PrepAnlass.spiel;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.isNew ? 'Neuer Termin' : 'Termin bearbeiten',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                _anlassTile(PrepAnlass.training, 'Training'),
                _anlassTile(PrepAnlass.spiel, 'Spiel'),
                _anlassTile(PrepAnlass.sonstiges, 'Sonstiges'),
              ],
            ),
            const SizedBox(height: 12),
            if (_e.anlass == PrepAnlass.sonstiges)
              TextField(
                controller: _custom,
                textCapitalization: TextCapitalization.sentences,
                decoration: _dec('Was steht an?', hint: 'z. B. Mannschaftsfoto'),
              ),
            if (spiel) ...[
              TextField(
                controller: _opponent,
                textCapitalization: TextCapitalization.words,
                decoration: _dec('Gegner', icon: Icons.shield_outlined),
              ),
              const SizedBox(height: 10),
              SegmentedButton<PrepVenue?>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: PrepVenue.home, label: Text('Heim')),
                  ButtonSegment(value: PrepVenue.away, label: Text('Auswärts')),
                  ButtonSegment(value: PrepVenue.open, label: Text('Offen')),
                ],
                emptySelectionAllowed: true,
                selected: {if (_e.venue != null) _e.venue},
                onSelectionChanged: (s) => setState(
                  () => _e = _e.copyWith(venue: s.isEmpty ? null : s.first),
                ),
              ),
              if (_e.venue == PrepVenue.away) ...[
                const SizedBox(height: 10),
                TextField(
                  controller: _address,
                  decoration: _dec('Adresse / Sportanlage', icon: Icons.map_outlined),
                ),
              ],
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                _pickerTile(
                  icon: Icons.event,
                  label: 'Datum',
                  value: d == null
                      ? null
                      : DateFormat('EE, dd.MM.yy', 'de_DE').format(d),
                  onTap: _pickDate,
                ),
                const SizedBox(width: 10),
                _pickerTile(
                  icon: Icons.schedule,
                  label: 'Beginn',
                  value: visiblePrepTime(_e.time),
                  onTap: () async {
                    final t = await _pickTime(_e.time, 19);
                    if (t != null) setState(() => _e = _e.copyWith(time: t));
                  },
                  onClear: () => setState(() => _e = _e.copyWith(time: null)),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                _pickerTile(
                  icon: Icons.groups_outlined,
                  label: 'Treffpunkt',
                  value: visiblePrepTime(_e.meetTime),
                  onTap: () async {
                    final t = await _pickTime(_e.meetTime ?? _e.time, 18);
                    if (t != null) setState(() => _e = _e.copyWith(meetTime: t));
                  },
                  onClear: () => setState(() => _e = _e.copyWith(meetTime: null)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _meetLoc,
                    decoration: _dec('Treffpunkt-Ort', hint: 'z. B. Garath'),
                  ),
                ),
              ],
            ),
            if (_e.anlass != PrepAnlass.sonstiges) ...[
              const SizedBox(height: 10),
              TextField(
                controller: _custom,
                textCapitalization: TextCapitalization.sentences,
                decoration: _dec(
                  'Zusatz (optional)',
                  icon: Icons.short_text,
                  hint: spiel ? 'z. B. Kreisliga B' : 'z. B. intensiv',
                ),
              ),
            ],
            const SizedBox(height: 4),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.help_outline, color: _amber),
              value: _e.tentative,
              onChanged: (v) => setState(() => _e = _e.copyWith(tentative: v)),
              title: const Text('Fraglich'),
              subtitle: const Text('Termin steht noch nicht fest'),
            ),
            const SizedBox(height: 8),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
              onPressed: () => Navigator.pop(context, _result()),
              child: Text(widget.isNew ? 'Termin anlegen' : 'Speichern'),
            ),
          ],
        ),
      ),
    );
  }
}
