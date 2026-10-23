import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:provider/provider.dart';

import '../models/note_category.dart';
import '../models/player_note.dart';
import '../state/app_state.dart';
import '../utils/rich_note.dart';

/// Ergebnis des Notiz-Editors: formatierter Inhalt (Delta-JSON) + Rubrik.
class NoteEditResult {
  final String stored;
  final String? categoryId;
  const NoteEditResult(this.stored, this.categoryId);
}

/// Vollbild-Editor für eine Spieler-Notiz mit voller Textformatierung
/// (Überschriften, Fett/Kursiv/Unterstrichen/Durchgestrichen, Listen,
/// Checklisten, Einrückung …) – im Stil von Google Notizen.
class NoteEditorScreen extends StatefulWidget {
  const NoteEditorScreen({
    super.key,
    required this.playerName,
    this.existing,
  });

  final String playerName;
  final PlayerNote? existing;

  @override
  State<NoteEditorScreen> createState() => _NoteEditorScreenState();
}

class _NoteEditorScreenState extends State<NoteEditorScreen> {
  late final QuillController _controller;
  final FocusNode _focusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();

  List<NoteCategory> _categories = [];
  String? _categoryId;
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Die Notiz ist leer.')),
      );
      return;
    }
    Navigator.pop(
      context,
      NoteEditResult(RichNote.encode(_controller.document), _categoryId),
    );
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
                color: Theme.of(context).colorScheme.onPrimary.withValues(
                    alpha: 0.85),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('Speichern',
                style: TextStyle(color: Colors.white)),
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
                          value: null, child: Text('Ohne Kategorie')),
                      ..._categories.map((c) => DropdownMenuItem<String?>(
                          value: c.id, child: Text(c.name))),
                    ],
                    onChanged: (v) => setState(() => _categoryId = v),
                  ),
          ),
          // Formatierungsleiste
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
              multiRowsDisplay: true,
            ),
          ),
          const Divider(height: 1),
          // Editor
          Expanded(
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
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
