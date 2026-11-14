import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/player.dart';
import '../models/todo.dart';
import '../models/todo_topic.dart';
import '../state/app_state.dart';
import '../widgets/player_avatar.dart';
import '../widgets/trainer_mention_field.dart';

/// Eigene Aufgaben/To-Dos. Aufgaben werden unter Themen (Überschriften)
/// einsortiert; Schnellaufgaben (unten) laufen ohne Thema. Jede Aufgabe hat
/// einen oder mehrere Verantwortliche (Kader/Trainerteam oder manuell).
class TodosScreen extends StatefulWidget {
  const TodosScreen({super.key});

  @override
  State<TodosScreen> createState() => _TodosScreenState();
}

class _TodosScreenState extends State<TodosScreen> {
  /// Weggewischte Aufgaben, die erst nach Ablauf des „Rückgängig" gelöscht
  /// werden (bis dahin nur ausgeblendet).
  final Set<String> _pendingDelete = {};
  bool _showArchive = false;

  /// Eingeklappte Abschnitte (Thema-ID bzw. '__none__' für „Ohne Thema").
  final Set<String> _collapsed = {};
  static const _noTopicKey = '__none__';

  /// Verschiebt eine Aufgabe per Drag&Drop in ein anderes Thema (null = ohne).
  Future<void> _moveTodo(AppState state, Todo t, String? topicId) async {
    if (t.topicId == topicId) return;
    await state.saveTodo(
      t.copyWith(topicId: topicId, clearTopicId: topicId == null),
    );
    if (mounted) setState(() {});
  }

  static final _dDate = DateFormat('dd.MM.yyyy', 'de_DE');
  static final _dDateTime = DateFormat('dd.MM.yyyy  HH:mm', 'de_DE');

  Future<(List<TodoTopic>, List<Todo>, List<Player>)> _load(
    AppState state,
  ) async {
    final topics = await state.todoTopics();
    final todos = _showArchive
        ? await state.archivedTodos()
        : await state.todos();
    final team = state.ownTeam;
    final players = team == null ? <Player>[] : await state.playersOf(team.id);
    return (topics, todos, players);
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
  /// Schnell-Erfassung: Blatt mit Text, Thema, Fälligkeit, Verantwortlichen.
  Future<void> _openQuickAdd(AppState state, {String? topicId}) async {
    final team = state.ownTeam;
    final players = team == null ? <Player>[] : await state.playersOf(team.id);
    final topics = await state.todoTopics();
    final todos = await state.todos();
    if (!mounted) return;
    final me = [
      for (final p in players)
        if (state.myPlayerIds.contains(p.id))
          TodoResponsible(playerId: p.id, name: p.displayName),
    ];
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => _QuickAddSheet(
        players: players,
        topics: topics,
        recent: todos,
        me: me,
        initialTopicId: topicId,
        onAddTopic: (title) => state.addTodoTopic(title),
        onSave: (text, topic, due, resp) => state.addTodo(
          text,
          dueDate: due,
          topicId: topic,
          responsible: resp,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  /// Nach links gewischt: ausblenden, mit „Rückgängig"; erst danach löschen.
  void _swipeDelete(AppState state, Todo t) {
    setState(() => _pendingDelete.add(t.id));
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger
        .showSnackBar(
          SnackBar(
            content: Text('„${t.text}" gelöscht'),
            action: SnackBarAction(label: 'Rückgängig', onPressed: () {}),
          ),
        )
        .closed
        .then((reason) async {
          if (reason == SnackBarClosedReason.action) {
            if (mounted) setState(() => _pendingDelete.remove(t.id));
            return;
          }
          await state.deleteTodo(t.id);
          _pendingDelete.remove(t.id);
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
            labelText: 'Thema',
            hintText: 'z.B. Organisation Sommerfest',
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Anlegen'),
          ),
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
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Speichern'),
          ),
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
          'Die Aufgaben bleiben erhalten und rutschen zu „Ohne Thema".',
        ),
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
      await state.addTodo(
        result.text,
        dueDate: result.due,
        topicId: result.topicId,
        responsible: result.responsible,
        mentionUserIds: result.mentionUserIds,
      );
    } else {
      await state.saveTodo(
        todo.copyWith(
          text: result.text,
          dueDate: result.due,
          clearDueDate: result.due == null,
          topicId: result.topicId,
          clearTopicId: result.topicId == null,
          responsible: result.responsible,
        ),
        mentionUserIds: result.mentionUserIds,
      );
    }
    if (mounted) setState(() {});
  }

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
          final visible = todos
              .where((t) => !_pendingDelete.contains(t.id))
              .toList();
          return _showArchive
              ? _archiveView(state, visible, playerMap)
              : _activeView(state, topics, visible, players, playerMap);
        },
      ),
      floatingActionButton: _showArchive
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _openQuickAdd(state),
              icon: const Icon(Icons.add_task),
              label: const Text('Aufgabe'),
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
            'Noch keine Aufgaben.\nTippe unten rechts auf „Aufgabe".',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey.shade600),
          ),
        ),
      );
    }

    return ListView(
      // Platz für den „Aufgabe"-Knopf unten rechts.
      padding: const EdgeInsets.only(bottom: 96),
      children: [
        for (final topic in topics)
          _section(
            state: state,
            sectionKey: topic.id,
            topicId: topic.id,
            title: topic.title,
            todos: byTopic[topic.id] ?? const [],
            players: players,
            playerMap: playerMap,
            allTopics: topics,
            topic: topic,
          ),
        // „Ohne Thema" immer zeigen – auch als Ablageziel zum Herausziehen.
        _section(
          state: state,
          sectionKey: _noTopicKey,
          topicId: null,
          title: 'Ohne Thema',
          todos: noTopic,
          players: players,
          playerMap: playerMap,
          allTopics: topics,
          topic: null,
        ),
      ],
    );
  }

  Widget _archiveView(
    AppState state,
    List<Todo> todos,
    Map<String, Player> playerMap,
  ) {
    if (todos.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Archiv ist leer.', style: TextStyle(color: Colors.grey)),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 12),
      children: [for (final t in todos) _todoTile(state, t, playerMap)],
    );
  }

  /// Ein-/ausklappbarer Abschnitt (Thema oder „Ohne Thema"), zugleich DragTarget
  /// zum Hineinziehen von Aufgaben. Kopf antippen = ein-/ausklappen.
  Widget _section({
    required AppState state,
    required String sectionKey,
    required String? topicId,
    required String title,
    required List<Todo> todos,
    required List<Player> players,
    required Map<String, Player> playerMap,
    required List<TodoTopic> allTopics,
    TodoTopic? topic,
  }) {
    final collapsed = _collapsed.contains(sectionKey);
    return DragTarget<Todo>(
      onWillAcceptWithDetails: (d) => d.data.topicId != topicId,
      onAcceptWithDetails: (d) => _moveTodo(state, d.data, topicId),
      builder: (context, candidate, rejected) {
        final scheme = Theme.of(context).colorScheme;
        final highlight = candidate.isNotEmpty;
        final actions = topic == null
            ? const <Widget>[]
            : <Widget>[
                IconButton(
                  tooltip: 'Aufgabe hinzufügen',
                  icon: const Icon(Icons.add),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _openQuickAdd(state, topicId: topic.id),
                ),
                PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'rename') _renameTopic(state, topic);
                    if (v == 'delete') _deleteTopic(state, topic);
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'rename', child: Text('Umbenennen')),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text('Thema löschen'),
                    ),
                  ],
                ),
              ];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Material(
              color: highlight
                  ? scheme.primaryContainer
                  : scheme.surfaceContainerHighest,
              child: InkWell(
                onTap: () => setState(() {
                  if (collapsed) {
                    _collapsed.remove(sectionKey);
                  } else {
                    _collapsed.add(sectionKey);
                  }
                }),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
                  child: Row(
                    children: [
                      Icon(
                        collapsed ? Icons.chevron_right : Icons.expand_more,
                        size: 22,
                      ),
                      const SizedBox(width: 2),
                      Expanded(
                        child: Text(
                          '$title  (${todos.length})',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
                      ),
                      ...actions,
                    ],
                  ),
                ),
              ),
            ),
            if (!collapsed)
              if (todos.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
                  child: Text(
                    highlight
                        ? 'Hier ablegen'
                        : 'Noch keine Aufgaben – eine Aufgabe hierher ziehen.',
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                  ),
                )
              else
                for (final t in todos) _todoTile(state, t, playerMap),
          ],
        );
      },
    );
  }

  Widget _todoTile(AppState state, Todo t, Map<String, Player> playerMap) {
    final sub = <Widget>[];
    if (t.responsible.isNotEmpty) {
      sub.add(
        Wrap(
          spacing: 6,
          runSpacing: 2,
          children: t.responsible.map((r) {
            final p = _resolveResponsible(r, playerMap);
            return Chip(
              avatar: p != null
                  ? PlayerAvatar(player: p, radius: 10)
                  : const CircleAvatar(
                      radius: 10,
                      child: Icon(Icons.person, size: 12),
                    ),
              label: Text(r.name, style: const TextStyle(fontSize: 12)),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              padding: EdgeInsets.zero,
            );
          }).toList(),
        ),
      );
    }
    if (t.dueDate != null) {
      final overdue = t.isOverdue;
      sub.add(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.event,
              size: 14,
              color: overdue ? Colors.red : Colors.grey.shade600,
            ),
            const SizedBox(width: 4),
            Text(
              'Fällig: ${_dueLabel(t.dueDate!)}',
              style: TextStyle(
                fontSize: 12.5,
                color: overdue ? Colors.red : Colors.grey.shade700,
                fontWeight: overdue ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      );
    }
    if (t.done && t.completedAt != null) {
      sub.add(
        Text(
          'Erledigt: ${_dDateTime.format(t.completedAt!)}',
          style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600),
        ),
      );
    }

    // Wischen: nach rechts = erledigt/wieder offen, nach links = löschen
    // (mit „Rückgängig").
    final tile = Dismissible(
      key: ValueKey(t.id),
      background: Container(
        color: t.done ? Colors.blueGrey : Colors.green.shade600,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 20),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(t.done ? Icons.undo : Icons.check, color: Colors.white),
            const SizedBox(width: 8),
            Text(
              t.done ? 'Wieder offen' : 'Erledigt',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
      secondaryBackground: Container(
        color: Colors.red,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Löschen',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
            SizedBox(width: 8),
            Icon(Icons.delete, color: Colors.white),
          ],
        ),
      ),
      confirmDismiss: (dir) async {
        if (dir == DismissDirection.startToEnd) {
          await state.toggleTodo(t, !t.done);
          return false;
        }
        return true;
      },
      onDismissed: (_) => _swipeDelete(state, t),
      child: ListTile(
        leading: Checkbox(
          value: t.done,
          onChanged: (v) => state.toggleTodo(t, v ?? false),
        ),
        title: Text(
          t.text,
          style: t.done
              ? const TextStyle(
                  decoration: TextDecoration.lineThrough,
                  color: Colors.grey,
                )
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
                        padding: const EdgeInsets.only(bottom: 2),
                        child: w,
                      ),
                  ],
                ),
              ),
        trailing: PopupMenuButton<String>(
          onSelected: (v) => _onMenu(state, t, v),
          itemBuilder: (context) => [
            const PopupMenuItem(value: 'edit', child: Text('Bearbeiten')),
            PopupMenuItem(
              value: t.archived ? 'unarchive' : 'archive',
              child: Text(t.archived ? 'Wiederherstellen' : 'Archivieren'),
            ),
            const PopupMenuItem(value: 'delete', child: Text('Löschen')),
          ],
        ),
      ),
    );

    // Lange drücken und auf einen Thema-Kopf ziehen = Aufgabe dorthin verschieben.
    return LongPressDraggable<Todo>(
      data: t,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 280),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(10),
            boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6)],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.drag_indicator, size: 18),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  t.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
      childWhenDragging: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        alignment: Alignment.centerLeft,
        child: Text(
          t.text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: Colors.grey.shade400),
        ),
      ),
      child: tile,
    );
  }

  Future<void> _onMenu(AppState state, Todo t, String value) async {
    switch (value) {
      case 'edit':
        final team = state.ownTeam;
        final players = team == null
            ? <Player>[]
            : await state.playersOf(team.id);
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

}

/// Ergebnis der Aufgaben-Seite.
class _TaskResult {
  final String text;
  final String? topicId;
  final DateTime? due;
  final List<TodoResponsible> responsible;
  final List<String> mentionUserIds;
  const _TaskResult(
    this.text,
    this.topicId,
    this.due,
    this.responsible,
    this.mentionUserIds,
  );
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
  final List<String> _mentions = [];

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
    Navigator.pop(
      context,
      _TaskResult(text, _topicId, _due, _responsible, List.of(_mentions)),
    );
  }

  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

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
        builder: (_) => _ResponsiblePickerPage(
          players: widget.players,
          initial: _responsible,
        ),
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
            initialValue: widget.topics.any((t) => t.id == _topicId)
                ? _topicId
                : null,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Thema',
              border: OutlineInputBorder(),
            ),
            items: [
              const DropdownMenuItem<String?>(
                value: null,
                child: Text('Ohne Thema'),
              ),
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
              labelText: 'Aufgabe',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Verantwortliche',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              TextButton.icon(
                onPressed: _pickResponsible,
                icon: const Icon(Icons.group_add, size: 18),
                label: const Text('Wählen'),
              ),
            ],
          ),
          if (_responsible.isEmpty)
            Text(
              'Noch niemand gewählt.',
              style: TextStyle(color: Colors.grey.shade600),
            )
          else
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: _responsible.map((r) {
                final p = _resolveResponsible(r, playerMap);
                return InputChip(
                  avatar: p != null
                      ? PlayerAvatar(player: p, radius: 10)
                      : const CircleAvatar(
                          radius: 10,
                          child: Icon(Icons.person, size: 12),
                        ),
                  label: Text(r.name),
                  onDeleted: () => setState(
                    () => _responsible = _responsible
                        .where((x) => x != r)
                        .toList(),
                  ),
                );
              }).toList(),
            ),
          const SizedBox(height: 20),
          const Text(
            'Fälligkeit (optional)',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _pickDue,
                icon: const Icon(Icons.event),
                label: Text(
                  _due == null ? 'Datum wählen' : _dDate.format(_due!),
                ),
              ),
              if (_due != null)
                IconButton(
                  tooltip: 'Fälligkeit entfernen',
                  icon: const Icon(Icons.clear),
                  onPressed: () => setState(() => _due = null),
                ),
            ],
          ),
          const SizedBox(height: 20),
          TrainerMentionField(
            onChanged: (v) => _mentions
              ..clear()
              ..addAll(v),
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
                icon: const Icon(Icons.add),
                onPressed: _addManual,
              ),
            ],
          ),
          if (_manual.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: _manual
                  .map(
                    (n) => InputChip(
                      avatar: const CircleAvatar(
                        radius: 10,
                        child: Icon(Icons.person, size: 12),
                      ),
                      label: Text(n),
                      onDeleted: () => setState(() => _manual.remove(n)),
                    ),
                  )
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

/// Spieler zu einem Verantwortlichen aufloesen: zuerst ueber die ID, sonst ueber
/// den Namen (falls die gespeicherte ID veraltet ist oder der Name frei
/// eingetragen wurde) – damit auch Trainer/Staff ihr Foto behalten.
Player? _resolveResponsible(TodoResponsible r, Map<String, Player> playerMap) {
  if (r.playerId != null) {
    final byId = playerMap[r.playerId];
    if (byId != null) return byId;
  }
  final name = r.name.trim().toLowerCase();
  if (name.isEmpty) return null;
  for (final p in playerMap.values) {
    if (p.displayName.trim().toLowerCase() == name) return p;
  }
  return null;
}

/// Schlüssel eines Verantwortlichen (Spieler-ID, sonst Name).
String _respKey(TodoResponsible r) =>
    r.playerId ?? 'n:${r.name.trim().toLowerCase()}';

/// Schnell-Erfassung als Blatt: Text (Tastatur sofort offen) + Ein-Tipp-Chips
/// für Thema, Fälligkeit und Verantwortliche („Ich" vorausgewählt).
/// „Speichern & neu" speichert und lässt das Blatt für die nächste offen.
class _QuickAddSheet extends StatefulWidget {
  const _QuickAddSheet({
    required this.players,
    required this.topics,
    required this.recent,
    required this.me,
    required this.onSave,
    required this.onAddTopic,
    this.initialTopicId,
  });

  final List<Player> players;
  final List<TodoTopic> topics;
  final List<Todo> recent;
  final List<TodoResponsible> me;
  final String? initialTopicId;
  final Future<void> Function(
    String text,
    String? topicId,
    DateTime? due,
    List<TodoResponsible> responsible,
  )
  onSave;
  final Future<TodoTopic> Function(String title) onAddTopic;

  @override
  State<_QuickAddSheet> createState() => _QuickAddSheetState();
}

class _QuickAddSheetState extends State<_QuickAddSheet> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  late final List<TodoTopic> _topics = List.of(widget.topics);
  late String? _topicId =
      widget.topics.any((t) => t.id == widget.initialTopicId)
      ? widget.initialTopicId
      : null;
  DateTime? _due;

  /// Angezeigte Personen-Chips (Ich + zuletzt verwendete + nachgewählte).
  late final List<TodoResponsible> _people = _initialPeople();
  late final Set<String> _selected = {for (final r in widget.me) _respKey(r)};
  String? _error;
  int _savedCount = 0;
  bool _saving = false;

  static final _dDate = DateFormat('EE, dd.MM.', 'de_DE');

  List<TodoResponsible> _initialPeople() {
    final out = <TodoResponsible>[...widget.me];
    final seen = {for (final r in out) _respKey(r)};
    final todos = [...widget.recent]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    for (final t in todos) {
      for (final r in t.responsible) {
        if (out.length >= 7) break;
        if (seen.add(_respKey(r))) out.add(r);
      }
    }
    return out;
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  DateTime get _today {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  /// Nächster Samstag (heute, falls Samstag).
  DateTime get _saturday {
    final t = _today;
    return t.add(Duration(days: (DateTime.saturday - t.weekday) % 7));
  }

  bool _sameDay(DateTime? a, DateTime b) =>
      a != null && a.year == b.year && a.month == b.month && a.day == b.day;

  Future<void> _save({required bool close}) async {
    final text = _text.text.trim();
    if (text.isEmpty) {
      setState(() => _error = 'Bitte eintragen, was zu tun ist.');
      _focus.requestFocus();
      return;
    }
    final resp = [
      for (final r in _people)
        if (_selected.contains(_respKey(r))) r,
    ];
    if (resp.isEmpty) {
      setState(() => _error = 'Bitte wählen, wer verantwortlich ist.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    await widget.onSave(text, _topicId, _due, resp);
    if (!mounted) return;
    if (close) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _saving = false;
      _savedCount++;
      _text.clear();
    });
    _focus.requestFocus();
  }

  Future<void> _newTopic() async {
    final ctrl = TextEditingController();
    final title = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Neues Thema'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'z.B. Kabine'),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Anlegen'),
          ),
        ],
      ),
    );
    if (title == null || title.isEmpty) return;
    final topic = await widget.onAddTopic(title);
    if (!mounted) return;
    setState(() {
      _topics.add(topic);
      _topicId = topic.id;
    });
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _due ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 2),
      helpText: 'Fälligkeit wählen',
    );
    if (d != null) setState(() => _due = d);
  }

  Future<void> _morePeople() async {
    final current = [
      for (final r in _people)
        if (_selected.contains(_respKey(r))) r,
    ];
    final res = await Navigator.of(context).push<List<TodoResponsible>>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) =>
            _ResponsiblePickerPage(players: widget.players, initial: current),
      ),
    );
    if (res == null || !mounted) return;
    setState(() {
      _selected.clear();
      for (final r in res) {
        final k = _respKey(r);
        _selected.add(k);
        if (!_people.any((x) => _respKey(x) == k)) _people.add(r);
      }
    });
  }

  Widget _row(String label, List<Widget> chips) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: Theme.of(context).hintColor,
          ),
        ),
        const SizedBox(height: 6),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final c in chips)
                Padding(padding: const EdgeInsets.only(right: 8), child: c),
            ],
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final playerMap = {for (final p in widget.players) p.id: p};
    final meKeys = {for (final r in widget.me) _respKey(r)};
    final saturday = _saturday;
    final today = _today;
    final tomorrow = today.add(const Duration(days: 1));
    final customDue =
        _due != null &&
        !_sameDay(_due, today) &&
        !_sameDay(_due, tomorrow) &&
        !_sameDay(_due, saturday);

    Widget dueChip(String label, DateTime? d) => ChoiceChip(
      label: Text(label),
      selected: d == null ? _due == null : _sameDay(_due, d),
      onSelected: (_) => setState(() => _due = d),
    );

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Neue Aufgabe',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                if (_savedCount > 0)
                  Text(
                    '✓ $_savedCount gespeichert',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _text,
              focusNode: _focus,
              autofocus: true,
              minLines: 1,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _save(close: true),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              decoration: InputDecoration(
                hintText: 'Was ist zu tun?',
                filled: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            _row('Thema', [
              ChoiceChip(
                label: const Text('Ohne'),
                selected: _topicId == null,
                onSelected: (_) => setState(() => _topicId = null),
              ),
              for (final t in _topics)
                ChoiceChip(
                  label: Text(t.title),
                  selected: _topicId == t.id,
                  onSelected: (_) => setState(() => _topicId = t.id),
                ),
              ActionChip(
                avatar: const Icon(Icons.add, size: 18),
                label: const Text('Thema'),
                onPressed: _newTopic,
              ),
            ]),
            _row('Fällig', [
              dueChip('Keine', null),
              dueChip('Heute', today),
              dueChip('Morgen', tomorrow),
              if (!_sameDay(saturday, today) && !_sameDay(saturday, tomorrow))
                dueChip(_dDate.format(saturday), saturday),
              customDue
                  ? InputChip(
                      avatar: const Icon(Icons.event, size: 18),
                      label: Text(_dDate.format(_due!)),
                      selected: true,
                      onPressed: _pickDate,
                      onDeleted: () => setState(() => _due = null),
                    )
                  : ActionChip(
                      avatar: const Icon(Icons.event, size: 18),
                      label: const Text('Datum …'),
                      onPressed: _pickDate,
                    ),
            ]),
            _row('Wer', [
              for (final r in _people)
                FilterChip(
                  avatar: switch (_resolveResponsible(r, playerMap)) {
                    final p? => PlayerAvatar(player: p, radius: 11),
                    null => const Icon(Icons.person, size: 18),
                  },
                  label: Text(meKeys.contains(_respKey(r)) ? 'Ich' : r.name),
                  selected: _selected.contains(_respKey(r)),
                  showCheckmark: false,
                  onSelected: (v) => setState(() {
                    _error = null;
                    if (v) {
                      _selected.add(_respKey(r));
                    } else {
                      _selected.remove(_respKey(r));
                    }
                  }),
                ),
              ActionChip(
                avatar: const Icon(Icons.group_add, size: 18),
                label: const Text('Auswählen …'),
                onPressed: _morePeople,
              ),
            ]),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _saving ? null : () => _save(close: false),
                    icon: const Icon(Icons.playlist_add),
                    label: const Text('Speichern & neu'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _saving ? null : () => _save(close: true),
                    icon: const Icon(Icons.check),
                    label: const Text('Speichern'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
