import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/enums.dart';
import '../models/team_event.dart';
import '../state/app_state.dart';
import 'event_detail_screen.dart';

class TermineScreen extends StatelessWidget {
  const TermineScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final df = DateFormat('EEE, dd.MM.yyyy • HH:mm', 'de_DE');

    return Scaffold(
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
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor:
                        Theme.of(context).colorScheme.secondaryContainer,
                    child: Text(e.type.symbol),
                  ),
                  title: Text(e.title,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text([
                    df.format(e.date),
                    if (e.location != null) e.location!,
                  ].join('  ·  ')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => EventDetailScreen(eventId: e.id),
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

Future<EventDialogData?> showEventDialog(BuildContext context,
    {TeamEvent? existing}) {
  final titleCtrl = TextEditingController(text: existing?.title ?? '');
  final locCtrl = TextEditingController(text: existing?.location ?? '');
  final noteCtrl = TextEditingController(text: existing?.note ?? '');
  var type = existing?.type ?? TeamEventType.feier;
  var date = existing?.date ?? DateTime.now().add(const Duration(days: 7));
  final df = DateFormat('dd.MM.yyyy HH:mm', 'de_DE');

  return showDialog<EventDialogData>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(existing == null ? 'Termin anlegen' : 'Termin bearbeiten'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleCtrl,
                decoration: const InputDecoration(
                    labelText: 'Titel', hintText: 'z.B. Weihnachtsfeier'),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<TeamEventType>(
                initialValue: type,
                decoration: const InputDecoration(labelText: 'Art'),
                items: TeamEventType.values
                    .map((t) => DropdownMenuItem(
                          value: t,
                          child: Text('${t.symbol}  ${t.label}'),
                        ))
                    .toList(),
                onChanged: (v) => setState(() => type = v ?? type),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () async {
                  final d = await showDatePicker(
                    context: context,
                    initialDate: date,
                    firstDate: DateTime(date.year - 1),
                    lastDate: DateTime(date.year + 2),
                  );
                  if (d == null) return;
                  if (!context.mounted) return;
                  final t = await showTimePicker(
                    context: context,
                    initialTime: TimeOfDay.fromDateTime(date),
                  );
                  setState(() => date = DateTime(
                      d.year, d.month, d.day, t?.hour ?? 18, t?.minute ?? 0));
                },
                icon: const Icon(Icons.schedule),
                label: Text(df.format(date)),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: locCtrl,
                decoration: const InputDecoration(labelText: 'Ort (optional)'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: noteCtrl,
                decoration:
                    const InputDecoration(labelText: 'Notiz (optional)'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Abbrechen')),
          FilledButton(
            onPressed: () {
              if (titleCtrl.text.trim().isEmpty) return;
              Navigator.pop(
                context,
                EventDialogData(
                  titleCtrl.text.trim(),
                  type,
                  date,
                  locCtrl.text.trim().isEmpty ? null : locCtrl.text.trim(),
                  noteCtrl.text.trim().isEmpty ? null : noteCtrl.text.trim(),
                ),
              );
            },
            child: const Text('Speichern'),
          ),
        ],
      ),
    ),
  );
}
