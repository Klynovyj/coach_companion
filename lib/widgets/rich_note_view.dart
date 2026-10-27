import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

import '../utils/rich_note.dart';

/// Schreibgeschützte Darstellung einer formatierten Notiz (flutter_quill).
/// Zeigt Überschriften, Listen, Checklisten und Zeichen-Formatierung an,
/// ohne Bearbeitung – fürs Antippen zum Bearbeiten ist der Aufrufer zuständig.
class RichNoteView extends StatefulWidget {
  const RichNoteView({super.key, required this.stored});

  /// Gespeicherter Wert (Delta-JSON oder Klartext aus Altbestand).
  final String stored;

  @override
  State<RichNoteView> createState() => _RichNoteViewState();
}

class _RichNoteViewState extends State<RichNoteView> {
  late QuillController _controller;
  final FocusNode _focusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _controller = _build();
  }

  QuillController _build() => QuillController(
    document: RichNote.documentFrom(widget.stored),
    selection: const TextSelection.collapsed(offset: 0),
    readOnly: true,
  );

  @override
  void didUpdateWidget(covariant RichNoteView old) {
    super.didUpdateWidget(old);
    if (old.stored != widget.stored) {
      _controller.dispose();
      _controller = _build();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return QuillEditor.basic(
      controller: _controller,
      focusNode: _focusNode,
      scrollController: _scrollController,
      config: const QuillEditorConfig(
        showCursor: false,
        autoFocus: false,
        scrollable: false,
        enableInteractiveSelection: false,
        padding: EdgeInsets.zero,
      ),
    );
  }
}
