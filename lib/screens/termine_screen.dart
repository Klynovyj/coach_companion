import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/enums.dart';
import '../models/team_event.dart';
import '../state/app_state.dart';
import '../widgets/app_drawer.dart';
import '../widgets/ui_bits.dart';
import 'event_detail_screen.dart';

class TermineScreen extends StatelessWidget {
  const TermineScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final df = DateFormat("HH:mm 'Uhr'", 'de_DE');

    return Scaffold(
      drawer: const AppDrawer(),
      appBar: AppBar(title: const Text('Termine')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addEvent(context),
        icon: const Icon(Icons.add),
        label: const Text('Termin'),
      ),
      body: FutureBuilder<List<TeamEvent>>(
        future: state.teamEvents(),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final events = snap.data!;
          if (events.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.event_available, size: 56, color: Colors.grey),
                    SizedBox(height: 12),
                    Text(
                      'Noch keine Termine.\nLege z.B. eine Weihnachtsfeier an.',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.only(bottom: 88),
            itemCount: events.length,
            itemBuilder: (context, i) {
              final e = events[i];
              return Card(
                child: InkWell(
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => EventDetailScreen(eventId: e.id),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        DateBlock(date: e.date),
                        const SizedBox(width: 12),
                        Text(e.type.symbol, style: const TextStyle(fontSize: 22)),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(e.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700, fontSize: 15)),
                              const SizedBox(height: 2),
                              Text([
                                e.type.label,
                                df.format(e.date),
                                if (e.location != null) e.location!,
                              ].join('  ·  '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodySmall),
                            ],
                          ),
                        ),
                        const Icon(Icons.chevron_right),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _addEvent(BuildContext context) async {
    final data = await showEventDialog(context);
    if (data == null || !context.mounted) return;
    await context.read<AppState>().addTeamEvent(
          title: data.title,
          type: data.type,
          date: data.date,
          location: data.location,
          note: data.note,
        );
  }
}

class EventDialogData {
  final String title;
  final TeamEventType type;
  final DateTime date;
  final String? location;
  final String? note;
  const EventDialogData(
      this.title, this.type, this.date, this.location, this.note);
}

/// Termin anlegen/bearbeiten als Vollbild-Formular (statt engem Popup).
Future<EventDialogData?> showEventDialog(BuildContext context,
    {TeamEvent? existing}) {
  return Navigator.push<EventDialogData>(
    context,
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _EventFormPage(existing: existing),
    ),
  );
}

class _EventFormPage extends StatefulWidget {
  const _EventFormPage({this.existing});

  final TeamEvent? existing;

  @override
  State<_EventFormPage> createState() => _EventFormPageState();
}

class _EventFormPageState extends State<_EventFormPage> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _locCtrl;
  late final TextEditingController _noteCtrl;
  late TeamEventType _type;
  late DateTime _date;
  final _df = DateFormat('dd.MM.yyyy  HH:mm', 'de_DE');

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _titleCtrl = TextEditingController(text: e?.title ?? '');
    _locCtrl = TextEditingController(text: e?.location ?? '');
    _noteCtrl = TextEditingController(text: e?.note ?? '');
    _type = e?.type ?? TeamEventType.feier;
    _date = e?.date ?? DateTime.now().add(const Duration(days: 7));
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _locCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(_date.year - 1),
      lastDate: DateTime(_date.year + 2),
    );
    if (d == null || !mounted) return;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_date),
    );
    if (!mounted) return;
    setState(() => _date =
        DateTime(d.year, d.month, d.day, t?.hour ?? 18, t?.minute ?? 0));
  }

  void _save() {
    if (_titleCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Bitte einen Titel eingeben.')));
      return;
    }
    Navigator.pop(
      context,
      EventDialogData(
        _titleCtrl.text.trim(),
        _type,
        _date,
        _locCtrl.text.trim().isEmpty ? null : _locCtrl.text.trim(),
        _noteCtrl.text.trim().isEmpty ? null : _noteCtrl.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(editing ? 'Termin bearbeiten' : 'Termin anlegen'),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('Speichern'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          TextField(
            controller: _titleCtrl,
            autofocus: !editing,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Titel',
              hintText: 'z.B. Weihnachtsfeier',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<TeamEventType>(
            initialValue: _type,
            decoration: const InputDecoration(
              labelText: 'Art',
              border: OutlineInputBorder(),
            ),
            items: TeamEventType.values
                .map((t) => DropdownMenuItem(
                      value: t,
                      child: Text('${t.symbol}  ${t.label}'),
                    ))
                .toList(),
            onChanged: (v) => setState(() => _type = v ?? _type),
          ),
          const SizedBox(height: 16),
          InkWell(
            onTap: _pickDate,
            borderRadius: BorderRadius.circular(4),
            child: InputDecorator(
              decoration: const InputDecoration(
                labelText: 'Datum & Uhrzeit',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.schedule),
              ),
              child: Text(_df.format(_date)),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _locCtrl,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Ort (optional)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _noteCtrl,
            minLines: 3,
            maxLines: 8,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Notiz (optional)',
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.check),
            label: Text(editing ? 'Änderungen speichern' : 'Termin anlegen'),
          ),
        ],
      ),
    );
  }
}
