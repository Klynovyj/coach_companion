import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/todo.dart';
import '../state/app_state.dart';

/// Eigene Aufgaben/To-Dos – eigener Menüpunkt. Anlegen (optional mit
/// Fälligkeit), abhaken (mit Zeitstempel), bearbeiten, archivieren, löschen.
class TodosScreen extends StatefulWidget {
  const TodosScreen({super.key});

  @override
  State<TodosScreen> createState() => _TodosScreenState();
}

class _TodosScreenState extends State<TodosScreen> {
  final _todoCtrl = TextEditingController();
  DateTime? _newDue; // optionale Fälligkeit für die neue Aufgabe
  bool _showArchive = false;

  static final _dDate = DateFormat('dd.MM.yyyy', 'de_DE');
  static final _dDateTime = DateFormat('dd.MM.yyyy  HH:mm', 'de_DE');

  @override
  void dispose() {
    _todoCtrl.dispose();
    super.dispose();
  }

  void _add(AppState state) {
    final t = _todoCtrl.text.trim();
    if (t.isEmpty) return;
    state.addTodo(t, dueDate: _newDue);
    _todoCtrl.clear();
    setState(() => _newDue = null);
  }

  Future<DateTime?> _pickDate(DateTime? initial) {
    final now = DateTime.now();
    final base = initial ?? now;
    return showDatePicker(
      context: context,
      initialDate: base.isBefore(now) ? now : base,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 2),
      helpText: 'Fälligkeit wählen',
    );
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

  /// „heute" / „morgen" / „gestern", sonst das Datum.
  String _dueLabel(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    final diff = day.difference(today).inDays;
    if (diff == 0) return 'heute';
    if (diff == 1) return 'morgen';
    if (diff == -1) return 'gestern';
    return _dDate.format(d);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: Text(_showArchive ? 'Aufgaben – Archiv' : 'Aufgaben'),
        actions: [
          IconButton(
            tooltip: _showArchive ? 'Aktive Aufgaben' : 'Archiv',
            icon: Icon(_showArchive ? Icons.checklist : Icons.archive_outlined),
            onPressed: () => setState(() => _showArchive = !_showArchive),
          ),
        ],
      ),
      body: FutureBuilder<List<Todo>>(
        future: _showArchive ? state.archivedTodos() : state.todos(),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final todos = snap.data!;
          return Column(
            children: [
              Expanded(
                child: todos.isEmpty
                    ? _empty()
                    : ListView(
                        padding: const EdgeInsets.only(bottom: 8),
                        children: [
                          for (final t in todos) _todoTile(context, state, t),
                        ],
                      ),
              ),
              if (!_showArchive) _addBar(state),
            ],
          );
        },
      ),
    );
  }

  Widget _empty() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _showArchive
                ? 'Archiv ist leer.'
                : 'Noch keine Aufgaben.\nUnten eine neue hinzufügen.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.grey),
          ),
        ),
      );

  Widget _todoTile(BuildContext context, AppState state, Todo t) {
    final subtitleParts = <Widget>[];
    if (t.dueDate != null) {
      final overdue = t.isOverdue;
      subtitleParts.add(InkWell(
        onTap: () async {
          final d = await _pickDate(t.dueDate);
          if (d != null) await state.setTodoDueDate(t, d);
        },
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.event,
                size: 14, color: overdue ? Colors.red : Colors.grey.shade600),
            const SizedBox(width: 4),
            Text('Fällig: ${_dueLabel(t.dueDate!)}',
                style: TextStyle(
                    fontSize: 12.5,
                    color: overdue ? Colors.red : Colors.grey.shade700,
                    fontWeight:
                        overdue ? FontWeight.bold : FontWeight.normal)),
          ],
        ),
      ));
    }
    if (t.done && t.completedAt != null) {
      subtitleParts.add(Text('Erledigt: ${_dDateTime.format(t.completedAt!)}',
          style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600)));
    }

    return Dismissible(
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
        leading: Checkbox(
          value: t.done,
          onChanged: (v) => state.toggleTodo(t, v ?? false),
        ),
        title: Text(
          t.text,
          style: t.done
              ? const TextStyle(
                  decoration: TextDecoration.lineThrough, color: Colors.grey)
              : null,
        ),
        subtitle: subtitleParts.isEmpty
            ? null
            : Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: subtitleParts,
                ),
              ),
        trailing: PopupMenuButton<String>(
          onSelected: (v) => _onMenu(context, state, t, v),
          itemBuilder: (context) => [
            PopupMenuItem(
              value: 'due',
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.event),
                title: Text(t.dueDate == null
                    ? 'Fälligkeit setzen'
                    : 'Fälligkeit ändern'),
              ),
            ),
            if (t.dueDate != null)
              const PopupMenuItem(
                value: 'due_clear',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.event_busy),
                  title: Text('Fälligkeit entfernen'),
                ),
              ),
            const PopupMenuItem(
              value: 'edit',
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.edit),
                title: Text('Bearbeiten'),
              ),
            ),
            PopupMenuItem(
              value: t.archived ? 'unarchive' : 'archive',
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                    t.archived ? Icons.unarchive : Icons.archive_outlined),
                title: Text(t.archived ? 'Wiederherstellen' : 'Archivieren'),
              ),
            ),
            const PopupMenuItem(
              value: 'delete',
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.delete_outline, color: Colors.red),
                title: Text('Löschen'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _onMenu(
      BuildContext context, AppState state, Todo t, String value) async {
    switch (value) {
      case 'due':
        final d = await _pickDate(t.dueDate);
        if (d != null) await state.setTodoDueDate(t, d);
      case 'due_clear':
        await state.setTodoDueDate(t, null);
      case 'edit':
        if (context.mounted) await _edit(context, state, t);
      case 'archive':
        await state.setTodoArchived(t, true);
      case 'unarchive':
        await state.setTodoArchived(t, false);
      case 'delete':
        await state.deleteTodo(t.id);
    }
    if (mounted) setState(() {});
  }

  Widget _addBar(AppState state) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_newDue != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: InputChip(
                    avatar: const Icon(Icons.event, size: 16),
                    label: Text('Fällig: ${_dueLabel(_newDue!)}'),
                    onDeleted: () => setState(() => _newDue = null),
                  ),
                ),
              ),
            Row(
              children: [
                IconButton(
                  tooltip: 'Fälligkeit für neue Aufgabe',
                  icon: Icon(
                    Icons.event,
                    color: _newDue != null
                        ? Theme.of(context).colorScheme.primary
                        : null,
                  ),
                  onPressed: () async {
                    final d = await _pickDate(_newDue);
                    if (d != null) setState(() => _newDue = d);
                  },
                ),
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
          ],
        ),
      ),
    );
  }
}
