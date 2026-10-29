import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../../models/drill_diagram.dart';
import '../../models/exercise.dart';
import '../../state/app_state.dart';
import '../../widgets/team_logo.dart';
import 'drill_diagram_editor.dart';

/// Übung anlegen oder bearbeiten.
class ExerciseEditorScreen extends StatefulWidget {
  const ExerciseEditorScreen({super.key, this.initial});

  final Exercise? initial;

  @override
  State<ExerciseEditorScreen> createState() => _ExerciseEditorScreenState();
}

class _ExerciseEditorScreenState extends State<ExerciseEditorScreen> {
  late final _title = TextEditingController(text: widget.initial?.title ?? '');
  late final _aufbau = TextEditingController(
    text: widget.initial?.aufbau ?? '',
  );
  late final _ablauf = TextEditingController(
    text: widget.initial?.ablauf ?? '',
  );
  late final _coaching = TextEditingController(
    text: widget.initial?.coachingPoints ?? '',
  );
  late final _varianten = TextEditingController(
    text: widget.initial?.varianten ?? '',
  );
  late final _material = TextEditingController(
    text: widget.initial?.material ?? '',
  );
  late final _minPlayers = TextEditingController(
    text: widget.initial?.minPlayers?.toString() ?? '',
  );
  late final _duration = TextEditingController(
    text: widget.initial?.durationMin?.toString() ?? '',
  );

  late final List<String> _categories = List.of(
    widget.initial?.categories ?? const [],
  );
  late bool _needsGk = widget.initial?.needsGoalkeeper ?? false;
  late DrillDiagram _diagram = widget.initial?.diagram ?? const DrillDiagram();
  late final List<String> _videoLinks = List.of(
    widget.initial?.videoLinks ?? const [],
  );
  late String? _sketchPhoto = widget.initial?.sketchPhotoUrl;
  bool _saving = false;

  Future<void> _addCategory() async {
    final ctrl = TextEditingController();
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Trainingsart'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'z.B. Taktik, Standards, Laufintensiv',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Hinzufügen'),
          ),
        ],
      ),
    );
    if (v == null || v.isEmpty) return;
    setState(() {
      if (!_categories.contains(v)) _categories.add(v);
    });
  }

  Future<void> _addVideo() async {
    final ctrl = TextEditingController();
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Video-Link'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'YouTube- oder Instagram-Link',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Hinzufügen'),
          ),
        ],
      ),
    );
    if (v == null || v.isEmpty) return;
    setState(() => _videoLinks.add(v));
  }

  Future<void> _pickPhoto() async {
    final picker = ImagePicker();
    final file = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 90,
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return;
    final resized = decoded.width > 1400
        ? img.copyResize(decoded, width: 1400)
        : decoded;
    final jpg = img.encodeJpg(resized, quality: 82);
    if (!mounted) return;
    setState(
      () => _sketchPhoto = 'data:image/jpeg;base64,${base64Encode(jpg)}',
    );
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bitte einen Titel angeben.')),
      );
      return;
    }
    setState(() => _saving = true);
    final now = DateTime.now();
    final base =
        widget.initial ??
        Exercise(
          id: const Uuid().v4(),
          title: title,
          createdAt: now,
          updatedAt: now,
        );
    final ex = base.copyWith(
      title: title,
      categories: _categories,
      aufbau: _aufbau.text.trim(),
      ablauf: _ablauf.text.trim(),
      coachingPoints: _coaching.text.trim(),
      varianten: _varianten.text.trim(),
      minPlayers: int.tryParse(_minPlayers.text.trim()),
      clearMinPlayers: _minPlayers.text.trim().isEmpty,
      needsGoalkeeper: _needsGk,
      durationMin: int.tryParse(_duration.text.trim()),
      clearDuration: _duration.text.trim().isEmpty,
      material: _material.text.trim(),
      diagram: _diagram.isEmpty ? null : _diagram,
      clearDiagram: _diagram.isEmpty,
      videoLinks: _videoLinks,
      sketchPhotoUrl: _sketchPhoto,
      clearSketchPhoto: _sketchPhoto == null,
      updatedAt: now,
    );
    await context.read<AppState>().upsertExercise(ex);
    if (mounted) Navigator.pop(context, ex);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.initial == null ? 'Neue Übung' : 'Übung bearbeiten'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: const Text(
              'Speichern',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 28),
        children: [
          TextField(
            controller: _title,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Titel',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          _label('Trainingsart'),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final c in _categories)
                InputChip(
                  label: Text(c),
                  onDeleted: () => setState(() => _categories.remove(c)),
                ),
              ActionChip(
                avatar: const Icon(Icons.add, size: 16),
                label: const Text('Art'),
                onPressed: _addCategory,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _minPlayers,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'min. Spieler',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _duration,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Dauer (Min)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Torwart nötig'),
            value: _needsGk,
            onChanged: (v) => setState(() => _needsGk = v),
          ),
          const SizedBox(height: 4),
          _field(_aufbau, 'Aufbau'),
          _field(_ablauf, 'Ablauf'),
          _field(_coaching, 'Coaching-Punkte'),
          _field(_varianten, 'Varianten'),
          _field(_material, 'Material', lines: 2),
          const SizedBox(height: 12),
          _label('Skizze'),
          DrillDiagramEditor(initial: _diagram, onChanged: (d) => _diagram = d),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(child: _label('Video-Links')),
              TextButton.icon(
                onPressed: _addVideo,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Link'),
              ),
            ],
          ),
          for (final link in _videoLinks)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.ondemand_video),
              title: Text(link, maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => launchUrl(
                Uri.parse(link),
                mode: LaunchMode.externalApplication,
              ),
              trailing: IconButton(
                icon: const Icon(Icons.close, size: 18),
                onPressed: () => setState(() => _videoLinks.remove(link)),
              ),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _label('Original-Skizzenfoto')),
              TextButton.icon(
                onPressed: _pickPhoto,
                icon: const Icon(Icons.add_a_photo, size: 18),
                label: Text(_sketchPhoto == null ? 'Foto' : 'Ersetzen'),
              ),
            ],
          ),
          if (_sketchPhoto != null)
            Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(
                    TeamLogo.decode(_sketchPhoto)!,
                    height: 160,
                    width: double.infinity,
                    fit: BoxFit.cover,
                  ),
                ),
                Positioned(
                  top: 4,
                  right: 4,
                  child: IconButton.filledTonal(
                    icon: const Icon(Icons.delete, size: 18),
                    onPressed: () => setState(() => _sketchPhoto = null),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _label(String t) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(t, style: const TextStyle(fontWeight: FontWeight.w600)),
  );

  Widget _field(TextEditingController c, String label, {int lines = 3}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(
          controller: c,
          minLines: lines,
          maxLines: lines + 4,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
            alignLabelWithHint: true,
          ),
        ),
      );
}
