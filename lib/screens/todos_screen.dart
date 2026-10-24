import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/player.dart';
import '../models/todo.dart';
import '../models/todo_topic.dart';
import '../state/app_state.dart';
import '../widgets/player_avatar.dart';

/// Eigene Aufgaben/To-Dos. Aufgaben werden unter Themen (Überschriften)
/// einsortiert; Schnellaufgaben (unten) laufen ohne Thema. Jede Aufgabe hat
/// einen oder mehrere Verantwortliche (Kader/Trainerteam oder manuell).
class TodosScreen extends StatefulWidget {
  const TodosScreen({super.key});

  @override
  State<TodosScreen> createState() => _TodosScreenState();
}

class _TodosScreenState extends State<TodosScreen> {
  final _quickCtrl = TextEditingController();
  DateTime? _quickDue;
  List<TodoResponsible> _quickResponsible = [];
  bool _showArchive = false;

  static final _dDate = DateFormat('dd.MM.yyyy', 'de_DE');
  static final _dDateTime = DateFormat('dd.MM.yyyy  HH:mm', 'de_DE');

  @override
  void dispose() {
    _quickCtrl.dispose();
    super.dispose();
  }

  Future<(List<TodoTopic>, List<Todo>, List<Player>)> _load(
      AppState state) async {
    final topics = await state.todoTopics();
    final todos =
        _showArchive ? await state.archivedTodos() : await state.todos();
    final team = state.ownTeam;
    final players = team == null ? <Player>[] : await state.playersOf(team.id);
    return (topics, todos, players);
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

  // ------------------------------------------------------------ Aktionen
  Future<void> _addQuick(AppState state) async {
    final t = _quickCtrl.text.trim();
    if (t.isEmpty) return;
    if (_quickResponsible.isEmpty) {
      _snack('Bitte mindestens einen Verantwortlichen wählen.');
      return;
    }
    await state.addTodo(t,
        dueDate: _quickDue, responsible: _quickResponsible);
    _quickCtrl.clear();
    setState(() {
      _quickDue = null;
      _quickResponsible = [];
    });
  }

  Future<void> _addTopic(AppState state) async {
    final ctrl = TextEditingController();
    final title = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Neues Thema'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
              labelText: 'Thema', hintText: 'z.B. Organisation Sommerfest'),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Anlegen')),
        ],
      ),
    );
    if (title != null && title.isNotEmpty) {
      await state.addTodoTopic(title);
      if (mounted) setState(() {});
    }
  }

  Future<void> _renameTopic(AppState state, TodoTopic topic) async {
    final ctrl = TextEditingController(text: topic.title);
    final title = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Thema umbenennen'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'Thema'),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Speichern')),
        ],
      ),
    );
    if (title != null && title.isNotEmpty) {
      await state.renameTodoTopic(topic, title);
      if (mounted) setState(() {});
    }
  }

  Future<void> _deleteTopic(AppState state, TodoTopic topic) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Thema „${topic.title}" löschen?'),
        content: const Text(
            'Die Aufgaben bleiben erhalten und rutschen zu „Ohne Thema".'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Löschen')),
        ],
      ),
    );
    if (ok == true) {
      await state.deleteTodoTopic(topic.id);
      if (mounted) setState(() {});
    }
  }

  /// Aufgaben-Seite (Vollbild) zum Anlegen oder Bearbeiten.
  Future<void> _openTaskPage(
    AppState state,
    List<Player> players, {
    Todo? todo,
    String? topicId,
    List<TodoTopic> topics = const [],
  }) async {
    final result = await Navigator.of(context).push<_TaskResult>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _TaskEditPage(
          players: players,
          topics: topics,
          initial: todo,
          initialTopicId: topicId ?? todo?.topicId,
        ),
      ),
    );
    if (result == null || !mounted) return;
    if (todo == null) {
      await state.addTodo(result.text,
          dueDate: result.due,
          topicId: result.topicId,
          responsible: result.responsible);
    } else {
      await state.saveTodo(todo.copyWith(
        text: result.text,
        dueDate: result.due,
        clearDueDate: result.due == null,
        topicId: result.topicId,
        clearTopicId: result.topicId == null,
        responsible: result.responsible,
      ));
    }
    if (mounted) setState(() {});
  }

  void _snack(String msg) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: Text(_showArchive ? 'Aufgaben – Archiv' : 'Aufgaben'),
        actions: [
          if (!_showArchive)
            IconButton(
              tooltip: 'Neues Thema',
              icon: const Icon(Icons.create_new_folder_outlined),
              onPressed: () => _addTopic(state),
            ),
          IconButton(
            tooltip: _showArchive ? 'Aktive Aufgaben' : 'Archiv',
            icon: Icon(_showArchive ? Icons.checklist : Icons.archive_outlined),
            onPressed: () => setState(() => _showArchive = !_showArchive),
          ),
        ],
      ),
      body: FutureBuilder<(List<TodoTopic>, List<Todo>, List<Player>)>(
        future: _load(state),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final topics = snap.data!.$1;
          final todos = snap.data!.$2;
          final players = snap.data!.$3;
          final playerMap = {for (final p in players) p.id: p};
          return Column(
            children: [
              Expanded(
                child: _showArchive
                    ? _archiveView(state, todos, playerMap)
                    : _activeView(state, topics, todos, players, playerMap),
              ),
              if (!_showArchive) _addBar(state, players),
            ],
          );
        },
      ),
    );
  }

  Widget _activeView(
    AppState state,
    List<TodoTopic> topics,
    List<Todo> todos,
    List<Player> players,
    Map<String, Player> playerMap,
  ) {
    final byTopic = <String?, List<Todo>>{};
    for (final t in todos) {
      final key = topics.any((x) => x.id == t.topicId) ? t.topicId : null;
      byTopic.putIfAbsent(key, () => []).add(t);
    }
    final noTopic = byTopic[null] ?? const [];

    if (topics.isEmpty && todos.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Noch keine Aufgaben.\nOben ein Thema anlegen oder unten eine '
            'Schnellaufgabe hinzufügen.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey.shade600),
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 12),
      children: [
        for (final topic in topics)
          _topicSection(state, topic, byTopic[topic.id] ?? const [],
              players, playerMap, topics),
        if (noTopic.isNotEmpty)
          _plainSection(
              state, 'Ohne Thema', noTopic, playerMap),
      ],
    );
  }

  Widget _archiveView(
      AppState state, List<Todo> todos, Map<String, Player> playerMap) {
    if (todos.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Archiv ist leer.',
              style: TextStyle(color: Colors.grey)),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 12),
      children: [for (final t in todos) _todoTile(state, t, playerMap)],
    );
  }

  Widget _topicSection(
    AppState state,
    TodoTopic topic,
    List<Todo> todos,
    List<Player> players,
    Map<String, Player> playerMap,
    List<TodoTopic> allTopics,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
          child: Row(
            children: [
              Expanded(
                child: Text(topic.title,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15)),
              ),
              IconButton(
                tooltip: 'Aufgabe hinzufügen',
                icon: const Icon(Icons.add),
                visualDensity: VisualDensity.compact,
                onPressed: () => _openTaskPage(state, players,
                    topicId: topic.id, topics: allTopics),
              ),
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'rename') _renameTopic(state, topic);
                  if (v == 'delete') _deleteTopic(state, topic);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'rename', child: Text('Umbenennen')),
                  PopupMenuItem(value: 'delete', child: Text('Thema löschen')),
                ],
              ),
            ],
          ),
        ),
        if (todos.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text('Noch keine Aufgaben in diesem Thema.',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
          )
        else
          for (final t in todos) _todoTile(state, t, playerMap),
      ],
    );
  }

  Widget _plainSection(AppState state, String title, List<Todo> todos,
      Map<String, Player> playerMap) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Text(title,
              style:
                  const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        ),
        for (final t in todos) _todoTile(state, t, playerMap),
      ],
    );
  }

  Widget _todoTile(AppState state, Todo t, Map<String, Player> playerMap) {
    final sub = <Widget>[];
    if (t.responsible.isNotEmpty) {
      sub.add(Wrap(
        spacing: 6,
        runSpacing: 2,
        children: t.responsible.map((r) {
          final p = r.playerId == null ? null : playerMap[r.playerId];
          return Chip(
            avatar: p != null
                ? PlayerAvatar(player: p, radius: 10)
                : const CircleAvatar(radius: 10, child: Icon(Icons.person, size: 12)),
            label: Text(r.name, style: const TextStyle(fontSize: 12)),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: EdgeInsets.zero,
          );
        }).toList(),
      ));
    }
    if (t.dueDate != null) {
      final overdue = t.isOverdue;
      sub.add(Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.event,
              size: 14, color: overdue ? Colors.red : Colors.grey.shade600),
          const SizedBox(width: 4),
          Text('Fällig: ${_dueLabel(t.dueDate!)}',
              style: TextStyle(
                  fontSize: 12.5,
                  color: overdue ? Colors.red : Colors.grey.shade700,
                  fontWeight: overdue ? FontWeight.bold : FontWeight.normal)),
        ],
      ));
    }
    if (t.done && t.completedAt != null) {
      sub.add(Text('Erledigt: ${_dDateTime.format(t.completedAt!)}',
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
        subtitle: sub.isEmpty
            ? null
            : Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final w in sub)
                      Padding(
                          padding: const EdgeInsets.only(bottom: 2), child: w),
                  ],
                ),
              ),
        trailing: PopupMenuButton<String>(
          onSelected: (v) => _onMenu(state, t, v),
          itemBuilder: (context) => [
            const PopupMenuItem(value: 'edit', child: Text('Bearbeiten')),
            PopupMenuItem(
                value: t.archived ? 'unarchive' : 'archive',
                child: Text(t.archived ? 'Wiederherstellen' : 'Archivieren')),
            const PopupMenuItem(value: 'delete', child: Text('Löschen')),
          ],
        ),
      ),
    );
  }

  Future<void> _onMenu(AppState state, Todo t, String value) async {
    switch (value) {
      case 'edit':
        final team = state.ownTeam;
        final players =
            team == null ? <Player>[] : await state.playersOf(team.id);
        final topics = await state.todoTopics();
        if (mounted) {
          await _openTaskPage(state, players, todo: t, topics: topics);
        }
      case 'archive':
        await state.setTodoArchived(t, true);
      case 'unarchive':
        await state.setTodoArchived(t, false);
      case 'delete':
        await state.deleteTodo(t.id);
    }
    if (mounted) setState(() {});
  }

  Widget _addBar(AppState state, List<Player> players) {
    final hasResp = _quickResponsible.isNotEmpty;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_quickDue != null || hasResp)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      if (_quickDue != null)
                        InputChip(
                          avatar: const Icon(Icons.event, size: 16),
                          label: Text('Fällig: ${_dueLabel(_quickDue!)}'),
                          onDeleted: () => setState(() => _quickDue = null),
                        ),
                      for (final r in _quickResponsible)
                        InputChip(
                          avatar: const Icon(Icons.person, size: 16),
                          label: Text(r.name),
                          onDeleted: () => setState(() =>
                              _quickResponsible =
                                  _quickResponsible.where((x) => x != r).toList()),
                        ),
                    ],
                  ),
                ),
              ),
            Row(
              children: [
                IconButton(
                  tooltip: 'Verantwortliche wählen',
                  icon: Icon(Icons.group_add,
                      color: hasResp
                          ? Theme.of(context).colorScheme.primary
                          : null),
                  onPressed: () async {
                    final res = await _pickResponsible(players, _quickResponsible);
                    if (res != null) setState(() => _quickResponsible = res);
                  },
                ),
                IconButton(
                  tooltip: 'Fälligkeit',
                  icon: Icon(Icons.event,
                      color: _quickDue != null
                          ? Theme.of(context).colorScheme.primary
                          : null),
                  onPressed: () async {
                    final d = await _pickDate(_quickDue);
                    if (d != null) setState(() => _quickDue = d);
                  },
                ),
                Expanded(
                  child: TextField(
                    controller: _quickCtrl,
                    decoration: const InputDecoration(
                      hintText: 'Schnellaufgabe …',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _addQuick(state),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  icon: const Icon(Icons.add),
                  onPressed: () => _addQuick(state),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<List<TodoResponsible>?> _pickResponsible(
      List<Player> players, List<TodoResponsible> initial) {
    return Navigator.of(context).push<List<TodoResponsible>>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _ResponsiblePickerPage(players: players, initial: initial),
      ),
    );
  }
}

/// Ergebnis der Aufgaben-Seite.
class _TaskResult {
  final String text;
  final String? topicId;
  final DateTime? due;
  final List<TodoResponsible> responsible;
  const _TaskResult(this.text, this.topicId, this.due, this.responsible);
}

/// Vollbild-Seite zum Anlegen/Bearbeiten einer Aufgabe (Thema + Text +
/// Verantwortliche + Fälligkeit).
class _TaskEditPage extends StatefulWidget {
  const _TaskEditPage({
    required this.players,
    required this.topics,
    this.initial,
    this.initialTopicId,
  });

  final List<Player> players;
  final List<TodoTopic> topics;
  final Todo? initial;
  final String? initialTopicId;

  @override
  State<_TaskEditPage> createState() => _TaskEditPageState();
}

class _TaskEditPageState extends State<_TaskEditPage> {
  late final TextEditingController _textCtrl;
  String? _topicId;
  DateTime? _due;
  List<TodoResponsible> _responsible = [];

  static final _dDate = DateFormat('dd.MM.yyyy', 'de_DE');

  @override
  void initState() {
    super.initState();
    _textCtrl = TextEditingController(text: widget.initial?.text ?? '');
    _topicId = widget.initialTopicId;
    _due = widget.initial?.dueDate;
    _responsible = List.of(widget.initial?.responsible ?? const []);
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    super.dispose();
  }

  void _save() {
    final text = _textCtrl.text.trim();
    if (text.isEmpty) {
      _snack('Bitte einen Aufgabentext eingeben.');
      return;
    }
    if (_responsible.isEmpty) {
      _snack('Bitte mindestens einen Verantwortlichen wählen.');
      return;
    }
    Navigator.pop(context, _TaskResult(text, _topicId, _due, _responsible));
  }

  void _snack(String msg) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _pickDue() async {
    final now = DateTime.now();
    final base = _due ?? now;
    final d = await showDatePicker(
      context: context,
      initialDate: base.isBefore(now) ? now : base,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 2),
      helpText: 'Fälligkeit wählen',
    );
    if (d != null) setState(() => _due = d);
  }

  Future<void> _pickResponsible() async {
    final res = await Navigator.of(context).push<List<TodoResponsible>>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) =>
            _ResponsiblePickerPage(players: widget.players, initial: _responsible),
      ),
    );
    if (res != null) setState(() => _responsible = res);
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.initial != null;
    final playerMap = {for (final p in widget.players) p.id: p};
    return Scaffold(
      appBar: AppBar(
        title: Text(isEdit ? 'Aufgabe bearbeiten' : 'Neue Aufgabe'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.check, size: 18),
              label: const Text('Speichern'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          DropdownButtonFormField<String?>(
            initialValue:
                widget.topics.any((t) => t.id == _topicId) ? _topicId : null,
            isExpanded: true,
            decoration: const InputDecoration(
                labelText: 'Thema', border: OutlineInputBorder()),
            items: [
              const DropdownMenuItem<String?>(
                  value: null, child: Text('Ohne Thema')),
              for (final t in widget.topics)
                DropdownMenuItem<String?>(value: t.id, child: Text(t.title)),
            ],
            onChanged: (v) => setState(() => _topicId = v),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _textCtrl,
            autofocus: !isEdit,
            minLines: 1,
            maxLines: 4,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
                labelText: 'Aufgabe', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              const Expanded(
                child: Text('Verantwortliche',
                    style: TextStyle(fontWeight: FontWeight.w600)),
              ),
              TextButton.icon(
                onPressed: _pickResponsible,
                icon: const Icon(Icons.group_add, size: 18),
                label: const Text('Wählen'),
              ),
            ],
          ),
          if (_responsible.isEmpty)
            Text('Noch niemand gewählt.',
                style: TextStyle(color: Colors.grey.shade600))
          else
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: _responsible.map((r) {
                final p = r.playerId == null ? null : playerMap[r.playerId];
                return InputChip(
                  avatar: p != null
                      ? PlayerAvatar(player: p, radius: 10)
                      : const CircleAvatar(
                          radius: 10, child: Icon(Icons.person, size: 12)),
                  label: Text(r.name),
                  onDeleted: () => setState(() =>
                      _responsible = _responsible.where((x) => x != r).toList()),
                );
              }).toList(),
            ),
          const SizedBox(height: 20),
          const Text('Fälligkeit (optional)',
              style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _pickDue,
                icon: const Icon(Icons.event),
                label: Text(_due == null
                    ? 'Datum wählen'
                    : _dDate.format(_due!)),
              ),
              if (_due != null)
                IconButton(
                  tooltip: 'Fälligkeit entfernen',
                  icon: const Icon(Icons.clear),
                  onPressed: () => setState(() => _due = null),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Vollbild-Picker für Verantwortliche: Spieler/Trainer (mit Foto) auswählen,
/// Suche filtern, zusätzlich manuelle Namen eingeben.
class _ResponsiblePickerPage extends StatefulWidget {
  const _ResponsiblePickerPage({required this.players, required this.initial});

  final List<Player> players;
  final List<TodoResponsible> initial;

  @override
  State<_ResponsiblePickerPage> createState() => _ResponsiblePickerPageState();
}

class _ResponsiblePickerPageState extends State<_ResponsiblePickerPage> {
  final Set<String> _selectedIds = {};
  final List<String> _manual = [];
  final _manualCtrl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    for (final r in widget.initial) {
      if (r.playerId != null) {
        _selectedIds.add(r.playerId!);
      } else if (r.name.trim().isNotEmpty) {
        _manual.add(r.name.trim());
      }
    }
  }

  @override
  void dispose() {
    _manualCtrl.dispose();
    super.dispose();
  }

  void _addManual() {
    final n = _manualCtrl.text.trim();
    if (n.isEmpty) return;
    setState(() {
      _manual.add(n);
      _manualCtrl.clear();
    });
  }

  void _done() {
    final map = {for (final p in widget.players) p.id: p};
    final result = <TodoResponsible>[
      for (final id in _selectedIds)
        TodoResponsible(playerId: id, name: map[id]?.displayName ?? 'Spieler'),
      for (final n in _manual) TodoResponsible(name: n),
    ];
    Navigator.pop(context, result);
  }

  List<Player> get _filtered {
    final q = _query.trim().toLowerCase();
    final list = q.isEmpty
        ? widget.players
        : widget.players
            .where((p) => p.displayName.toLowerCase().contains(q))
            .toList();
    // Trainerteam zuerst, dann Spieler.
    final staff = list.where((p) => p.isStaff).toList();
    final rest = list.where((p) => !p.isStaff).toList();
    return [...staff, ...rest];
  }

  @override
  Widget build(BuildContext context) {
    final players = _filtered;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Verantwortliche'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: FilledButton.icon(
              onPressed: _done,
              icon: const Icon(Icons.check, size: 18),
              label: const Text('Fertig'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          // Manuelle Eingabe.
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _manualCtrl,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Name manuell eingeben',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _addManual(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                  icon: const Icon(Icons.add), onPressed: _addManual),
            ],
          ),
          if (_manual.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: _manual
                  .map((n) => InputChip(
                        avatar: const CircleAvatar(
                            radius: 10, child: Icon(Icons.person, size: 12)),
                        label: Text(n),
                        onDeleted: () => setState(() => _manual.remove(n)),
                      ))
                  .toList(),
            ),
          ],
          const SizedBox(height: 16),
          TextField(
            onChanged: (v) => setState(() => _query = v),
            decoration: InputDecoration(
              hintText: 'Spieler/Trainer suchen …',
              prefixIcon: const Icon(Icons.search),
              isDense: true,
              border: const OutlineInputBorder(),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () => setState(() => _query = ''),
                    ),
            ),
          ),
          const SizedBox(height: 8),
          if (players.isEmpty)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                widget.players.isEmpty
                    ? 'Kein Kader geladen – nutze die manuelle Eingabe.'
                    : 'Keine Treffer.',
                style: const TextStyle(color: Colors.grey),
              ),
            )
          else
            for (final p in players)
              CheckboxListTile(
                value: _selectedIds.contains(p.id),
                onChanged: (v) => setState(() {
                  if (v == true) {
                    _selectedIds.add(p.id);
                  } else {
                    _selectedIds.remove(p.id);
                  }
                }),
                secondary: PlayerAvatar(player: p, radius: 18),
                title: Text(p.displayName),
                subtitle: p.isStaff ? const Text('Trainerteam') : null,
                controlAffinity: ListTileControlAffinity.trailing,
                contentPadding: EdgeInsets.zero,
              ),
        ],
      ),
    );
  }
}
