import 'package:flutter/material.dart';

import '../services/cloud_service.dart';

/// Admin-Screen: legt pro Team-Mitglied fest, wer die KI-Funktionen nutzen darf
/// – getrennt für Gemini (Grafik-Bearbeitung) und Claude (Co-Trainer). Nur der
/// Team-Ersteller (Admin) kommt hierher; die Server-Freigabe erzwingt das zudem.
class AiPermissionsScreen extends StatefulWidget {
  const AiPermissionsScreen({
    super.key,
    required this.teamId,
    required this.teamName,
  });

  final String teamId;
  final String teamName;

  @override
  State<AiPermissionsScreen> createState() => _AiPermissionsScreenState();
}

class _AiPermissionsScreenState extends State<AiPermissionsScreen> {
  late Future<List<Map<String, dynamic>>> _future;
  List<Map<String, dynamic>> _members = [];

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<Map<String, dynamic>>> _load() async {
    final rows = await CloudService.teamMembers(widget.teamId);
    _members = [for (final r in rows) Map<String, dynamic>.from(r)];
    return _members;
  }

  Future<void> _set(Map<String, dynamic> member, String kind, bool value) async {
    final userId = member['user_id'] as String;
    final col = kind == 'image' ? 'ai_image_enabled' : 'ai_coach_enabled';
    final prev = member[col];
    setState(() => member[col] = value);
    try {
      await CloudService.setAiPermission(widget.teamId, userId, kind, value);
    } catch (e) {
      if (!mounted) return;
      setState(() => member[col] = prev);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Konnte nicht speichern: $e')),
      );
    }
  }

  String _name(Map<String, dynamic> m) {
    final name = (m['display_name'] as String?)?.trim();
    if (name != null && name.isNotEmpty) return name;
    final mail = (m['email'] as String?)?.trim();
    if (mail != null && mail.isNotEmpty) return mail;
    return 'Unbekannt';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('KI-Berechtigungen · ${widget.teamName}')),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Mitglieder konnten nicht geladen werden.\n${snap.error}',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          if (_members.isEmpty) {
            return const Center(child: Text('Noch keine Mitglieder.'));
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
            children: [
              Card(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: const Padding(
                  padding: EdgeInsets.all(14),
                  child: Text(
                    'Lege fest, wer die KI nutzen darf. Jede KI-Nutzung kostet '
                    'Geld (pro Bild bzw. pro Übung). Standardmäßig ist alles an.',
                    style: TextStyle(fontSize: 13),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              for (final m in _members) _memberCard(m),
            ],
          );
        },
      ),
    );
  }

  Widget _memberCard(Map<String, dynamic> m) {
    final isMe = m['is_me'] == true;
    final isAdmin = m['is_admin'] == true;
    final role = m['role'] as String? ?? 'spieler';
    final shown = _name(m);
    final subtitle = isAdmin
        ? 'Admin · Ersteller'
        : (role == 'trainer' ? 'Trainer' : 'Spieler');
    final aiImage = m['ai_image_enabled'] != false;
    final aiCoach = m['ai_coach_enabled'] != false;
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: CircleAvatar(
              child: Icon(
                isAdmin
                    ? Icons.shield
                    : (role == 'trainer' ? Icons.sports : Icons.person),
              ),
            ),
            title: Text(isMe ? '$shown (du)' : shown),
            subtitle: Text(subtitle),
          ),
          SwitchListTile(
            value: aiImage,
            onChanged: (v) => _set(m, 'image', v),
            secondary: const Icon(Icons.auto_awesome),
            dense: true,
            title: const Text('Gemini – Grafik-KI'),
            subtitle: const Text('„Mit KI bearbeiten" bei Grafiken'),
          ),
          SwitchListTile(
            value: aiCoach,
            onChanged: (v) => _set(m, 'coach', v),
            secondary: const Icon(Icons.sports_soccer),
            dense: true,
            title: const Text('Claude – Co-Trainer'),
            subtitle: const Text('KI im Trainings-Planer (Übungen, Skizzen)'),
          ),
        ],
      ),
    );
  }
}
