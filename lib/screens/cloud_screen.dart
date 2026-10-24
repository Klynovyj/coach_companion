import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/enums.dart';
import '../models/match.dart';
import '../models/player.dart';
import '../services/cloud_service.dart';
import '../state/app_state.dart';
import '../widgets/app_drawer.dart';

/// Lokale Spieler → Cloud-Kader-Datensätze.
List<Map<String, dynamic>> rosterMaps(List<Player> players) => [
      for (final p in players.where((p) => !p.isStaffOnly))
        {
          'first_name': p.firstName,
          'last_name': p.lastName,
          'number': p.number,
          'position': p.position,
        }
    ];

/// Lokaler Spielplan → Cloud-Spiel-Datensätze.
List<Map<String, dynamic>> scheduleMaps(List<GameMatch> matches) => [
      for (final m in matches)
        {
          'opponent': m.opponentName,
          'kickoff': m.kickoff?.toUtc().toIso8601String(),
          'venue': m.venue == Venue.home ? 'Heim' : 'Auswärts',
          'own_score': m.ownScore,
          'opponent_score': m.opponentScore,
          'status': m.status.storageKey,
        }
    ];

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

  void _reload() {
    setState(() {
      _future = CloudService.myTeams();
    });
  }

  Future<void> _createTeam() async {
    final url = await _prompt('Team aus FuPa anlegen', 'FuPa-Teamlink',
        'https://www.fupa.net/team/…');
    if (url == null || !mounted) return; // abgebrochen
    final app = context.read<AppState>();

    // Ohne Link: einfaches Team nur mit Namen.
    if (url.isEmpty) {
      final name =
          await _prompt('Team anlegen', 'Teamname', 'z.B. Garather SV');
      if (name == null || name.isEmpty) return;
      try {
        await CloudService.createTeam(name);
        _reload();
      } catch (e) {
        _snack('Fehler: $e');
      }
      return;
    }

    // Mit FuPa-Link: alles laden (Team, Kader, Spielplan) + Cloud-Team + Upload.
    final navigator = Navigator.of(context);
    final status = ValueNotifier<String>('Starte Import …');
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('FuPa wird geladen …'),
        content: ValueListenableBuilder<String>(
          valueListenable: status,
          builder: (_, s, _) => Row(
            children: [
              const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 16),
              Expanded(child: Text(s)),
            ],
          ),
        ),
      ),
    );
    try {
      final summary =
          await app.connectOwnTeam(url, onProgress: (p) => status.value = p);
      final localTeam = app.ownTeam;
      final List<Player> players =
          localTeam == null ? <Player>[] : await app.playersOf(localTeam.id);
      final roster = rosterMaps(players);
      final schedule = scheduleMaps(app.matches);
      final team = await CloudService.createTeam(summary.teamName);
      await CloudService.uploadRoster(team['id'], roster);
      final added = await CloudService.uploadSchedule(team['id'], schedule);
      // Zurückladen, damit lokale IDs == Cloud-IDs sind (Schreib-Sync).
      final cloudPlayers = await CloudService.players(team['id']);
      final cloudMatches = await CloudService.matches(team['id']);
      await app.downloadCloudTeam(team['id'], summary.teamName,
          players: cloudPlayers, matches: cloudMatches);
      if (mounted) navigator.pop(); // Fortschritt schließen
      _reload();
      _snack('„${summary.teamName}" angelegt · ${roster.length} Spieler, '
          '$added Spiele · geteilt.');
    } catch (e) {
      if (mounted) navigator.pop();
      _snack('Fehler: $e');
    } finally {
      status.dispose();
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

  late final AppState _app = context.read<AppState>();
  RealtimeChannel? _teamChannel;
  bool _autoSyncing = false;

  @override
  void initState() {
    super.initState();
    // Realtime: Änderungen an Spielen/Kader (auch von Kollegen) live übernehmen.
    _teamChannel = CloudService.subscribeTeam(widget.teamId, _onCloudChange);
    // Beim Öffnen automatisch in den lokalen Cache laden (cloud-first).
    _autoSync();
  }

  @override
  void dispose() {
    final ch = _teamChannel;
    if (ch != null) CloudService.removeChannel(ch);
    super.dispose();
  }

  /// Lädt das Team beim Öffnen automatisch in den lokalen Cache – außer es ist
  /// bereits das aktive Abbild (dann kein Wipe, nur Realtime hält es aktuell).
  Future<void> _autoSync() async {
    if (_app.activeCloudTeamId == widget.teamId) return;
    setState(() => _autoSyncing = true);
    try {
      final players = await CloudService.players(widget.teamId);
      final matches = await CloudService.matches(widget.teamId);
      await _app.downloadCloudTeam(widget.teamId, widget.teamName,
          players: players, matches: matches);
    } catch (_) {
      // Offline/Lesefehler: lokaler Cache bleibt wie er ist.
    }
    if (mounted) setState(() => _autoSyncing = false);
  }

  /// Realtime-Callback: Spielliste neu laden und – wenn dieses Team aktiv ist –
  /// den lokalen Cache nachziehen (ohne Wipe).
  Future<void> _onCloudChange() async {
    try {
      final matches = await CloudService.matches(widget.teamId);
      if (!mounted) return;
      setState(() => _future = Future.value(matches));
      await _app.syncCloudMatchesToCache(widget.teamId, matches);
      final players = await CloudService.players(widget.teamId);
      await _app.syncCloudPlayersToCache(widget.teamId, players);
      // Geteilte Bereiche (Nominierung, Karten, Notizen, Bewertungen …) live.
      await _app.resyncCloudAuxData(widget.teamId);
    } catch (_) {}
  }

  void _reload() {
    setState(() {
      _future = CloudService.matches(widget.teamId);
    });
  }

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

  Future<void> _uploadData() async {
    final app = context.read<AppState>();
    final localTeam = app.ownTeam;
    if (localTeam == null) {
      _snack('Keine lokalen Daten vorhanden.');
      return;
    }
    final players = await app.playersOf(localTeam.id);
    final roster = rosterMaps(players);
    final schedule = scheduleMaps(app.matches);
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Daten hochladen'),
        content: Text(
            '${roster.length} Spieler und ${schedule.length} Spiele in die '
            'Cloud laden? Der Kader wird ersetzt; fehlende Spiele werden '
            'ergänzt (bestehende/getrackte bleiben).'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Hochladen')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await CloudService.uploadRoster(widget.teamId, roster);
      final added = await CloudService.uploadSchedule(widget.teamId, schedule);
      _reload();
      _snack('${roster.length} Spieler, $added Spiele hochgeladen.');
    } catch (e) {
      _snack('Fehler: $e');
    }
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _downloadToLocal() async {
    final app = context.read<AppState>();
    final navigator = Navigator.of(context);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(children: [
          SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 16),
          Expanded(child: Text('Team wird in diese App geladen …')),
        ]),
      ),
    );
    try {
      final players = await CloudService.players(widget.teamId);
      final matches = await CloudService.matches(widget.teamId);
      await app.downloadCloudTeam(widget.teamId, widget.teamName,
          players: players, matches: matches);
      if (mounted) navigator.pop();
      _snack('„${widget.teamName}" geladen: ${players.length} Spieler, '
          '${matches.length} Spiele. Siehe Menü → Spielplan/Kader.');
    } catch (e) {
      if (mounted) navigator.pop();
      _snack('Fehler: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.teamName),
        actions: [
          if (widget.isTrainer)
            IconButton(
              tooltip: 'Mitglieder & Rollen',
              icon: const Icon(Icons.group_outlined),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => CloudMembersScreen(
                    teamId: widget.teamId,
                    teamName: widget.teamName,
                  ),
                ),
              ),
            ),
          IconButton(
            tooltip: 'In diese App laden (Kader & Spielplan)',
            icon: const Icon(Icons.cloud_download_outlined),
            onPressed: _downloadToLocal,
          ),
          if (widget.isTrainer)
            IconButton(
              tooltip: 'Kader & Spielplan hochladen',
              icon: const Icon(Icons.cloud_upload_outlined),
              onPressed: _uploadData,
            ),
        ],
      ),
      floatingActionButton: widget.isTrainer
          ? FloatingActionButton.extended(
              onPressed: _newMatch,
              icon: const Icon(Icons.add),
              label: const Text('Spiel'),
            )
          : null,
      body: Column(
        children: [
          if (_autoSyncing)
            const _SyncBanner(),
          Expanded(
            child: FutureBuilder<List<Map<String, dynamic>>>(
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
                              _df.format(
                                  DateTime.parse(m['kickoff']).toLocal()),
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
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------- Mitglieder & Rollen
/// Zeigt die Team-Mitglieder und lässt Trainer Kollegen hochstufen
/// (Spieler ↔ Trainer). Nur Trainer dürfen schreiben – ein Trainer bleibt
/// mindestens erhalten (serverseitig abgesichert).
class CloudMembersScreen extends StatefulWidget {
  const CloudMembersScreen(
      {super.key, required this.teamId, required this.teamName});

  final String teamId;
  final String teamName;

  @override
  State<CloudMembersScreen> createState() => _CloudMembersScreenState();
}

class _CloudMembersScreenState extends State<CloudMembersScreen> {
  late Future<List<Map<String, dynamic>>> _future =
      CloudService.teamMembers(widget.teamId);

  void _reload() => setState(
      () => _future = CloudService.teamMembers(widget.teamId));

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _setRole(Map<String, dynamic> member, String role) async {
    final current = member['role'] as String?;
    if (current == role) return;
    final name = (member['display_name'] as String?)?.trim();
    final label = (name == null || name.isEmpty) ? 'dieses Mitglied' : name;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rolle ändern'),
        content: Text(role == 'trainer'
            ? '$label zum Trainer machen? Trainer dürfen alles eintragen und bearbeiten.'
            : '$label auf Spieler zurückstufen? Spieler haben nur Ansicht.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Ändern')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await CloudService.setMemberRole(
          widget.teamId, member['user_id'] as String, role);
      _reload();
    } catch (e) {
      _snack('Fehler: ${_clean(e)}');
    }
  }

  String _clean(Object e) =>
      e is PostgrestException ? e.message : e.toString();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Mitglieder · ${widget.teamName}')),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _future,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final members = snap.data!;
          if (members.isEmpty) {
            return const Center(
                child: Text('Noch keine Mitglieder.',
                    style: TextStyle(color: Colors.grey)));
          }
          return ListView(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(
                  'Trainer dürfen eintragen und bearbeiten. Spieler sehen nur zu. '
                  'Stufe Trainer-Kollegen hier hoch.',
                  style: TextStyle(color: Colors.grey),
                ),
              ),
              for (final m in members)
                _MemberTile(
                  member: m,
                  onSetRole: (role) => _setRole(m, role),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _MemberTile extends StatelessWidget {
  const _MemberTile({required this.member, required this.onSetRole});

  final Map<String, dynamic> member;
  final void Function(String role) onSetRole;

  @override
  Widget build(BuildContext context) {
    final name = (member['display_name'] as String?)?.trim();
    final role = member['role'] as String? ?? 'spieler';
    final isMe = member['is_me'] == true;
    final isTrainer = role == 'trainer';
    final shown = (name == null || name.isEmpty) ? 'Unbekannt' : name;
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          child: Icon(isTrainer ? Icons.sports : Icons.person),
        ),
        title: Text(isMe ? '$shown (du)' : shown),
        subtitle: Text(isTrainer ? 'Trainer' : 'Spieler'),
        trailing: isMe
            ? const Chip(label: Text('du'))
            : (isTrainer
                ? OutlinedButton(
                    onPressed: () => onSetRole('spieler'),
                    child: const Text('Zu Spieler'),
                  )
                : FilledButton.tonal(
                    onPressed: () => onSetRole('trainer'),
                    child: const Text('Zu Trainer'),
                  )),
      ),
    );
  }
}

/// Schlanke Leiste, während das Team beim Öffnen in den lokalen Cache geladen
/// wird (Auto-Sync, cloud-first).
class _SyncBanner extends StatelessWidget {
  const _SyncBanner();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: scheme.onSecondaryContainer),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text('Team wird synchronisiert …',
                  style: TextStyle(color: scheme.onSecondaryContainer)),
            ),
          ],
        ),
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
  List<Map<String, dynamic>> _players = [];
  RealtimeChannel? _channel;

  @override
  void initState() {
    super.initState();
    _own = widget.match['own_score'] ?? 0;
    _opp = widget.match['opponent_score'] ?? 0;
    _load();
    _loadPlayers();
    _channel = CloudService.subscribeEvents(_matchId, _load);
  }

  Future<void> _loadPlayers() async {
    try {
      final ps = await CloudService.players(widget.teamId);
      if (mounted) setState(() => _players = ps);
    } catch (_) {}
  }

  /// Spieler aus dem Cloud-Kader wählen. null = abgebrochen,
  /// Record mit id=null/name=null = „ohne".
  Future<({String? id, String? name})?> _pickCloudPlayer(String title) async {
    if (_players.isEmpty) await _loadPlayers(); // evtl. erst jetzt hochgeladen
    if (!mounted) return null;
    if (_players.isEmpty) {
      final t = await _askText('$title – Name (optional)');
      if (t == _cancelled) return null;
      return (id: null, name: (t == null || t.isEmpty) ? null : t);
    }
    return showModalBottomSheet<({String? id, String? name})>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.7),
          child: ListView(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text(title,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 16)),
              ),
              ListTile(
                leading: const CircleAvatar(child: Icon(Icons.block)),
                title: const Text('— ohne —'),
                onTap: () => Navigator.pop(context, (id: null, name: null)),
              ),
              for (final p in _players)
                ListTile(
                  leading: CircleAvatar(child: Text('${p['number'] ?? ''}')),
                  title: Text([p['first_name'], p['last_name']]
                      .where((x) => x != null && '$x'.isNotEmpty)
                      .join(' ')),
                  subtitle: p['position'] != null ? Text('${p['position']}') : null,
                  onTap: () => Navigator.pop(context, (
                    id: p['id'] as String,
                    name: [p['first_name'], p['last_name']]
                        .where((x) => x != null && '$x'.isNotEmpty)
                        .join(' '),
                  )),
                ),
            ],
          ),
        ),
      ),
    );
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
    ({String? id, String? name})? pick;
    if (own) {
      pick = await _pickCloudPlayer('Torschütze');
      if (pick == null) return; // abgebrochen
    }
    _own += own ? 1 : 0;
    _opp += own ? 0 : 1;
    await CloudService.addEvent(
      matchId: _matchId,
      teamId: widget.teamId,
      type: 'goal',
      playerId: pick?.id,
      playerName: pick?.name,
      note: own ? null : 'Gegner',
    );
    await CloudService.setScore(_matchId, _own, _opp);
    if (mounted) setState(() {});
  }

  Future<void> _addSimple(String type, String label) async {
    final pick = await _pickCloudPlayer(label);
    if (pick == null) return; // abgebrochen
    await CloudService.addEvent(
      matchId: _matchId,
      teamId: widget.teamId,
      type: type,
      playerId: pick.id,
      playerName: pick.name,
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
