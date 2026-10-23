import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/fupa/fupa_dtos.dart';
import '../services/paste/squad_paste_parser.dart';
import '../state/app_state.dart';

/// Editierbare Zeile im Vorschau-Schritt.
class _EditableRow {
  final TextEditingController first;
  final TextEditingController last;
  final TextEditingController number;
  final TextEditingController position;
  bool selected;

  _EditableRow(ParsedPlayer p)
      : first = TextEditingController(text: p.firstName),
        last = TextEditingController(text: p.lastName),
        number =
            TextEditingController(text: p.number?.toString() ?? ''),
        position = TextEditingController(text: p.position ?? ''),
        selected = true;

  bool get hasName =>
      first.text.trim().isNotEmpty || last.text.trim().isNotEmpty;

  void dispose() {
    first.dispose();
    last.dispose();
    number.dispose();
    position.dispose();
  }

  PlayerData toData() => PlayerData(
        firstName: first.text.trim(),
        lastName: last.text.trim(),
        number: int.tryParse(number.text.trim()),
        position: position.text.trim().isEmpty ? null : position.text.trim(),
      );
}

/// Einfügen-Import für einen Kader (eigenes Team oder Gegner).
class PasteImportScreen extends StatefulWidget {
  const PasteImportScreen({
    super.key,
    required this.teamId,
    required this.teamName,
    this.fupaUrl,
  });

  final String teamId;
  final String teamName;
  final String? fupaUrl;

  @override
  State<PasteImportScreen> createState() => _PasteImportScreenState();
}

class _PasteImportScreenState extends State<PasteImportScreen> {
  final _textController = TextEditingController();
  List<_EditableRow>? _rows;

  @override
  void dispose() {
    _textController.dispose();
    for (final r in _rows ?? const <_EditableRow>[]) {
      r.dispose();
    }
    super.dispose();
  }

  void _analyze() {
    final parsed = SquadPasteParser.parse(_textController.text);
    for (final r in _rows ?? const <_EditableRow>[]) {
      r.dispose();
    }
    setState(() {
      _rows = parsed.map(_EditableRow.new).toList();
    });
    if (parsed.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'Keine Spieler erkannt. Tipp: eine Zeile pro Spieler einfügen.')),
      );
    }
  }

  void _addEmptyRow() {
    setState(() {
      (_rows ??= []).add(_EditableRow(const ParsedPlayer()));
    });
  }

  Future<void> _import() async {
    final rows = _rows ?? const <_EditableRow>[];
    final selected = rows.where((r) => r.selected && r.hasName).toList();
    if (selected.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Keine Spieler mit Namen ausgewählt.')),
      );
      return;
    }
    final data = selected.map((r) => r.toData()).toList();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final added =
        await context.read<AppState>().importPastedPlayers(widget.teamId, data);
    messenger.showSnackBar(
      SnackBar(
          content: Text(
              '${data.length} Spieler übernommen ($added neu, ${data.length - added} aktualisiert).')),
    );
    navigator.pop(added);
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return Scaffold(
      appBar: AppBar(
        title: Text('Einfügen · ${widget.teamName}'),
        actions: [
          if (rows != null)
            TextButton(
              onPressed: _import,
              child: const Text('Übernehmen',
                  style: TextStyle(color: Colors.white)),
            ),
        ],
      ),
      body: rows == null ? _buildInput() : _buildPreview(rows),
      floatingActionButton: rows == null
          ? null
          : FloatingActionButton.small(
              onPressed: _addEmptyRow,
              tooltip: 'Leere Zeile hinzufügen',
              child: const Icon(Icons.add),
            ),
    );
  }

  Widget _buildInput() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Kopiere die Spielerliste (z.B. von der öffentlichen FuPa-Seite) '
          'und füge sie hier ein – eine Zeile pro Spieler. Erkannt werden '
          'Nummer, Name und Position. Du kannst danach alles prüfen und '
          'korrigieren.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 8),
        Text(
          'Hinweis: Die App ruft nichts von FuPa ab – sie liest nur deinen '
          'eingefügten Text.',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(fontStyle: FontStyle.italic),
        ),
        const SizedBox(height: 16),
        if (widget.fupaUrl != null)
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: () => _openUrl(widget.fupaUrl!),
              icon: const Icon(Icons.open_in_new),
              label: const Text('FuPa-Seite öffnen'),
            ),
          ),
        const SizedBox(height: 12),
        TextField(
          controller: _textController,
          minLines: 8,
          maxLines: 20,
          decoration: const InputDecoration(
            labelText: 'Spielerliste einfügen',
            alignLabelWithHint: true,
            hintText: '7 Max Mustermann Sturm\n1 Jonas Keller Tor\n...',
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _analyze,
          icon: const Icon(Icons.auto_fix_high),
          label: const Text('Erkennen'),
        ),
      ],
    );
  }

  Widget _buildPreview(List<_EditableRow> rows) {
    final selectedCount = rows.where((r) => r.selected && r.hasName).length;
    return Column(
      children: [
        Container(
          width: double.infinity,
          color: Theme.of(context).colorScheme.primaryContainer,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Text('$selectedCount von ${rows.length} werden übernommen'),
              ),
              TextButton(
                onPressed: () => setState(() {
                  final allOn = rows.every((r) => r.selected);
                  for (final r in rows) {
                    r.selected = !allOn;
                  }
                }),
                child: const Text('Alle/Keine'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.only(bottom: 88),
            itemCount: rows.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) => _rowTile(rows[i]),
          ),
        ),
      ],
    );
  }

  Widget _rowTile(_EditableRow row) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Checkbox(
            value: row.selected,
            onChanged: (v) => setState(() => row.selected = v ?? false),
          ),
          SizedBox(
            width: 44,
            child: TextField(
              controller: row.number,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              decoration: const InputDecoration(hintText: 'Nr', isDense: true),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: row.first,
                        decoration: const InputDecoration(
                            hintText: 'Vorname', isDense: true),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: TextField(
                        controller: row.last,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                            hintText: 'Nachname', isDense: true),
                      ),
                    ),
                  ],
                ),
                TextField(
                  controller: row.position,
                  decoration: const InputDecoration(
                      hintText: 'Position', isDense: true),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}
