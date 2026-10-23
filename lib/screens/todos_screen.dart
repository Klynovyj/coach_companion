import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/todo.dart';
import '../state/app_state.dart';

/// Eigene Aufgaben/To-Dos – eigener Menüpunkt. Anlegen, abhaken, bearbeiten,
/// löschen; offene zuerst.
class TodosScreen extends StatefulWidget {
  const TodosScreen({super.key});

  @override
  State<TodosScreen> createState() => _TodosScreenState();
}

class _TodosScreenState extends State<TodosScreen> {
  final _todoCtrl = TextEditingController();

  @override
  void dispose() {
    _todoCtrl.dispose();
    super.dispose();
  }

  void _add(AppState state) {
    final t = _todoCtrl.text.trim();
    if (t.isEmpty) return;
    state.addTodo(t);
    _todoCtrl.clear();
  }

  Future<void> _edit(BuildContext context, AppState state, Todo todo) async {
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

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(title: const Text('Aufgaben')),
      body: FutureBuilder<List<Todo>>(
        future: state.todos(),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final todos = snap.data!;
          return Column(
            children: [
              Expanded(
                child: todos.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'Noch keine Aufgaben.\nUnten eine neue hinzufügen.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.grey),
                          ),
                        ),
                      )
                    : ListView(
                        children: [
                          for (final t in todos)
                            Dismissible(
                              key: ValueKey(t.id),
                              direction: DismissDirection.endToStart,
                              background: Container(
                                color: Colors.red,
                                alignment: Alignment.centerRight,
                                padding: const EdgeInsets.only(right: 20),
                                child: const Icon(Icons.delete,
                                    color: Colors.white),
                              ),
                              onDismissed: (_) => state.deleteTodo(t.id),
                              child: ListTile(
                                leading: Checkbox(
                                  value: t.done,
                                  onChanged: (v) =>
                                      state.toggleTodo(t, v ?? false),
                                ),
                                title: Text(
                                  t.text,
                                  style: t.done
                                      ? const TextStyle(
                                          decoration:
                                              TextDecoration.lineThrough,
                                          color: Colors.grey)
                                      : null,
                                ),
                                trailing: const Icon(Icons.edit, size: 18),
                                onTap: () => _edit(context, state, t),
                              ),
                            ),
                        ],
                      ),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _todoCtrl,
                          decoration: const InputDecoration(
                            hintText: 'Neue Aufgabe …',
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                          onSubmitted: (_) => _add(state),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(
                        icon: const Icon(Icons.add),
                        onPressed: () => _add(state),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
