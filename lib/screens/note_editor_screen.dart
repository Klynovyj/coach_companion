import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/match.dart';
import '../models/note_category.dart';
import '../models/player_note.dart';
import '../state/app_state.dart';
import '../utils/rich_note.dart';

/// Ergebnis des Notiz-Editors: formatierter Inhalt (Delta-JSON) + Rubrik +
/// optional verknüpftes Spiel.
class NoteEditResult {
  final String stored;
  final String? categoryId;
  final String? matchId;
  const NoteEditResult(this.stored, this.categoryId, this.matchId);
}

/// Vollbild-Editor für eine Spieler-Notiz mit voller Textformatierung
/// (Überschriften, Fett/Kursiv/Unterstrichen/Durchgestrichen, Listen,
/// Checklisten, Einrückung …) – im Stil von Google Notizen.
class NoteEditorScreen extends StatefulWidget {
  const NoteEditorScreen({
    super.key,
    required this.playerName,
    this.existing,
    this.matches = const [],
  });

  final String playerName;
  final PlayerNote? existing;

  /// Auswählbare Spiele (neueste zuerst) zum Verknüpfen.
  final List<GameMatch> matches;

  @override
  State<NoteEditorScreen> createState() => _NoteEditorScreenState();
}

class _NoteEditorScreenState extends State<NoteEditorScreen> {
  late final QuillController _controller;
  final FocusNode _focusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();

  List<NoteCategory> _categories = [];
  String? _categoryId;
  String? _matchId;
  bool _loadingCats = true;

  @override
  void initState() {
    super.initState();
    final doc = RichNote.documentFrom(widget.existing?.text);
    _controller = QuillController(
      document: doc,
      selection: const TextSelection.collapsed(offset: 0),
    );
    _categoryId = widget.existing?.categoryId;
    _matchId = widget.existing?.matchId;
    _loadCategories();
  }

  Future<void> _loadCategories() async {
    final cats = await context.read<AppState>().noteCategories();
    if (!mounted) return;
    setState(() {
      _categories = cats;
      // Rubrik nur behalten, wenn sie noch existiert.
      if (_categoryId != null && !cats.any((c) => c.id == _categoryId)) {
        _categoryId = null;
      }
      _loadingCats = false;
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _save() {
    if (RichNote.isEmpty(RichNote.encode(_controller.document))) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Die Notiz ist leer.')));
      return;
    }
    // Nur ein noch existierendes Spiel verknüpfen.
    final matchId = widget.matches.any((m) => m.id == _matchId)
        ? _matchId
        : null;
    Navigator.pop(
      context,
      NoteEditResult(
        RichNote.encode(_controller.document),
        _categoryId,
        matchId,
      ),
    );
  }

  static final _dfMatch = DateFormat('dd.MM.yyyy', 'de_DE');

  String _matchDate(GameMatch m) =>
      m.kickoff == null ? '' : _dfMatch.format(m.kickoff!);

  /// Label inkl. Datum: „vs Gegner · 18.10.2025".
  String _matchLabel(GameMatch m) {
    final d = _matchDate(m);
    return d.isEmpty ? 'vs ${m.opponentName}' : 'vs ${m.opponentName}  ·  $d';
  }

  /// Durchsuchbares Auswahl-Sheet für das zu verknüpfende Spiel (mit Datum).
  Future<void> _pickMatch() async {
    final selected = await showModalBottomSheet<String?>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        var query = '';
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            final q = query.trim().toLowerCase();
            final filtered = q.isEmpty
                ? widget.matches
                : widget.matches
                      .where(
                        (m) =>
                            m.opponentName.toLowerCase().contains(q) ||
                            _matchDate(m).contains(q),
                      )
                      .toList();
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(ctx).viewInsets.bottom,
              ),
              child: SizedBox(
                height: MediaQuery.of(ctx).size.height * 0.7,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: TextField(
                        autofocus: true,
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search),
                          hintText: 'Spiel suchen (Gegner oder Datum)…',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        onChanged: (v) => setSheet(() => query = v),
                      ),
                    ),
                    Expanded(
                      child: ListView(
                        children: [
                          ListTile(
                            leading: const Icon(Icons.block),
                            title: const Text('Kein Spiel'),
                            onTap: () => Navigator.pop(ctx, '__none__'),
                          ),
                          const Divider(height: 1),
                          for (final m in filtered)
                            ListTile(
                              selected: m.id == _matchId,
                              leading: const Icon(Icons.sports_soccer),
                              title: Text('vs ${m.opponentName}'),
                              subtitle: _matchDate(m).isEmpty
                                  ? null
                                  : Text(_matchDate(m)),
                              onTap: () => Navigator.pop(ctx, m.id),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    if (selected == null || !mounted) return;
    setState(() => _matchId = selected == '__none__' ? null : selected);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.existing == null ? 'Neue Notiz' : 'Notiz bearbeiten'),
            Text(
              widget.playerName,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(
                  context,
                ).colorScheme.onPrimary.withValues(alpha: 0.85),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text(
              'Speichern',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Rubrik-Auswahl
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: _loadingCats
                ? const SizedBox(height: 4, child: LinearProgressIndicator())
                : DropdownButtonFormField<String?>(
                    initialValue: _categoryId,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Kategorie',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('Ohne Kategorie'),
                      ),
                      ..._categories.map(
                        (c) => DropdownMenuItem<String?>(
                          value: c.id,
                          child: Text(c.name),
                        ),
                      ),
                    ],
                    onChanged: (v) => setState(() => _categoryId = v),
                  ),
          ),
          // Spiel verknüpfen (optional) – durchsuchbares Sheet mit Datum.
          if (widget.matches.isNotEmpty)
            Builder(
              builder: (context) {
                final linked = widget.matches.cast<GameMatch?>().firstWhere(
                  (m) => m?.id == _matchId,
                  orElse: () => null,
                );
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: InkWell(
                    onTap: _pickMatch,
                    child: InputDecorator(
                      decoration: InputDecoration(
                        labelText: 'Spiel verknüpfen (optional)',
                        border: const OutlineInputBorder(),
                        isDense: true,
                        prefixIcon: const Icon(Icons.sports_soccer, size: 20),
                        suffixIcon: linked == null
                            ? const Icon(Icons.search)
                            : IconButton(
                                icon: const Icon(Icons.clear),
                                tooltip: 'Verknüpfung entfernen',
                                onPressed: () =>
                                    setState(() => _matchId = null),
                              ),
                      ),
                      child: Text(
                        linked == null ? 'Kein Spiel' : _matchLabel(linked),
                        style: TextStyle(
                          color: linked == null
                              ? Theme.of(context).hintColor
                              : null,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          // Formatierungsleiste
          // Bewusst schlank: nur Fett/Kursiv/Unterstreichen, Listen & Haken –
          // kein Farbdialog, keine Überschriften/Einrückung/Ausrichtung.
          QuillSimpleToolbar(
            controller: _controller,
            config: const QuillSimpleToolbarConfig(
              showFontFamily: false,
              showFontSize: false,
              showInlineCode: false,
              showSubscript: false,
              showSuperscript: false,
              showSmallButton: false,
              showCodeBlock: false,
              showSearchButton: false,
              showLink: false,
              showColorButton: false,
              showBackgroundColorButton: false,
              showStrikeThrough: false,
              showHeaderStyle: false,
              showQuote: false,
              showIndent: false,
              showAlignmentButtons: false,
              showClearFormat: false,
              showDividers: false,
              multiRowsDisplay: false,
            ),
          ),
          const Divider(height: 1),
          // Editor – füllt die Höhe; Tippen irgendwo im Bereich fokussiert.
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _focusNode.requestFocus(),
              child: Container(
                color: Theme.of(context).colorScheme.surface,
                padding: const EdgeInsets.all(16),
                child: QuillEditor.basic(
                  controller: _controller,
                  focusNode: _focusNode,
                  scrollController: _scrollController,
                  config: const QuillEditorConfig(
                    placeholder: 'Beobachtung, Hinweis, Checkliste …',
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
    );
  }
}
