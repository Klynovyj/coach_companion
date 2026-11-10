import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../models/prep_plan.dart';
import '../services/prep_plan_pdf.dart';
import '../services/share_service.dart';
import '../services/studio_plan_import.dart';
import '../state/app_state.dart';
import '../utils/rich_note.dart';
import '../widgets/team_logo.dart';

const _uuid = Uuid();

// Zeilen-Farben wie im Coach-Studio-Plan (Heim grün, Auswärts orange,
// Training blau, Sonstiges weiß) – hier als dezente Tönung der Karte.
const _tintHome = Color(0xFF22C55E);
const _tintAway = Color(0xFFF59E0B);
const _tintTraining = Color(0xFF38BDF8);
const _amber = Color(0xFFD97706);

/// Vorbereitungspläne (Mehr → Vorbereitungsplan): Saison-Termine als
/// druckbarer DIN-A4-Plan – 1:1 wie im Coach Studio.
class PrepPlansScreen extends StatefulWidget {
  const PrepPlansScreen({super.key});

  @override
  State<PrepPlansScreen> createState() => _PrepPlansScreenState();
}

class _PrepPlansScreenState extends State<PrepPlansScreen> {
  List<PrepPlan>? _plans;

  @override
  void initState() {
    super.initState();
    _load();
    // Cloud-Abgleich (lädt neuere Pläne, schiebt fehlende hoch).
    context.read<AppState>().syncPrepPlans().then((_) => _load());
  }

  Future<void> _load() async {
    final p = await context.read<AppState>().prepPlans();
    if (mounted) setState(() => _plans = p);
  }

  Future<void> _create() async {
    final ctrl = TextEditingController(text: 'Vorbereitungsplan');
    final title = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Neuer Vorbereitungsplan'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Titel'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('Erstellen'),
          ),
        ],
      ),
    );
    if (title == null || !mounted) return;
    final plan = PrepPlan(
      id: 'plan-${_uuid.v4().substring(0, 8)}',
      title: title.trim().isEmpty ? 'Vorbereitungsplan' : title.trim(),
      createdAt: DateTime.now().toUtc().toIso8601String(),
    );
    await context.read<AppState>().savePrepPlan(plan);
    if (!mounted) return;
    await _open(plan);
  }

  Future<void> _open(PrepPlan plan) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => PrepPlanEditorScreen(plan: plan)),
    );
    _load();
  }

  Future<void> _delete(PrepPlan p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Plan „${p.title}" löschen?'),
        content: const Text('Der Plan wird endgültig entfernt.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await context.read<AppState>().deletePrepPlan(p.id);
    _load();
  }

  Future<void> _importStudio() async {
    final state = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      final plans = await StudioPlanImport.readPlans();
      final existing = {for (final p in await state.prepPlans()) p.id};
      var added = 0;
      var updated = 0;
      for (final p in plans) {
        existing.contains(p.id) ? updated++ : added++;
        await state.savePrepPlan(p, notify: false);
      }
      await _load();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            plans.isEmpty
                ? 'Keine Pläne im Coach Studio gefunden.'
                : 'Aus Coach Studio übernommen: $added neu'
                      '${updated > 0 ? ', $updated aktualisiert' : ''}.',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Übernahme fehlgeschlagen: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final team = state.ownTeam;
    final canEdit = state.isTrainerHere;
    final plans = _plans;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Vorbereitungspläne'),
        actions: [
          if (canEdit && StudioPlanImport.available)
            IconButton(
              tooltip: 'Aus Coach Studio übernehmen',
              icon: const Icon(Icons.download_for_offline_outlined),
              onPressed: _importStudio,
            ),
        ],
      ),
      floatingActionButton: canEdit
          ? FloatingActionButton.extended(
              onPressed: _create,
              icon: const Icon(Icons.add),
              label: const Text('Neuer Plan'),
            )
          : null,
      body: plans == null
          ? const Center(child: CircularProgressIndicator())
          : plans.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'Noch keine Pläne angelegt.\n'
                  'Saison-Termine als druckbarer Plan – Trainings, Spiele, '
                  'Mannschaftsfoto, Grillen und alles dazwischen.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).hintColor),
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
              children: [
                for (final p in plans)
                  Card(
                    child: ListTile(
                      leading: TeamLogo(logoPath: team?.logoPath, size: 40),
                      title: Text(
                        p.title,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        [
                          if (p.subtitle?.trim().isNotEmpty ?? false)
                            p.subtitle!.trim(),
                          '${p.entries.length} Termin'
                              '${p.entries.length == 1 ? '' : 'e'}',
                        ].join(' · '),
                      ),
                      onTap: () => _open(p),
                      trailing: canEdit
                          ? IconButton(
                              tooltip: 'Plan löschen',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => _delete(p),
                            )
                          : const Icon(Icons.chevron_right),
                    ),
                  ),
              ],
            ),
    );
  }
}

// ======================================================================
// Editor
// ======================================================================

class PrepPlanEditorScreen extends StatefulWidget {
  const PrepPlanEditorScreen({super.key, required this.plan});
  final PrepPlan plan;

  @override
  State<PrepPlanEditorScreen> createState() => _PrepPlanEditorScreenState();
}

class _PrepPlanEditorScreenState extends State<PrepPlanEditorScreen> {
  late PrepPlan _plan = widget.plan;
  late final TextEditingController _title = TextEditingController(
    text: widget.plan.title,
  );
  late final TextEditingController _subtitle = TextEditingController(
    text: widget.plan.subtitle ?? '',
  );
  late final QuillController _hint = _quill(widget.plan.hint);
  late final QuillController _footer = _quill(widget.plan.footerText);
  StreamSubscription<dynamic>? _hintSub;
  StreamSubscription<dynamic>? _footerSub;
  Timer? _saveTimer;
  bool _dirty = false;
  bool _busy = false;

  QuillController _quill(String? stored) => QuillController(
    document: RichNote.documentFrom(stored),
    selection: const TextSelection.collapsed(offset: 0),
  );

  late final AppState _state;

  bool get _canEdit => _state.isTrainerHere;

  @override
  void initState() {
    super.initState();
    _state = context.read<AppState>();
    _hintSub = _hint.document.changes.listen((_) {
      _update(_plan.copyWith(hint: _richOrNull(_hint)));
    });
    _footerSub = _footer.document.changes.listen((_) {
      _update(_plan.copyWith(footerText: _richOrNull(_footer)));
    });
  }

  String? _richOrNull(QuillController c) {
    final s = RichNote.encode(c.document);
    return RichNote.isEmpty(s) ? null : s;
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    if (_dirty) _saveNow();
    _hintSub?.cancel();
    _footerSub?.cancel();
    _hint.dispose();
    _footer.dispose();
    _title.dispose();
    _subtitle.dispose();
    super.dispose();
  }

  /// Änderung übernehmen + gedrosselt speichern (wie das Auto-Save im Studio).
  void _update(PrepPlan p) {
    setState(() => _plan = p);
    _dirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), _saveNow);
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
      if (!mounted) return;
      final team = context.read<AppState>().ownTeam;
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
        messenger.showSnackBar(
          SnackBar(content: Text('PDF gespeichert: $path')),
        );
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('PDF fehlgeschlagen: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _shareWhatsApp() async {
    final team = context.read<AppState>().ownTeam;
    final ctrl = TextEditingController(
      text: prepPlanWhatsAppText(_plan, teamName: team?.name),
    );
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Plan via WhatsApp teilen'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Du kannst den Text vor dem Teilen noch anpassen.',
                style: TextStyle(color: Theme.of(ctx).hintColor, fontSize: 13),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: TextField(
                  controller: ctrl,
                  maxLines: null,
                  minLines: 8,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                  ),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Abbrechen'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            icon: const Icon(Icons.share),
            label: const Text('Teilen'),
          ),
        ],
      ),
    );
    if (text == null || text.trim().isEmpty) return;
    await shareText(text);
  }

  void _addEntry() {
    final last = _plan.entries.isNotEmpty ? _plan.entries.last : null;
    final e = PrepPlanEntry(
      id: 'entry-${_uuid.v4().substring(0, 8)}',
      date: last?.date ?? DateFormat('yyyy-MM-dd').format(DateTime.now()),
    );
    _update(_plan.copyWith(entries: [..._plan.entries, e]));
    _editEntry(e);
  }

  void _replaceEntry(PrepPlanEntry e) => _update(
    _plan.copyWith(
      entries: [for (final x in _plan.entries) x.id == e.id ? e : x],
    ),
  );

  void _removeEntry(String id) => _update(
    _plan.copyWith(entries: _plan.entries.where((x) => x.id != id).toList()),
  );

  void _moveEntry(String id, int dir) {
    final list = [..._plan.entries];
    final i = list.indexWhere((x) => x.id == id);
    final j = i + dir;
    if (i < 0 || j < 0 || j >= list.length) return;
    final t = list[i];
    list[i] = list[j];
    list[j] = t;
    _update(_plan.copyWith(entries: list));
  }

  void _sortByDate() {
    final list = [..._plan.entries]
      ..sort((a, b) {
        final d = a.date.compareTo(b.date);
        if (d != 0) return d;
        return (visiblePrepTime(a.meetTime) ?? visiblePrepTime(a.time) ?? '')
            .compareTo(
              visiblePrepTime(b.meetTime) ?? visiblePrepTime(b.time) ?? '',
            );
      });
    _update(_plan.copyWith(entries: list));
  }

  void _duplicate(PrepPlanEntry e) {
    final i = _plan.entries.indexWhere((x) => x.id == e.id);
    final copy = PrepPlanEntry.fromJson({
      ...e.toJson(),
      'id': 'entry-${_uuid.v4().substring(0, 8)}',
    });
    final list = [..._plan.entries]..insert(i + 1, copy);
    _update(_plan.copyWith(entries: list));
  }

  Future<void> _editEntry(PrepPlanEntry e) async {
    if (!_canEdit) return;
    final res = await showModalBottomSheet<PrepPlanEntry>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _EntrySheet(entry: e),
    );
    if (res != null) _replaceEntry(res);
  }

  // -------------------------------------------------------------- Aufbau
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final team = state.ownTeam;
    final canEdit = state.isTrainerHere;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(_plan.title.isEmpty ? 'Vorbereitungsplan' : _plan.title),
        actions: [
          IconButton(
            tooltip: 'Als WhatsApp-Text teilen',
            icon: const Icon(Icons.chat_outlined),
            onPressed: _shareWhatsApp,
          ),
          IconButton(
            tooltip: 'Als PDF (DIN A4) teilen / speichern',
            icon: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.picture_as_pdf_outlined),
            onPressed: _busy ? null : _exportPdf,
          ),
          if (canEdit)
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'sort') _sortByDate();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'sort',
                  child: ListTile(
                    leading: Icon(Icons.sort),
                    title: Text('Nach Datum sortieren'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
        ],
      ),
      floatingActionButton: canEdit
          ? FloatingActionButton.extended(
              onPressed: _addEntry,
              icon: const Icon(Icons.add),
              label: const Text('Termin hinzufügen'),
            )
          : null,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 100),
            children: [
              // Kopf: Logo + Titel/Untertitel/Mannschaft.
              Row(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: scheme.primary, width: 2),
                    ),
                    padding: const EdgeInsets.all(4),
                    child: TeamLogo(logoPath: team?.logoPath, size: 56),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextField(
                          controller: _title,
                          readOnly: !canEdit,
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                          ),
                          decoration: const InputDecoration(
                            hintText: 'Titel',
                            isDense: true,
                            border: InputBorder.none,
                          ),
                          onChanged: (v) => _update(_plan.copyWith(title: v)),
                        ),
                        TextField(
                          controller: _subtitle,
                          readOnly: !canEdit,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 1,
                            color: scheme.primary,
                          ),
                          decoration: const InputDecoration(
                            hintText:
                                'Untertitel (z. B. 1. Mannschaft, Saison 26/27)',
                            isDense: true,
                            border: InputBorder.none,
                          ),
                          onChanged: (v) => _update(
                            _plan.copyWith(subtitle: v.isEmpty ? null : v),
                          ),
                        ),
                        if (team != null)
                          Text(
                            team.name.toUpperCase(),
                            style: TextStyle(
                              fontSize: 11,
                              letterSpacing: 1,
                              fontWeight: FontWeight.w600,
                              color: Theme.of(context).hintColor,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const Divider(height: 24),
              _RichBox(
                controller: _hint,
                readOnly: !canEdit,
                placeholder:
                    'Extra Text (oben) – fett / kursiv / unterstrichen / Listen',
              ),
              const SizedBox(height: 16),
              _tableHeader(context),
              if (_plan.entries.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Text(
                    canEdit
                        ? 'Noch keine Termine. Tippe auf „Termin hinzufügen".'
                        : 'Noch keine Termine.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Theme.of(context).hintColor),
                  ),
                ),
              for (var i = 0; i < _plan.entries.length; i++)
                _EntryCard(
                  entry: _plan.entries[i],
                  canEdit: canEdit,
                  isFirst: i == 0,
                  isLast: i == _plan.entries.length - 1,
                  onTap: () => _editEntry(_plan.entries[i]),
                  onMove: (d) => _moveEntry(_plan.entries[i].id, d),
                  onToggleTentative: () => _replaceEntry(
                    _plan.entries[i].copyWith(
                      tentative: !_plan.entries[i].tentative,
                    ),
                  ),
                  onDuplicate: () => _duplicate(_plan.entries[i]),
                  onRemove: () => _removeEntry(_plan.entries[i].id),
                ),
              const SizedBox(height: 16),
              _RichBox(
                controller: _footer,
                readOnly: !canEdit,
                placeholder: 'Extra Text (unten) – fett / kursiv / Listen',
              ),
              const SizedBox(height: 16),
              _StatsView(entries: _plan.entries),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tableHeader(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: const BoxDecoration(
      color: Color(0xFF166534),
      borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
    ),
    child: const Text(
      'DATUM · TREFFPUNKT · ANLASS / DETAILS · H / A · BEGINN',
      style: TextStyle(
        color: Colors.white,
        fontSize: 11,
        fontWeight: FontWeight.bold,
        letterSpacing: 1.2,
      ),
      overflow: TextOverflow.ellipsis,
    ),
  );
}

/// Rich-Text-Feld mit kleiner Leiste (Größe, Farbe, Hintergrund, Fett/
/// Kursiv/Unterstrichen, Listen) – wie der Word-light-Editor im Studio.
class _RichBox extends StatefulWidget {
  const _RichBox({
    required this.controller,
    required this.placeholder,
    required this.readOnly,
  });
  final QuillController controller;
  final String placeholder;
  final bool readOnly;

  @override
  State<_RichBox> createState() => _RichBoxState();
}

class _RichBoxState extends State<_RichBox> {
  final _focus = FocusNode();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.controller.readOnly = widget.readOnly;
  }

  @override
  void dispose() {
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final border = Theme.of(context).dividerColor;
    if (widget.readOnly && widget.controller.document.toPlainText().trim().isEmpty) {
      return const SizedBox.shrink();
    }
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!widget.readOnly) ...[
            QuillSimpleToolbar(
              controller: widget.controller,
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
                multiRowsDisplay: false,
              ),
            ),
            Divider(height: 1, color: border),
          ],
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _focus.requestFocus(),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 40),
                child: QuillEditor.basic(
                  controller: widget.controller,
                  focusNode: _focus,
                  scrollController: _scroll,
                  config: QuillEditorConfig(
                    placeholder: widget.placeholder,
                    padding: EdgeInsets.zero,
                    scrollable: false,
                    autoFocus: false,
                    showCursor: !widget.readOnly,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Ein Termin als Karte – Aufbau wie die Tabellenzeile im Studio-Druck.
class _EntryCard extends StatelessWidget {
  const _EntryCard({
    required this.entry,
    required this.canEdit,
    required this.isFirst,
    required this.isLast,
    required this.onTap,
    required this.onMove,
    required this.onToggleTentative,
    required this.onDuplicate,
    required this.onRemove,
  });

  final PrepPlanEntry entry;
  final bool canEdit;
  final bool isFirst;
  final bool isLast;
  final VoidCallback onTap;
  final void Function(int dir) onMove;
  final VoidCallback onToggleTentative;
  final VoidCallback onDuplicate;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final theme = Theme.of(context);
    final tint = e.venue == PrepVenue.home
        ? _tintHome
        : e.venue == PrepVenue.away
        ? _tintAway
        : e.anlass == PrepAnlass.training
        ? _tintTraining
        : null;
    final muted = e.tentative ? theme.hintColor : null;
    final italic = e.tentative ? FontStyle.italic : FontStyle.normal;
    final d = e.day;
    final meetT = visiblePrepTime(e.meetTime);
    final startT = visiblePrepTime(e.time);
    final loc = e.meetLocation?.trim() ?? '';

    final dateBlock = SizedBox(
      width: 74,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (e.tentative)
            Container(
              margin: const EdgeInsets.only(bottom: 4),
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: const Color(0xFFFEF3C7),
                border: Border.all(color: _amber),
                borderRadius: BorderRadius.circular(3),
              ),
              child: const Text(
                '? FRAGLICH',
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF92400E),
                  letterSpacing: 0.5,
                ),
              ),
            ),
          Text(
            d == null
                ? ''
                : DateFormat('EEEE', 'de_DE').format(d).toUpperCase(),
            style: TextStyle(
              fontSize: 9.5,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.8,
              color: muted ?? theme.colorScheme.primary,
            ),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                d == null ? '–' : '${d.day}',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w900,
                  color: muted,
                  fontStyle: italic,
                ),
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  d == null
                      ? ''
                      : DateFormat('MMM yy', 'de_DE').format(d).toUpperCase(),
                  style: TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w600,
                    color: theme.hintColor,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );

    final opp = e.opponent?.trim();
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: e.anlassLabel.toUpperCase(),
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.6,
                ),
              ),
              if (e.isSpiel) ...[
                TextSpan(
                  text: '  vs. ',
                  style: TextStyle(color: theme.hintColor),
                ),
                if (opp != null && opp.isNotEmpty)
                  TextSpan(
                    text: opp,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
              ],
            ],
          ),
          style: TextStyle(fontSize: 14.5, color: muted, fontStyle: italic),
        ),
        if (e.zusatz != null)
          Text(
            e.zusatz!,
            style: TextStyle(
              fontSize: 12.5,
              color: theme.hintColor,
              fontStyle: italic,
            ),
          ),
        if (e.isAway && (e.address?.trim().isNotEmpty ?? false))
          Text(
            e.address!.trim(),
            style: TextStyle(
              fontSize: 12,
              color: theme.hintColor,
              fontStyle: FontStyle.italic,
            ),
          ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 12,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (meetT != null || loc.isNotEmpty)
              _info(
                Icons.place_outlined,
                'Treffpunkt: ${[if (meetT != null) '$meetT Uhr', if (loc.isNotEmpty) loc].join(' · ')}',
                muted,
              ),
            if (startT != null)
              _info(Icons.schedule, 'Beginn: $startT Uhr', muted),
            if (e.isSpiel && e.venue != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  border: Border.all(color: (tint ?? theme.hintColor)),
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text(
                  e.venue!.label.toUpperCase(),
                  style: const TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
          ],
        ),
      ],
    );

    return Container(
      decoration: BoxDecoration(
        color: tint?.withValues(alpha: 0.12) ?? theme.colorScheme.surface,
        border: Border(
          left: BorderSide(
            color: e.tentative ? _amber : (tint ?? theme.dividerColor),
            width: e.tentative ? 4 : 3,
          ),
          bottom: BorderSide(color: theme.dividerColor),
          right: BorderSide(color: theme.dividerColor),
        ),
        borderRadius: isLast
            ? const BorderRadius.vertical(bottom: Radius.circular(8))
            : null,
      ),
      child: InkWell(
        onTap: canEdit ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              dateBlock,
              const SizedBox(width: 8),
              Expanded(child: details),
              if (canEdit)
                PopupMenuButton<String>(
                  tooltip: 'Termin-Aktionen',
                  onSelected: (v) {
                    switch (v) {
                      case 'up':
                        onMove(-1);
                      case 'down':
                        onMove(1);
                      case 'tent':
                        onToggleTentative();
                      case 'dup':
                        onDuplicate();
                      case 'del':
                        onRemove();
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'up',
                      enabled: !isFirst,
                      child: const Text('Nach oben'),
                    ),
                    PopupMenuItem(
                      value: 'down',
                      enabled: !isLast,
                      child: const Text('Nach unten'),
                    ),
                    PopupMenuItem(
                      value: 'tent',
                      child: Text(
                        e.tentative
                            ? 'Nicht mehr fraglich'
                            : 'Als fraglich markieren',
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'dup',
                      child: Text('Duplizieren'),
                    ),
                    const PopupMenuItem(
                      value: 'del',
                      child: Text(
                        'Termin löschen',
                        style: TextStyle(color: Colors.red),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _info(IconData icon, String text, Color? color) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 14, color: color),
      const SizedBox(width: 3),
      Text(
        text,
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    ],
  );
}

/// Bearbeiten eines Termins (Bottom-Sheet).
class _EntrySheet extends StatefulWidget {
  const _EntrySheet({required this.entry});
  final PrepPlanEntry entry;

  @override
  State<_EntrySheet> createState() => _EntrySheetState();
}

class _EntrySheetState extends State<_EntrySheet> {
  late PrepPlanEntry _e = widget.entry;
  late final _custom = TextEditingController(
    text: widget.entry.customAnlassLabel ?? '',
  );
  late final _opponent = TextEditingController(
    text: widget.entry.opponent ?? '',
  );
  late final _address = TextEditingController(text: widget.entry.address ?? '');
  late final _meetLoc = TextEditingController(
    text: widget.entry.meetLocation ?? '',
  );

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

  Future<String?> _pickTime(String? current) async {
    TimeOfDay init = const TimeOfDay(hour: 18, minute: 0);
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

  Widget _timeField(
    String label,
    String? value,
    void Function(String?) onChanged,
  ) {
    final v = visiblePrepTime(value);
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
        suffixIcon: v == null
            ? null
            : IconButton(
                tooltip: 'Uhrzeit entfernen',
                icon: const Icon(Icons.clear, size: 18),
                onPressed: () => onChanged(null),
              ),
      ),
      child: InkWell(
        onTap: () async {
          final t = await _pickTime(value);
          if (t != null) onChanged(t);
        },
        child: Text(v == null ? '– wählen –' : '$v Uhr'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = _e.day;
    final spiel = _e.anlass == PrepAnlass.spiel;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Termin bearbeiten',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, _result()),
                  child: const Text('Fertig'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _pickDate,
              icon: const Icon(Icons.event),
              label: Text(
                d == null
                    ? 'Datum wählen'
                    : DateFormat('EEEE, dd.MM.yyyy', 'de_DE').format(d),
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _e.tentative,
              onChanged: (v) => setState(() => _e = _e.copyWith(tentative: v)),
              title: const Text('Fraglich'),
              subtitle: const Text('Termin steht noch nicht fest'),
            ),
            const SizedBox(height: 4),
            SegmentedButton<PrepAnlass>(
              segments: const [
                ButtonSegment(
                  value: PrepAnlass.training,
                  label: Text('Training'),
                ),
                ButtonSegment(value: PrepAnlass.spiel, label: Text('Spiel')),
                ButtonSegment(
                  value: PrepAnlass.sonstiges,
                  label: Text('Sonstiges'),
                ),
              ],
              selected: {_e.anlass},
              onSelectionChanged: (s) =>
                  setState(() => _e = _e.copyWith(anlass: s.first)),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _custom,
              decoration: InputDecoration(
                labelText: _e.anlass == PrepAnlass.sonstiges
                    ? 'Anlass eintragen'
                    : 'Zusatz (z. B. intensiv)',
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            if (spiel) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _opponent,
                decoration: const InputDecoration(
                  labelText: 'Gegner',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              SegmentedButton<PrepVenue?>(
                segments: const [
                  ButtonSegment(value: null, label: Text('—')),
                  ButtonSegment(value: PrepVenue.home, label: Text('Heim')),
                  ButtonSegment(value: PrepVenue.away, label: Text('Auswärts')),
                  ButtonSegment(value: PrepVenue.open, label: Text('Offen')),
                ],
                selected: {_e.venue},
                onSelectionChanged: (s) =>
                    setState(() => _e = _e.copyWith(venue: s.first)),
              ),
              if (_e.venue == PrepVenue.away) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _address,
                  decoration: const InputDecoration(
                    labelText: 'Adresse / Sportanlage',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ],
            ],
            const SizedBox(height: 16),
            Text('Treffpunkt', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _timeField(
                    'Uhrzeit',
                    _e.meetTime,
                    (v) => setState(() => _e = _e.copyWith(meetTime: v)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _meetLoc,
                    decoration: const InputDecoration(
                      labelText: 'Ort',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _timeField(
              'Beginn',
              _e.time,
              (v) => setState(() => _e = _e.copyWith(time: v)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Vorbereitungsbilanz (wie am Ende des Studio-Drucks).
class _StatsView extends StatelessWidget {
  const _StatsView({required this.entries});
  final List<PrepPlanEntry> entries;

  @override
  Widget build(BuildContext context) {
    bool spiel(PrepPlanEntry e) => e.anlass == PrepAnlass.spiel;
    final home = entries
        .where((e) => spiel(e) && e.venue == PrepVenue.home)
        .length;
    final away = entries
        .where((e) => spiel(e) && e.venue == PrepVenue.away)
        .length;
    final open = entries
        .where((e) => spiel(e) && (e.venue == PrepVenue.open || e.venue == null))
        .length;
    final training = entries
        .where((e) => e.anlass == PrepAnlass.training)
        .length;
    final sonst = entries
        .where((e) => e.anlass == PrepAnlass.sonstiges)
        .length;
    final fraglich = entries.where((e) => e.tentative).length;

    Widget card(String label, String value, Color color, {String? sub}) =>
        Container(
          width: 132,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            border: Border.all(color: color.withValues(alpha: 0.6)),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label.toUpperCase(),
                style: TextStyle(
                  fontSize: 9.5,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.6,
                  color: Theme.of(context).hintColor,
                ),
              ),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                ),
              ),
              if (sub != null)
                Text(
                  sub,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.only(bottom: 4),
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: Theme.of(context).colorScheme.primary,
                width: 2,
              ),
            ),
          ),
          child: Text(
            'VORBEREITUNGSBILANZ',
            style: TextStyle(
              fontWeight: FontWeight.w900,
              letterSpacing: 1.2,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            card('Termine gesamt', '${entries.length}', Colors.grey),
            card(
              'Spiele',
              '${home + away + open}',
              _tintHome,
              sub: '$home H · $away A${open > 0 ? ' · $open O' : ''}',
            ),
            card('Trainingseinheiten', '$training', _tintTraining),
            card('Sondertermine', '$sonst', _tintAway),
            card('Heim / Auswärts', '$home / $away', Colors.grey),
            card('Fraglich', '$fraglich', _amber),
          ],
        ),
      ],
    );
  }
}
