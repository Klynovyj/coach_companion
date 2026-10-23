import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/todo.dart';
import '../state/app_state.dart';
import 'match_center_screen.dart';
import 'rating_screen.dart';

/// „Nachholen" (wie MS-Teams): offene Punkte, die man später erledigen kann –
/// fehlende Bewertungen, Nominierungen, Aufstellungen und eigene To-Dos.
class NachholenScreen extends StatefulWidget {
  const NachholenScreen({super.key});

  @override
  State<NachholenScreen> createState() => _NachholenScreenState();
}

class _NachholenScreenState extends State<NachholenScreen> {
  final _todoCtrl = TextEditingController();

  @override
  void dispose() {
    _todoCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final df = DateFormat('dd.MM.yyyy', 'de_DE');

    return Scaffold(
      appBar: AppBar(title: const Text('Nachholen')),
      body: FutureBuilder<(List<NachholenItem>, List<Todo>)>(
        future: _load(state),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final items = snap.data!.$1;
          final todos = snap.data!.$2;
          final ratings =
              items.where((i) => i.kind == NachholenKind.rating).toList();
          final noms =
              items.where((i) => i.kind == NachholenKind.nomination).toList();
          final lineups =
              items.where((i) => i.kind == NachholenKind.lineup).toList();
          final allClear = items.isEmpty && todos.every((t) => t.done);

          return ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              if (allClear) _allClear(context),
              _section(
                context,
                icon: Icons.star_border,
                title: 'Offene Bewertungen',
                items: ratings,
                df: df,
                onTap: (i) => _open(context, RatingScreen(matchId: i.matchId)),
              ),
              _section(
                context,
                icon: Icons.how_to_reg,
                title: 'Offene Nominierungen',
                items: noms,
                df: df,
                onTap: (i) =>
                    _open(context, MatchCenterScreen(matchId: i.matchId)),
              ),
              _section(
                context,
                icon: Icons.dashboard_customize,
                title: 'Fehlende Aufstellung',
                items: lineups,
                df: df,
                onTap: (i) =>
                    _open(context, MatchCenterScreen(matchId: i.matchId)),
              ),
              _todoSection(context, state, todos),
            ],
          );
        },
      ),
    );
  }

  Future<(List<NachholenItem>, List<Todo>)> _load(AppState s) async {
    final items = await s.nachholen();
    final todos = await s.todos();
    return (items, todos);
  }

  Future<void> _open(BuildContext context, Widget screen) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
  }

  Widget _allClear(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
        child: Column(
          children: [
            Icon(Icons.check_circle,
                size: 48, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 8),
            const Text('Alles erledigt 🎉', textAlign: TextAlign.center),
          ],
        ),
      );

  Widget _section(
    BuildContext context, {
    required IconData icon,
    required String title,
    required List<NachholenItem> items,
    required DateFormat df,
    required void Function(NachholenItem) onTap,
  }) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Row(
                children: [
                  Icon(icon,
                      size: 18, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 8),
                  Text(title,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const Spacer(),
                  _countBadge(context, items.length),
                ],
              ),
            ),
            for (final i in items)
              ListTile(
                contentPadding: const EdgeInsets.only(right: 8),
                title: Text(i.title),
                subtitle: Text([
                  if (i.kickoff != null) df.format(i.kickoff!.toLocal()),
                  i.detail,
                ].join('  ·  ')),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => onTap(i),
              ),
          ],
        ),
      ),
    );
  }

  Widget _countBadge(BuildContext context, int n) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text('$n',
            style: TextStyle(
                color: Theme.of(context).colorScheme.onPrimary,
                fontWeight: FontWeight.bold,
                fontSize: 12)),
      );

  Widget _todoSection(BuildContext context, AppState state, List<Todo> todos) {
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.checklist,
                    size: 18, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                Text('Eigene To-Dos',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 4),
            if (todos.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Noch keine Aufgaben.',
                      style: TextStyle(color: Colors.grey)),
                ),
              )
            else
              for (final t in todos)
                Dismissible(
                  key: ValueKey(t.id),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    color: Colors.red,
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 20),
                    child: const Icon(Icons.delete, color: Colors.white),
                  ),
                  onDismissed: (_) => state.deleteTodo(t.id),
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Checkbox(
                      value: t.done,
                      onChanged: (v) => state.toggleTodo(t, v ?? false),
                    ),
                    title: Text(
                      t.text,
                      style: t.done
                          ? const TextStyle(
                              decoration: TextDecoration.lineThrough,
                              color: Colors.grey)
                          : null,
                    ),
                    onTap: () => _editTodo(context, state, t),
                  ),
                ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _todoCtrl,
                    decoration: const InputDecoration(
                      hintText: 'Neue Aufgabe …',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _addTodo(state),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: () => _addTodo(state),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _addTodo(AppState state) {
    final t = _todoCtrl.text.trim();
    if (t.isEmpty) return;
    state.addTodo(t);
    _todoCtrl.clear();
  }

  Future<void> _editTodo(
      BuildContext context, AppState state, Todo todo) async {
    final ctrl = TextEditingController(text: todo.text);
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Aufgabe bearbeiten'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Aufgabe'),
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () => Navigator.pop(context, ctrl.text.trim()),
              child: const Text('Speichern')),
        ],
      ),
    );
    if (text != null) await state.updateTodoText(todo, text);
  }
}
