import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../models/drill_diagram.dart';
import '../../models/enums.dart';
import '../../models/exercise.dart';
import '../../models/training_session.dart';
import '../../services/cloud_service.dart';
import '../../state/app_state.dart';
import 'exercise_detail_screen.dart';
import 'exercise_library_screen.dart';

/// Einheit planen/bearbeiten: erst Anzahl Feldspieler + Torhüter, dann
/// Trainingsart(en), dann Übungen aus der Bibliothek.
class SessionEditorScreen extends StatefulWidget {
  const SessionEditorScreen({super.key, this.initial});

  final TrainingSession? initial;

  @override
  State<SessionEditorScreen> createState() => _SessionEditorScreenState();
}

class _SessionEditorScreenState extends State<SessionEditorScreen> {
  static const _commonCats = [
    'Aufwärmen',
    'Technik',
    'Taktik',
    'Standards',
    'Laufintensiv',
    'Spielformen',
    'Abschluss',
    'Torwart',
  ];

  late final String _id = widget.initial?.id ?? const Uuid().v4();
  late DateTime _date = widget.initial?.date ?? DateTime.now();
  late final _field = TextEditingController(
    text: widget.initial?.fieldPlayers.toString() ?? '',
  );
  late final _gk = TextEditingController(
    text: widget.initial?.goalkeepers.toString() ?? '',
  );
  late final List<String> _categories = List.of(
    widget.initial?.categories ?? const [],
  );
  List<String> _allCats = List.of(_commonCats);

  final List<SessionItem> _items = [];
  final Map<String, Exercise> _exMap = {};
  Set<String> _originalItemIds = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    final cats = await state.exerciseCategories();
    final merged = {..._commonCats, ...cats}.toList();
    if (widget.initial != null) {
      final items = await state.sessionItems(_id);
      _items.addAll(items);
      _originalItemIds = {for (final i in items) i.id};
      for (final i in items) {
        _exMap[i.exerciseId] =
            await state.exerciseById(i.exerciseId) ??
            Exercise(
              id: i.exerciseId,
              title: '—',
              createdAt: DateTime.now(),
              updatedAt: DateTime.now(),
            );
      }
    } else {
      // Vorschlag aus dem Kader: fitte Feldspieler + Torhüter.
      final team = state.ownTeam;
      if (team != null && _field.text.isEmpty) {
        final players = (await state.playersOf(
          team.id,
        )).where((p) => !p.isStaffOnly && p.status == PlayerStatus.fit);
        final gk = players
            .where((p) => (p.position ?? '').toLowerCase().contains('tor'))
            .length;
        _field.text = (players.length - gk).toString();
        _gk.text = gk.toString();
      }
    }
    if (mounted) {
      setState(() {
        _allCats = merged;
        _loading = false;
      });
    }
  }

  int get _totalMin => _items.fold(
    0,
    (s, i) => s + (i.durationMin ?? _exMap[i.exerciseId]?.durationMin ?? 0),
  );

  void _addToItems(Exercise ex) {
    setState(() {
      _exMap[ex.id] = ex;
      _items.add(
        SessionItem(
          id: const Uuid().v4(),
          sessionId: _id,
          exerciseId: ex.id,
          orderIndex: _items.length,
          durationMin: ex.durationMin,
        ),
      );
    });
  }

  Future<void> _pickExercise() async {
    final ex = await Navigator.push<Exercise>(
      context,
      MaterialPageRoute(
        builder: (_) => ExerciseLibraryScreen(
          pickMode: true,
          forPlayers: int.tryParse(_field.text.trim()),
        ),
      ),
    );
    if (ex != null) _addToItems(ex);
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  /// Vorschläge: erst passende Übungen aus der Bibliothek, dann Option, eine
  /// neue per KI zu generieren.
  Future<void> _suggest() async {
    final state = context.read<AppState>();
    final forPlayers = int.tryParse(_field.text.trim());
    final matches = await state.exercises(
      categories: _categories,
      forPlayers: forPlayers,
    );
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (ctx, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(
                'Vorschläge aus der Bibliothek',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ),
            if (matches.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Keine passende Übung in der Bibliothek. Lass die KI eine erstellen.',
                  style: TextStyle(color: Colors.grey),
                ),
              ),
            for (final ex in matches.take(25))
              ListTile(
                leading: Icon(
                  ex.favorite ? Icons.star : Icons.fitness_center,
                  color: ex.favorite ? Colors.amber : null,
                ),
                title: Text(ex.title),
                subtitle: Text(
                  [
                    if (ex.categories.isNotEmpty) ex.categories.join(', '),
                    if (ex.durationMin != null) '${ex.durationMin} Min',
                  ].join(' · '),
                ),
                trailing: const Icon(Icons.add),
                onTap: () {
                  Navigator.pop(ctx);
                  _addToItems(ex);
                },
              ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.auto_awesome),
              title: const Text('Neue Übung mit KI generieren'),
              subtitle: const Text('Passend zu Spieleranzahl und Trainingsart'),
              onTap: () {
                Navigator.pop(ctx);
                _generateAndAdd();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _generateAndAdd() async {
    final state = context.read<AppState>();
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Expanded(child: Text('KI erstellt eine Übung …')),
          ],
        ),
      ),
    );
    try {
      final draft = await CloudService.aiCoach({
        'mode': 'generate',
        'players': _field.text.trim(),
        'goalkeepers': _gk.text.trim(),
        'categories': _categories,
        'focus': '',
        'duration': '',
      });
      if (!mounted) return;
      Navigator.pop(context); // Spinner
      if (draft == null) {
        _snack('Keine Antwort von der KI.');
        return;
      }
      final ex = _exerciseFromDraft(draft);
      // In der Bibliothek speichern (wiederverwendbar + team-synchron) …
      await state.upsertExercise(ex);
      if (!mounted) return;
      _addToItems(ex); // … und direkt der Einheit hinzufügen.
      _snack('KI-Übung erstellt und hinzugefügt.');
    } catch (e) {
      if (mounted) Navigator.pop(context);
      _snack('KI-Fehler: $e');
    }
  }

  Exercise _exerciseFromDraft(Map<String, dynamic> d) {
    final now = DateTime.now();
    DrillDiagram? dia;
    final dm = d['diagram'];
    if (dm is Map) {
      final parsed = DrillDiagram.fromJson(Map<String, dynamic>.from(dm));
      if (!parsed.isEmpty) dia = parsed.tidy();
    }
    final cats = <String>[];
    final c = d['categories'];
    if (c is List) {
      for (final x in c) {
        final s = x.toString().trim();
        if (s.isNotEmpty) cats.add(s);
      }
    }
    String str(Object? v) => (v as String?)?.trim() ?? '';
    final title = str(d['title']);
    return Exercise(
      id: const Uuid().v4(),
      title: title.isEmpty ? 'KI-Übung' : title,
      categories: cats.isEmpty ? List.of(_categories) : cats,
      aufbau: str(d['aufbau']),
      ablauf: str(d['ablauf']),
      coachingPoints: str(d['coachingPoints']),
      varianten: str(d['varianten']),
      minPlayers: (d['minPlayers'] as num?)?.toInt(),
      needsGoalkeeper: d['needsGoalkeeper'] == true,
      durationMin: (d['durationMin'] as num?)?.toInt(),
      material: str(d['material']),
      diagram: dia,
      source: 'ai',
      createdAt: now,
      updatedAt: now,
    );
  }

  Future<void> _editDuration(int index) async {
    final ctrl = TextEditingController(
      text: _items[index].durationMin?.toString() ?? '',
    );
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Dauer (Minuten)'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    if (v == null) return;
    setState(
      () =>
          _items[index] = _items[index].copyWith(durationMin: int.tryParse(v)),
    );
  }

  Future<void> _addCategory() async {
    final ctrl = TextEditingController();
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Trainingsart'),
        content: TextField(controller: ctrl, autofocus: true),
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
      if (!_allCats.contains(v)) _allCats.add(v);
      if (!_categories.contains(v)) _categories.add(v);
    });
  }

  Future<void> _save() async {
    final state = context.read<AppState>();
    await state.upsertTrainingSession(
      TrainingSession(
        id: _id,
        date: _date,
        fieldPlayers: int.tryParse(_field.text.trim()) ?? 0,
        goalkeepers: int.tryParse(_gk.text.trim()) ?? 0,
        categories: _categories,
        note: widget.initial?.note ?? '',
        createdAt: widget.initial?.createdAt ?? DateTime.now(),
      ),
    );
    for (var i = 0; i < _items.length; i++) {
      await state.upsertSessionItem(_items[i].copyWith(orderIndex: i));
    }
    final keep = {for (final i in _items) i.id};
    for (final id in _originalItemIds) {
      if (!keep.contains(id)) await state.deleteSessionItem(id);
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.initial == null ? 'Neue Einheit' : 'Einheit'),
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
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
        children: [
          // Schritt 1: Anzahl.
          _header('1. Wie viele sind dabei?'),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _field,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Feldspieler',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _gk,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Torhüter',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.event, size: 18),
              const SizedBox(width: 8),
              Text(
                '${_date.day.toString().padLeft(2, '0')}.${_date.month.toString().padLeft(2, '0')}.${_date.year}',
              ),
              TextButton(
                onPressed: () async {
                  final d = await showDatePicker(
                    context: context,
                    initialDate: _date,
                    firstDate: DateTime(_date.year - 1),
                    lastDate: DateTime(_date.year + 2),
                  );
                  if (d != null) setState(() => _date = d);
                },
                child: const Text('Datum'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Schritt 2: Trainingsart.
          _header('2. Trainingsart'),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final c in _allCats)
                FilterChip(
                  label: Text(c),
                  selected: _categories.contains(c),
                  onSelected: (v) => setState(() {
                    if (v) {
                      _categories.add(c);
                    } else {
                      _categories.remove(c);
                    }
                  }),
                ),
              ActionChip(
                avatar: const Icon(Icons.add, size: 16),
                label: const Text('Art'),
                onPressed: _addCategory,
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Schritt 3: Übungen.
          Row(
            children: [
              Expanded(
                child: _header(
                  '3. Übungen${_totalMin > 0 ? ' · $_totalMin Min' : ''}',
                ),
              ),
              TextButton.icon(
                onPressed: _suggest,
                icon: const Icon(Icons.auto_awesome, size: 18),
                label: const Text('Vorschlagen'),
              ),
              IconButton(
                tooltip: 'Aus Bibliothek',
                onPressed: _pickExercise,
                icon: const Icon(Icons.add),
              ),
            ],
          ),
          if (_items.isEmpty)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Noch keine Übungen. Füge welche aus der Bibliothek hinzu.',
                style: TextStyle(color: Colors.grey),
              ),
            )
          else
            ReorderableListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: true,
              onReorder: (oldI, newI) {
                setState(() {
                  if (newI > oldI) newI -= 1;
                  final it = _items.removeAt(oldI);
                  _items.insert(newI, it);
                });
              },
              children: [
                for (var i = 0; i < _items.length; i++)
                  _itemTile(context, i, _items[i]),
              ],
            ),
        ],
      ),
    );
  }

  Widget _itemTile(BuildContext context, int i, SessionItem it) {
    final ex = _exMap[it.exerciseId];
    final dur = it.durationMin ?? ex?.durationMin;
    return Card(
      key: ValueKey(it.id),
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        leading: CircleAvatar(child: Text('${i + 1}')),
        title: Text(ex?.title ?? '—'),
        subtitle: Text(
          [
            if (ex != null && ex.categories.isNotEmpty) ex.categories.first,
            if (dur != null) '$dur Min',
          ].join(' · '),
        ),
        onTap: ex == null
            ? null
            : () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ExerciseDetailScreen(exercise: ex),
                ),
              ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Dauer',
              icon: const Icon(Icons.timer_outlined, size: 20),
              onPressed: () => _editDuration(i),
            ),
            IconButton(
              tooltip: 'Entfernen',
              icon: const Icon(Icons.close, size: 20),
              onPressed: () => setState(() => _items.removeAt(i)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(String t) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      t,
      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
    ),
  );
}
