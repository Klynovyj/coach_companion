import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/inbox_message.dart';
import '../state/app_state.dart';
import 'rating_summary_screen.dart';
import 'todos_screen.dart';

/// Persönlicher Posteingang: Benachrichtigungen, die mich betreffen
/// (Vorschlag übernommen/abgelehnt, zu Aufgabe hinzugefügt, erwähnt,
/// wichtige Team-Ereignisse). Antippen markiert gelesen und öffnet das Ziel.
class InboxScreen extends StatefulWidget {
  const InboxScreen({super.key});

  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> {
  final _dt = DateFormat('dd.MM.yyyy · HH:mm', 'de_DE');
  List<InboxMessage> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final items = await context.read<AppState>().inboxMessages();
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  Future<void> _open(InboxMessage m) async {
    final app = context.read<AppState>();
    if (m.unread) await app.markInboxRead(m.id);
    if (!mounted) return;
    switch (m.linkType) {
      case 'match':
        if (m.linkId != null) {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => RatingSummaryScreen(matchId: m.linkId!),
            ),
          );
        }
      case 'todo':
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const TodosScreen()),
        );
    }
    if (mounted) _load();
  }

  Future<void> _markAll() async {
    await context.read<AppState>().markAllInboxRead();
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final hasUnread = _items.any((m) => m.unread);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Posteingang'),
        actions: [
          if (hasUnread)
            TextButton(
              onPressed: _markAll,
              child: const Text(
                'Alle gelesen',
                style: TextStyle(color: Colors.white),
              ),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Keine Benachrichtigungen.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView.separated(
                itemCount: _items.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) => _tile(_items[i]),
              ),
            ),
    );
  }

  Widget _tile(InboxMessage m) {
    final scheme = Theme.of(context).colorScheme;
    final hasLink = m.linkType != null && m.linkId != null;
    return ListTile(
      onTap: hasLink || m.unread ? () => _open(m) : null,
      leading: CircleAvatar(
        backgroundColor: m.unread
            ? scheme.primaryContainer
            : scheme.surfaceContainerHighest,
        child: Icon(
          m.type.icon,
          size: 20,
          color: m.unread ? scheme.onPrimaryContainer : scheme.outline,
        ),
      ),
      title: Text(
        m.title,
        style: TextStyle(
          fontWeight: m.unread ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if ((m.subtitle ?? '').isNotEmpty) Text(m.subtitle!),
          Text(
            '${m.actorName} · ${_dt.format(m.createdAt.toLocal())}',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor),
          ),
        ],
      ),
      trailing: m.unread
          ? Icon(Icons.circle, size: 10, color: scheme.primary)
          : (hasLink ? const Icon(Icons.chevron_right) : null),
      isThreeLine: (m.subtitle ?? '').isNotEmpty,
    );
  }
}
