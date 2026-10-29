import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../../models/drill_diagram.dart';
import '../../models/exercise.dart';
import '../../services/cloud_service.dart';
import '../../state/app_state.dart';
import '../../widgets/drill_diagram_view.dart';
import '../../widgets/photo_viewer.dart';
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
  late final _goalkeepers = TextEditingController(
    text: widget.initial?.goalkeepers?.toString() ?? '',
  );
  late final _duration = TextEditingController(
    text: widget.initial?.durationMin?.toString() ?? '',
  );

  late final List<String> _categories = List.of(
    widget.initial?.categories ?? const [],
  );
  late DrillDiagram _diagram = widget.initial?.diagram ?? const DrillDiagram();
  late final List<String> _videoLinks = List.of(
    widget.initial?.videoLinks ?? const [],
  );
  late String? _sketchPhoto = widget.initial?.sketchPhotoUrl;
  int _diagramKey = 0;
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

  /// Wählt ein Bild aus der Galerie und liefert es als (verkleinerte) Data-URL.
  Future<String?> _pickImageDataUrl() async {
    final picker = ImagePicker();
    final file = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 90,
    );
    if (file == null) return null;
    final bytes = await file.readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;
    final resized = decoded.width > 1400
        ? img.copyResize(decoded, width: 1400)
        : decoded;
    final jpg = img.encodeJpg(resized, quality: 82);
    return 'data:image/jpeg;base64,${base64Encode(jpg)}';
  }

  Future<void> _pickPhoto() async {
    final url = await _pickImageDataUrl();
    if (url == null || !mounted) return;
    setState(() => _sketchPhoto = url);
  }

  /// Skizze immer im Vollbild-Editor bearbeiten (mit allen Funktionen).
  Future<void> _editDiagram() async {
    final res = await editDiagramFullscreen(context, _diagram);
    if (res != null && mounted) {
      setState(() {
        _diagram = res;
        _diagramKey++;
      });
    }
  }

  // ---------------------------------------------------------------- KI
  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  /// Übernimmt einen KI-Entwurf in die Felder (zum Prüfen/Bearbeiten).
  void _applyDraft(Map<String, dynamic> d) {
    void setIf(TextEditingController c, Object? v) {
      final s = (v as String?)?.trim();
      if (s != null && s.isNotEmpty) c.text = s;
    }

    setState(() {
      setIf(_title, d['title']);
      final cats = d['categories'];
      if (cats is List) {
        for (final c in cats) {
          final s = c.toString().trim();
          if (s.isNotEmpty && !_categories.contains(s)) _categories.add(s);
        }
      }
      setIf(_aufbau, d['aufbau']);
      setIf(_ablauf, d['ablauf']);
      setIf(_coaching, d['coachingPoints']);
      setIf(_varianten, d['varianten']);
      setIf(_material, d['material']);
      final mp = d['minPlayers'];
      if (mp is num) _minPlayers.text = mp.toInt().toString();
      final du = d['durationMin'];
      if (du is num) _duration.text = du.toInt().toString();
      final gkn = d['goalkeepers'];
      if (gkn is num) {
        _goalkeepers.text = gkn.toInt().toString();
      } else if (d['needsGoalkeeper'] == true &&
          _goalkeepers.text.trim().isEmpty) {
        _goalkeepers.text = '1';
      }
      final dia = d['diagram'];
      if (dia is Map) {
        final parsed = DrillDiagram.fromJson(Map<String, dynamic>.from(dia));
        if (!parsed.isEmpty) {
          _diagram = parsed.tidy(); // Überlappungen auseinanderziehen
          _diagramKey++; // Editor mit neuem Diagramm neu aufbauen
        }
      }
    });
  }

  Future<void> _runAi(Map<String, dynamic> body) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Expanded(child: Text('KI denkt nach …')),
          ],
        ),
      ),
    );
    try {
      final draft = await CloudService.aiCoach(body);
      if (mounted) Navigator.pop(context); // Spinner
      if (draft == null) {
        _snack('Keine Antwort von der KI.');
        return;
      }
      _applyDraft(draft);
      _snack('KI-Entwurf eingefügt – prüfen und speichern.');
    } catch (e) {
      if (mounted) Navigator.pop(context);
      _snack('KI-Fehler: $e');
    }
  }

  Map<String, dynamic> get _ctx => {
    'players': _minPlayers.text.trim(),
    'goalkeepers': _goalkeepers.text.trim(),
    'categories': _categories,
  };

  void _kiSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'KI-Co-Trainer',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.auto_awesome),
              title: const Text('Übung vorschlagen'),
              subtitle: const Text('Die KI erfindet eine passende Übung'),
              onTap: () {
                Navigator.pop(ctx);
                _kiGenerate();
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_note),
              title: const Text('Aus Stichpunkten'),
              subtitle: const Text('Deine Notizen ausformulieren'),
              onTap: () {
                Navigator.pop(ctx);
                _kiBullets();
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera),
              title: const Text('Aus Skizzen-Foto'),
              subtitle: const Text('Foto einer Zeichnung analysieren'),
              onTap: () {
                Navigator.pop(ctx);
                _kiPhoto();
              },
            ),
            ListTile(
              leading: const Icon(Icons.ondemand_video),
              title: const Text('Aus Video-Infos'),
              subtitle: const Text('Titel/Beschreibung eines Videos'),
              onTap: () {
                Navigator.pop(ctx);
                _kiVideo();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<String?> _prompt(String title, String hint, {int lines = 1}) async {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          minLines: lines,
          maxLines: lines + 4,
          decoration: InputDecoration(hintText: hint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Los'),
          ),
        ],
      ),
    );
  }

  Future<void> _kiGenerate() async {
    final focus = await _prompt(
      'Übung vorschlagen',
      'Fokus/Wunsch (optional), z.B. Pressing, Abschluss …',
    );
    if (focus == null) return;
    await _runAi({
      ..._ctx,
      'mode': 'generate',
      'focus': focus,
      'duration': _duration.text.trim(),
    });
  }

  Future<void> _kiBullets() async {
    final bullets = await _prompt(
      'Aus Stichpunkten',
      'Deine Stichpunkte zur Übung …',
      lines: 4,
    );
    if (bullets == null || bullets.isEmpty) return;
    await _runAi({..._ctx, 'mode': 'bullets', 'bullets': bullets});
  }

  Future<void> _kiPhoto() async {
    final url = await _pickImageDataUrl();
    if (url == null) return;
    setState(() => _sketchPhoto = url);
    await _runAi({..._ctx, 'mode': 'photo', 'image': url});
  }

  Future<void> _kiVideo() async {
    final info = await _prompt(
      'Aus Video-Infos',
      'Titel/Beschreibung/Transkript des Videos einfügen …',
      lines: 4,
    );
    if (info == null || info.isEmpty) return;
    await _runAi({..._ctx, 'mode': 'video', 'description': info});
  }

  /// Passt die bestehende Übung per KI an die aktuelle Spieler-/Torwartzahl an.
  Future<void> _kiAdapt() async {
    if (_minPlayers.text.trim().isEmpty) {
      _snack('Bitte zuerst die Spielerzahl (min. Spieler) eintragen.');
      return;
    }
    await _runAi({
      ..._ctx,
      'mode': 'adapt',
      'title': _title.text.trim(),
      'aufbau': _aufbau.text.trim(),
      'ablauf': _ablauf.text.trim(),
      'coachingPoints': _coaching.text.trim(),
      'varianten': _varianten.text.trim(),
      'material': _material.text.trim(),
    });
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
      goalkeepers: int.tryParse(_goalkeepers.text.trim()),
      clearGoalkeepers: _goalkeepers.text.trim().isEmpty,
      needsGoalkeeper: (int.tryParse(_goalkeepers.text.trim()) ?? 0) > 0,
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
          IconButton(
            tooltip: 'KI-Co-Trainer',
            icon: const Icon(Icons.auto_awesome),
            onPressed: _kiSheet,
          ),
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
                    labelText: 'min. Feldspieler',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _goalkeepers,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Torhüter',
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
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _kiAdapt,
              icon: const Icon(Icons.autorenew, size: 18),
              label: const Text('An Spieleranzahl anpassen (KI)'),
            ),
          ),
          const SizedBox(height: 4),
          _field(_aufbau, 'Aufbau'),
          _field(_ablauf, 'Ablauf'),
          _field(_coaching, 'Coaching-Punkte'),
          _field(_varianten, 'Varianten'),
          _field(_material, 'Material', lines: 2),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _label('Skizze')),
              TextButton.icon(
                onPressed: _editDiagram,
                icon: const Icon(Icons.edit, size: 18),
                label: const Text('Bearbeiten'),
              ),
            ],
          ),
          GestureDetector(
            onTap: _editDiagram,
            child: _diagram.isEmpty
                ? Container(
                    height: 150,
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    alignment: Alignment.center,
                    child: const Text(
                      'Tippen zum Zeichnen (Vollbild)',
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : DrillDiagramView(
                    key: ValueKey(_diagramKey),
                    diagram: _diagram,
                  ),
          ),
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
                GestureDetector(
                  onTap: () => showPhotoFullscreen(
                    context,
                    TeamLogo.decode(_sketchPhoto)!,
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.memory(
                      TeamLogo.decode(_sketchPhoto)!,
                      height: 160,
                      width: double.infinity,
                      fit: BoxFit.cover,
                    ),
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
