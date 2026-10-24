import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/cloud_service.dart';
import '../widgets/app_drawer.dart';

/// Einstieg in den Mehrbenutzer-Bereich (Supabase): Login → Teams → Spiele →
/// gemeinsames Live-Spiel in Echtzeit.
class CloudScreen extends StatefulWidget {
  const CloudScreen({super.key});

  @override
  State<CloudScreen> createState() => _CloudScreenState();
}

class _CloudScreenState extends State<CloudScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      drawer: const AppDrawer(),
      appBar: AppBar(
        title: const Text('Gemeinsam (Cloud)'),
        actions: [
          if (CloudService.ready && CloudService.signedIn)
            IconButton(
              tooltip: 'Abmelden',
              icon: const Icon(Icons.logout),
              onPressed: () async {
                await CloudService.signOut();
                if (mounted) setState(() {});
              },
            ),
        ],
      ),
      body: !CloudService.ready
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Keine Verbindung zur Cloud.\n'
                  'Prüfe die Internetverbindung und starte die App neu.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey),
                ),
              ),
            )
          : StreamBuilder<AuthState>(
              stream: CloudService.authChanges,
              builder: (context, _) {
                if (!CloudService.signedIn) {
                  return _AuthForm(onDone: () => setState(() {}));
                }
                return _TeamsView(onChanged: () => setState(() {}));
              },
            ),
    );
  }
}

// ----------------------------------------------------------------- Auth
class _AuthForm extends StatefulWidget {
  const _AuthForm({required this.onDone});
  final VoidCallback onDone;

  @override
  State<_AuthForm> createState() => _AuthFormState();
}

class _AuthFormState extends State<_AuthForm> {
  final _email = TextEditingController();
  final _pw = TextEditingController();
  final _name = TextEditingController();
  bool _register = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _pw.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_register) {
        await CloudService.signUp(_email.text, _pw.text, _name.text);
        // Falls E-Mail-Bestätigung aus ist, ist man direkt angemeldet.
        if (!CloudService.signedIn) {
          await CloudService.signIn(_email.text, _pw.text);
        }
      } else {
        await CloudService.signIn(_email.text, _pw.text);
      }
      if (mounted) widget.onDone();
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const SizedBox(height: 8),
        Text(_register ? 'Konto erstellen' : 'Anmelden',
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 16),
        if (_register)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: TextField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                  labelText: 'Name', border: OutlineInputBorder()),
            ),
          ),
        TextField(
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
          decoration: const InputDecoration(
              labelText: 'E-Mail', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _pw,
          obscureText: true,
          decoration: const InputDecoration(
              labelText: 'Passwort', border: OutlineInputBorder()),
          onSubmitted: (_) => _submit(),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(color: Colors.red)),
        ],
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(_register ? 'Registrieren' : 'Anmelden'),
        ),
        TextButton(
          onPressed: _busy ? null : () => setState(() => _register = !_register),
          child: Text(_register
              ? 'Ich habe schon ein Konto – Anmelden'
              : 'Neu hier? Konto erstellen'),
        ),
      ],
    );
  }
}

// ----------------------------------------------------------------- Teams
class _TeamsView extends StatefulWidget {
  const _TeamsView({required this.onChanged});
  final VoidCallback onChanged;

  @override
  State<_TeamsView> createState() => _TeamsViewState();
}

class _TeamsViewState extends State<_TeamsView> {
  late Future<List<Map<String, dynamic>>> _future = CloudService.myTeams();

  void _reload() => setState(() => _future = CloudService.myTeams());

  Future<void> _createTeam() async {
    final name = await _prompt('Team anlegen', 'Teamname', 'z.B. Garather SV');
    if (name == null || name.isEmpty) return;
    try {
      await CloudService.createTeam(name);
      _reload();
    } catch (e) {
      _snack('Fehler: $e');
    }
  }

  Future<void> _joinTeam() async {
    final code = await _prompt('Team beitreten', 'Einladungscode', 'z.B. a1b2c3d4');
    if (code == null || code.isEmpty) return;
    try {
      await CloudService.joinTeam(code);
      _reload();
    } catch (e) {
      _snack('Fehler: $e');
    }
  }

  Future<String?> _prompt(String title, String label, String hint) {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(labelText: label, hintText: hint),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('OK')),
        ],
      ),
    );
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _createTeam,
                  icon: const Icon(Icons.group_add),
                  label: const Text('Team anlegen'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _joinTeam,
                  icon: const Icon(Icons.login),
                  label: const Text('Beitreten'),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: FutureBuilder<List<Map<String, dynamic>>>(
            future: _future,
            builder: (context, snap) {
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final teams = snap.data!;
              if (teams.isEmpty) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Noch kein Team.\nLege eins an oder tritt per Code bei.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),
                );
              }
              return ListView(
                children: [
                  for (final t in teams)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.shield_outlined),
                        title: Text(t['name'] ?? 'Team'),
                        subtitle: Text(t['role'] == 'trainer'
                            ? 'Trainer · Code: ${t['invite_code']}'
                            : 'Spieler'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => CloudTeamScreen(
                              teamId: t['id'],
                              teamName: t['name'] ?? 'Team',
                              isTrainer: t['role'] == 'trainer',
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

// ----------------------------------------------------------- Team → Spiele
class CloudTeamScreen extends StatefulWidget {
  const CloudTeamScreen({
    super.key,
    required this.teamId,
    required this.teamName,
    required this.isTrainer,
  });

  final String teamId;
  final String teamName;
  final bool isTrainer;

  @override
  State<CloudTeamScreen> createState() => _CloudTeamScreenState();
}

class _CloudTeamScreenState extends State<CloudTeamScreen> {
  late Future<List<Map<String, dynamic>>> _future =
      CloudService.matches(widget.teamId);
  static final _df = DateFormat('dd.MM.yyyy  HH:mm', 'de_DE');

  void _reload() =>
      setState(() => _future = CloudService.matches(widget.teamId));

  Future<void> _newMatch() async {
    final ctrl = TextEditingController();
    final opp = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Neues Spiel'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Gegner'),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Starten')),
        ],
      ),
    );
    if (opp == null || opp.isEmpty) return;
    try {
      final m = await CloudService.createMatch(widget.teamId, opp);
      if (!mounted) return;
      _reload();
      _open(m);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Fehler: $e')));
      }
    }
  }

  void _open(Map<String, dynamic> m) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CloudMatchScreen(
          match: m,
          teamId: widget.teamId,
          teamName: widget.teamName,
          isTrainer: widget.isTrainer,
        ),
      ),
    ).then((_) => _reload());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.teamName)),
      floatingActionButton: widget.isTrainer
          ? FloatingActionButton.extended(
              onPressed: _newMatch,
              icon: const Icon(Icons.add),
              label: const Text('Spiel'),
            )
          : null,
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _future,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final matches = snap.data!;
          if (matches.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('Noch keine Spiele.',
                    style: TextStyle(color: Colors.grey)),
              ),
            );
          }
          return ListView(
            children: [
              for (final m in matches)
                Card(
                  child: ListTile(
                    title: Text('vs ${m['opponent']}'),
                    subtitle: Text([
                      '${m['own_score']} : ${m['opponent_score']}',
                      if (m['kickoff'] != null)
                        _df.format(DateTime.parse(m['kickoff']).toLocal()),
                      if (m['status'] == 'live') 'LIVE',
                    ].join('  ·  ')),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _open(m),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

// ------------------------------------------------- Spiel → Live (Echtzeit)
class CloudMatchScreen extends StatefulWidget {
  const CloudMatchScreen({
    super.key,
    required this.match,
    required this.teamId,
    required this.teamName,
    required this.isTrainer,
  });

  final Map<String, dynamic> match;
  final String teamId;
  final String teamName;
  final bool isTrainer;

  @override
  State<CloudMatchScreen> createState() => _CloudMatchScreenState();
}

class _CloudMatchScreenState extends State<CloudMatchScreen> {
  late final String _matchId = widget.match['id'];
  int _own = 0;
  int _opp = 0;
  List<Map<String, dynamic>> _events = [];
  RealtimeChannel? _channel;

  @override
  void initState() {
    super.initState();
    _own = widget.match['own_score'] ?? 0;
    _opp = widget.match['opponent_score'] ?? 0;
    _load();
    _channel = CloudService.subscribeEvents(_matchId, _load);
  }

  @override
  void dispose() {
    if (_channel != null) CloudService.removeChannel(_channel!);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final ev = await CloudService.events(_matchId);
      if (!mounted) return;
      setState(() => _events = ev);
    } catch (_) {}
  }

  Future<void> _addGoal(bool own) async {
    final name = own ? await _askText('Torschütze (optional)') : null;
    if (own && name == _cancelled) return;
    _own += own ? 1 : 0;
    _opp += own ? 0 : 1;
    await CloudService.addEvent(
      matchId: _matchId,
      teamId: widget.teamId,
      type: 'goal',
      playerName: (name == null || name.isEmpty) ? null : name,
      note: own ? null : 'Gegner',
    );
    await CloudService.setScore(_matchId, _own, _opp);
    if (mounted) setState(() {});
  }

  Future<void> _addSimple(String type, String label,
      {bool askPlayer = true}) async {
    String? player;
    if (askPlayer) {
      player = await _askText('$label – Spieler (optional)');
      if (player == _cancelled) return;
    }
    await CloudService.addEvent(
      matchId: _matchId,
      teamId: widget.teamId,
      type: type,
      playerName: (player == null || player.isEmpty) ? null : player,
    );
  }

  Future<void> _addComment() async {
    final text = await _askText('Kommentar');
    if (text == _cancelled || text == null || text.isEmpty) return;
    await CloudService.addEvent(
      matchId: _matchId,
      teamId: widget.teamId,
      type: 'comment',
      note: text,
    );
  }

  static const _cancelled = '\u0000cancel';
  Future<String?> _askText(String title) {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, _cancelled),
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('OK')),
        ],
      ),
    );
  }

  String _label(String type) {
    switch (type) {
      case 'goal':
        return '⚽ Tor';
      case 'yellow_card':
        return '🟨 Gelbe Karte';
      case 'red_card':
        return '🟥 Rote Karte';
      case 'comment':
        return '💬 Kommentar';
      default:
        return type;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text('vs ${widget.match['opponent']}')),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: scheme.primary,
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Text('${widget.teamName}   $_own : $_opp   ${widget.match['opponent']}',
                    style: TextStyle(
                        color: scheme.onPrimary,
                        fontSize: 20,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text('Live · Änderungen erscheinen bei allen',
                    style: TextStyle(
                        color: scheme.onPrimary.withValues(alpha: 0.85),
                        fontSize: 12)),
              ],
            ),
          ),
          if (widget.isTrainer)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  FilledButton(
                      onPressed: () => _addGoal(true),
                      child: const Text('⚽ Tor')),
                  FilledButton.tonal(
                      onPressed: () => _addGoal(false),
                      child: const Text('⚽ Gegner')),
                  OutlinedButton(
                      onPressed: () => _addSimple('yellow_card', 'Gelbe Karte'),
                      child: const Text('🟨 Gelb')),
                  OutlinedButton(
                      onPressed: () => _addSimple('red_card', 'Rote Karte'),
                      child: const Text('🟥 Rot')),
                  OutlinedButton(
                      onPressed: _addComment, child: const Text('💬 Kommentar')),
                ],
              ),
            )
          else
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('Nur-Ansicht – der Trainer trägt Ereignisse ein.',
                  style: TextStyle(color: Colors.grey)),
            ),
          const Divider(height: 1),
          Expanded(
            child: _events.isEmpty
                ? const Center(
                    child: Text('Noch keine Ereignisse.',
                        style: TextStyle(color: Colors.grey)))
                : ListView(
                    children: [
                      for (final e in _events.reversed)
                        ListTile(
                          dense: true,
                          leading: Text("${e['minute']}'"),
                          title: Text(_label(e['type'])),
                          subtitle: Text([
                            if (e['player_name'] != null) e['player_name'],
                            if (e['note'] != null) e['note'],
                          ].join('  ·  ')),
                          trailing: widget.isTrainer
                              ? IconButton(
                                  icon: const Icon(Icons.delete_outline,
                                      size: 20),
                                  onPressed: () async {
                                    await CloudService.deleteEvent(e['id']);
                                  },
                                )
                              : null,
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
