import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/enums.dart';
import '../models/match.dart';
import '../models/player.dart';
import '../services/cloud_service.dart';
import '../state/app_state.dart';
import '../widgets/app_drawer.dart';
import 'home_screen.dart' show homeTabNotifier;

/// Lokale Spieler → Cloud-Kader-Datensätze (mit stabiler id).
List<Map<String, dynamic>> rosterMaps(List<Player> players) => [
      for (final p in players.where((p) => !p.isStaffOnly))
        {
          'id': p.id,
          'first_name': p.firstName,
          'last_name': p.lastName,
          'number': p.number,
          'position': p.position,
        }
    ];

/// Lokaler Spielplan → Cloud-Spiel-Datensätze (mit stabiler id).
List<Map<String, dynamic>> scheduleMaps(List<GameMatch> matches) => [
      for (final m in matches)
        {
          'id': m.id,
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
      final team =
          await CloudService.createTeam(summary.teamName, fupaUrl: url);
      await CloudService.uploadRoster(team['id'], roster);
      final added = await CloudService.uploadSchedule(team['id'], schedule);
      // Zurückladen, damit lokale IDs == Cloud-IDs sind (Schreib-Sync).
      final cloudPlayers = await CloudService.players(team['id']);
      final cloudMatches = await CloudService.matches(team['id']);
      await app.downloadCloudTeam(team['id'], summary.teamName,
          players: cloudPlayers, matches: cloudMatches, fupaUrl: url);
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
    final who = CloudService.displayName ?? CloudService.email ?? '—';
    return Column(
      children: [
        Container(
          width: double.infinity,
          color: Theme.of(context).colorScheme.secondaryContainer,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.account_circle,
                  size: 18,
                  color: Theme.of(context).colorScheme.onSecondaryContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Angemeldet als $who',
                  style: TextStyle(
                      color:
                          Theme.of(context).colorScheme.onSecondaryContainer),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
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
                              fupaUrl: t['fupa_url'] as String?,
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
    this.fupaUrl,
  });

  final String teamId;
  final String teamName;
  final bool isTrainer;
  final String? fupaUrl;

  @override
  State<CloudTeamScreen> createState() => _CloudTeamScreenState();
}

class _CloudTeamScreenState extends State<CloudTeamScreen> {
  late final AppState _app = context.read<AppState>();
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _activate();
  }

  /// Macht das Team aktiv und startet den Realtime-Sync. Ist es schon aktiv,
  /// wird nur das Abo sichergestellt (kein Wipe).
  Future<void> _activate() async {
    if (_app.activeCloudTeamId == widget.teamId) {
      _app.ensureTeamSync(widget.teamId);
      return;
    }
    setState(() => _syncing = true);
    try {
      final players = await CloudService.players(widget.teamId);
      final matches = await CloudService.matches(widget.teamId);
      await _app.downloadCloudTeam(widget.teamId, widget.teamName,
          players: players, matches: matches, fupaUrl: widget.fupaUrl);
    } catch (_) {
      // Offline/Lesefehler: lokaler Cache bleibt wie er ist.
    }
    if (mounted) setState(() => _syncing = false);
  }

  /// Wechselt in die normale App (Spielplan=0, Kader=1) und schließt die
  /// Cloud-Seiten.
  void _goHomeTab(int index) {
    homeTabNotifier.value = index;
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  Future<void> _resyncFupa() async {
    final navigator = Navigator.of(context);
    final status = ValueNotifier<String>('Aktualisiere aus FuPa …');
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('FuPa-Aktualisierung'),
        content: ValueListenableBuilder<String>(
          valueListenable: status,
          builder: (_, s, _) => Row(children: [
            const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 16),
            Expanded(child: Text(s)),
          ]),
        ),
      ),
    );
    try {
      final sum = await _app.resyncOwnTeam(onProgress: (p) => status.value = p);
      if (mounted) navigator.pop();
      _snack('Aktualisiert: ${sum.players} Spieler, ${sum.matches} Spiele – geteilt.');
    } catch (e) {
      if (mounted) navigator.pop();
      _snack('Fehler: ${_err(e)}');
    } finally {
      status.dispose();
    }
  }

  String _err(Object e) => e is PostgrestException ? e.message : e.toString();

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
          players: players, matches: matches, fupaUrl: widget.fupaUrl);
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
    final scheme = Theme.of(context).colorScheme;
    final hasFupa = widget.fupaUrl?.isNotEmpty ?? false;
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
            tooltip: 'Neu aus Cloud laden',
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
      body: Column(
        children: [
          if (_syncing) const _SyncBanner(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Card(
                  color: scheme.secondaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Icon(Icons.cloud_done_outlined,
                              color: scheme.onSecondaryContainer),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text('„${widget.teamName}" ist aktiv',
                                style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: scheme.onSecondaryContainer)),
                          ),
                        ]),
                        const SizedBox(height: 8),
                        Text(
                          'Spielplan, Kader, Nominierung, Aufstellung, '
                          'Live-Tracking, Karten, Notizen, Bewertungen, Aufgaben '
                          'und Gespräche nutzt du direkt in der App – alles wird '
                          'für alle synchronisiert.',
                          style:
                              TextStyle(color: scheme.onSecondaryContainer),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.event_note),
                    title: const Text('Zum Spielplan'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _goHomeTab(0),
                  ),
                ),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.groups),
                    title: const Text('Zum Kader'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _goHomeTab(1),
                  ),
                ),
                if (widget.isTrainer && hasFupa)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.sync),
                      title: const Text('Aus FuPa aktualisieren'),
                      subtitle: const Text(
                          'Kader & Spielplan neu laden und teilen'),
                      onTap: _resyncFupa,
                    ),
                  ),
              ],
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

  void _reload() {
    setState(() {
      _future = CloudService.teamMembers(widget.teamId);
    });
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _setRole(Map<String, dynamic> member, String role) async {
    final current = member['role'] as String?;
    if (current == role) return;
    final name = (member['display_name'] as String?)?.trim();
    final mail = (member['email'] as String?)?.trim();
    final label = (name != null && name.isNotEmpty)
        ? name
        : (mail != null && mail.isNotEmpty ? mail : 'dieses Mitglied');
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
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.cloud_off, size: 40, color: Colors.grey),
                    const SizedBox(height: 12),
                    const Text(
                      'Mitglieder konnten nicht geladen werden.\n'
                      'Die Rollen-Funktion ist in der Cloud möglicherweise '
                      'noch nicht eingerichtet.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      onPressed: _reload,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Erneut versuchen'),
                    ),
                  ],
                ),
              ),
            );
          }
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
    final mail = (member['email'] as String?)?.trim();
    final role = member['role'] as String? ?? 'spieler';
    final isMe = member['is_me'] == true;
    final isTrainer = role == 'trainer';
    final shown = (name != null && name.isNotEmpty)
        ? name
        : (mail != null && mail.isNotEmpty ? mail : 'Unbekannt');
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
