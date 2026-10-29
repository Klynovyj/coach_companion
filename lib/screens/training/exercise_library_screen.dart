import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/exercise.dart';
import '../../state/app_state.dart';
import '../../widgets/drill_diagram_view.dart';
import 'exercise_editor_screen.dart';

/// Übungs-Bibliothek: suchen/filtern, anlegen, bearbeiten, duplizieren, löschen.
/// Mit [pickMode] = true liefert ein Tipp die gewählte Übung zurück (für den
/// Einheiten-Assistenten).
class ExerciseLibraryScreen extends StatefulWidget {
  const ExerciseLibraryScreen({
    super.key,
    this.pickMode = false,
    this.forPlayers,
  });

  final bool pickMode;
  final int? forPlayers;

  @override
  State<ExerciseLibraryScreen> createState() => _ExerciseLibraryScreenState();
}

class _ExerciseLibraryScreenState extends State<ExerciseLibraryScreen> {
  final _search = TextEditingController();
  String _query = '';
  String? _category;
  List<String> _categories = [];
  bool _onlyFav = false;
  bool _showArchived = false;

  @override
  void initState() {
    super.initState();
    _loadCategories();
  }

  Future<void> _loadCategories() async {
    final c = await context.read<AppState>().exerciseCategories();
    if (mounted) setState(() => _categories = c);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.pickMode ? 'Übung wählen' : 'Übungs-Bibliothek'),
      ),
      floatingActionButton: widget.pickMode
          ? null
          : FloatingActionButton.extended(
              onPressed: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const ExerciseEditorScreen(),
                  ),
                );
                _loadCategories();
                setState(() {});
              },
              icon: const Icon(Icons.add),
              label: const Text('Neue Übung'),
            ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: TextField(
              controller: _search,
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                hintText: 'Übung suchen …',
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                border: const OutlineInputBorder(),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _search.clear();
                          setState(() => _query = '');
                        },
                      ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                FilterChip(
                  avatar: Icon(
                    _onlyFav ? Icons.star : Icons.star_border,
                    size: 18,
                  ),
                  label: const Text('Favoriten'),
                  selected: _onlyFav,
                  onSelected: (v) => setState(() => _onlyFav = v),
                ),
                const SizedBox(width: 8),
                FilterChip(
                  avatar: const Icon(Icons.archive_outlined, size: 18),
                  label: const Text('Archiv'),
                  selected: _showArchived,
                  onSelected: (v) => setState(() => _showArchived = v),
                ),
              ],
            ),
          ),
          if (_categories.isNotEmpty)
            SizedBox(
              height: 42,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: FilterChip(
                      label: const Text('Alle'),
                      selected: _category == null,
                      onSelected: (_) => setState(() => _category = null),
                    ),
                  ),
                  for (final c in _categories)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: FilterChip(
                        label: Text(c),
                        selected: _category == c,
                        onSelected: (_) => setState(
                          () => _category = _category == c ? null : c,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          Expanded(
            child: FutureBuilder<List<Exercise>>(
              future: state.exercises(
                query: _query,
                categories: _category == null ? const [] : [_category!],
                forPlayers: widget.forPlayers,
                onlyFavorites: _onlyFav,
                includeArchived: _showArchived,
              ),
              builder: (context, snap) {
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final list = snap.data!;
                if (list.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _query.isEmpty && _category == null
                            ? 'Noch keine Übungen. Lege eine an.'
                            : 'Keine Treffer.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 90),
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, i) => _card(context, state, list[i]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(BuildContext context, AppState state, Exercise e) {
    final meta = <String>[
      if (e.minPlayers != null) 'ab ${e.minPlayers} Sp.',
      if ((e.goalkeepers ?? 0) > 0)
        '${e.goalkeepers} TW'
      else if (e.needsGoalkeeper)
        'mit TW',
      if (e.durationMin != null) '${e.durationMin} Min',
    ];
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: () async {
          if (widget.pickMode) {
            Navigator.pop(context, e);
            return;
          }
          await Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => ExerciseEditorScreen(initial: e)),
          );
          _loadCategories();
          setState(() {});
        },
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 90,
                child: e.diagram != null
                    ? DrillDiagramView(diagram: e.diagram!)
                    : Container(
                        height: 60,
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(Icons.sports, color: Colors.grey),
                      ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      e.title,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    if (e.categories.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          e.categories.join(' · '),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    if (meta.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          meta.join('  ·  '),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                  ],
                ),
              ),
              if (!widget.pickMode) ...[
                IconButton(
                  tooltip: e.favorite ? 'Favorit entfernen' : 'Als Favorit',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    e.favorite ? Icons.star : Icons.star_border,
                    color: e.favorite ? Colors.amber : null,
                  ),
                  onPressed: () async {
                    await state.toggleExerciseFavorite(e);
                    if (mounted) setState(() {});
                  },
                ),
                PopupMenuButton<String>(
                  onSelected: (v) async {
                    if (v == 'edit') {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ExerciseEditorScreen(initial: e),
                        ),
                      );
                    } else if (v == 'dup') {
                      final copy = e.copyWith(title: '${e.title} (Kopie)');
                      // Neue ID: über den Editor-Pfad einfacher – hier direkt.
                      await state.upsertExercise(
                        Exercise.fromMap({
                          ...copy.toMap(),
                          'id': DateTime.now().microsecondsSinceEpoch
                              .toString(),
                        }),
                      );
                    } else if (v == 'archive') {
                      await state.setExerciseArchived(e, !e.archived);
                    } else if (v == 'del') {
                      final ok = await _confirmDelete(context, e.title);
                      if (ok) await state.deleteExercise(e.id);
                    }
                    _loadCategories();
                    if (mounted) setState(() {});
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'edit',
                      child: Text('Bearbeiten'),
                    ),
                    const PopupMenuItem(
                      value: 'dup',
                      child: Text('Duplizieren'),
                    ),
                    PopupMenuItem(
                      value: 'archive',
                      child: Text(
                        e.archived ? 'Wiederherstellen' : 'Archivieren',
                      ),
                    ),
                    const PopupMenuItem(value: 'del', child: Text('Löschen')),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<bool> _confirmDelete(BuildContext context, String title) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Übung löschen?'),
        content: Text('„$title" wird gelöscht.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }
}
