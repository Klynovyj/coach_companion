import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/enums.dart';
import '../models/match.dart';
import '../models/player.dart';
import '../services/cloud_service.dart';
import '../state/app_state.dart';

/// Lokale Spieler → Cloud-Kader-Datensätze (mit stabiler id + Foto).
List<Map<String, dynamic>> rosterMaps(List<Player> players) => [
  for (final p in players.where((p) => !p.isStaffOnly))
    {
      'id': p.id,
      'first_name': p.firstName,
      'last_name': p.lastName,
      'number': p.number,
      'position': p.position,
      'photo': p.photoPath,
      'photo_fupa': p.fupaPhoto,
      'photo_custom': p.customPhoto,
      'use_custom_photo': p.useCustomPhoto ? 1 : 0,
      'source': p.source.storageKey,
      'suspended_games': p.suspendedGames,
      'suspension_competition': p.suspensionCompetition,
      'suspension_from': p.suspensionFrom?.toIso8601String(),
    },
];

/// Lokaler Spielplan → Cloud-Spiel-Datensätze (mit stabiler id + Gegner-Logo).
List<Map<String, dynamic>> scheduleMaps(List<GameMatch> matches) => [
  for (final m in matches)
    {
      'id': m.id,
      'opponent': m.opponentName,
      'opponent_logo': m.opponentLogoPath,
      'kickoff': m.kickoff?.toUtc().toIso8601String(),
      'venue': m.venue == Venue.home ? 'Heim' : 'Auswärts',
      'own_score': m.ownScore,
      'opponent_score': m.opponentScore,
      'status': m.status.storageKey,
      'fupa_match_slug': m.fupaMatchSlug,
    },
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
      appBar: AppBar(
        title: const Text('Konto & Team'),
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
        Text(
          _register ? 'Konto erstellen' : 'Anmelden',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 16),
        if (_register)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: TextField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Name',
                border: OutlineInputBorder(),
              ),
            ),
          ),
        TextField(
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
          decoration: const InputDecoration(
            labelText: 'E-Mail',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _pw,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'Passwort',
            border: OutlineInputBorder(),
          ),
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
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(_register ? 'Registrieren' : 'Anmelden'),
        ),
        TextButton(
          onPressed: _busy
              ? null
              : () => setState(() => _register = !_register),
          child: Text(
            _register
                ? 'Ich habe schon ein Konto – Anmelden'
                : 'Neu hier? Konto erstellen',
          ),
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
    final url = await _prompt(
      'Team aus FuPa anlegen',
      'FuPa-Teamlink',
      'https://www.fupa.net/team/…',
    );
    if (url == null || !mounted) return; // abgebrochen
    final app = context.read<AppState>();

    // Ohne Link: einfaches Team nur mit Namen.
    if (url.isEmpty) {
      final name = await _prompt(
        'Team anlegen',
        'Teamname',
        'z.B. Garather SV',
      );
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
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 16),
              Expanded(child: Text(s)),
            ],
          ),
        ),
      ),
    );
    try {
      final summary = await app.connectOwnTeam(
        url,
        onProgress: (p) => status.value = p,
      );
      final localTeam = app.ownTeam;
      final List<Player> players = localTeam == null
          ? <Player>[]
          : await app.playersOf(localTeam.id);
      final roster = rosterMaps(players);
      final schedule = scheduleMaps(app.matches);
      final team = await CloudService.createTeam(
        summary.teamName,
        fupaUrl: url,
      );
      await CloudService.uploadRoster(team['id'], roster);
      final added = await CloudService.uploadSchedule(team['id'], schedule);
      // Logo + Kurzname am Cloud-Team hinterlegen.
      await CloudService.updateTeam(team['id'], {
        'logo': localTeam?.logoPath,
        'short_name': localTeam?.shortName,
      });
      // Zurückladen, damit lokale IDs == Cloud-IDs sind (Schreib-Sync).
      final cloudPlayers = await CloudService.players(team['id']);
      final cloudMatches = await CloudService.matches(team['id']);
      await app.downloadCloudTeam(
        team['id'],
        summary.teamName,
        players: cloudPlayers,
        matches: cloudMatches,
        fupaUrl: url,
        logoPath: localTeam?.logoPath,
        shortName: localTeam?.shortName,
      );
      if (mounted) navigator.pop(); // Fortschritt schließen
      _reload();
      _snack(
        '„${summary.teamName}" angelegt · ${roster.length} Spieler, '
        '$added Spiele · geteilt.',
      );
    } catch (e) {
      if (mounted) navigator.pop();
      _snack('Fehler: $e');
    } finally {
      status.dispose();
    }
  }

  /// Voller FuPa-Import jetzt (Kader, Fotos, Logo, Statistik, Geburtsdatum) –
  /// umgeht die 6h-Drossel. Nur fürs aktive Trainer-Team mit FuPa-Link.
  Future<void> _refreshFupa(Map<String, dynamic> team) async {
    final app = context.read<AppState>();
    // Link ermitteln: Cloud-Team → lokales Team → ggf. erfragen und merken.
    var url = (team['fupa_url'] as String?)?.trim();
    if (url == null || url.isEmpty) url = app.ownTeam?.fupaUrl?.trim();
    if (url == null || url.isEmpty) {
      final entered = await _prompt(
        'FuPa verknüpfen',
        'FuPa-Teamlink',
        'https://www.fupa.net/team/…',
      );
      if (entered == null || entered.trim().isEmpty || !mounted) return;
      url = entered.trim();
    }
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
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 16),
              Expanded(child: Text(s)),
            ],
          ),
        ),
      ),
    );
    try {
      final summary = await app.refreshFromFupaNow(
        url: url,
        onProgress: (p) => status.value = p,
      );
      if (mounted) navigator.pop();
      _reload();
      _snack(
        summary == null
            ? 'Kein FuPa-Link hinterlegt.'
            : 'Aktualisiert · ${summary.players} Spieler, ${summary.matches} Spiele.',
      );
    } catch (e) {
      if (mounted) navigator.pop();
      _snack('Fehler: $e');
    } finally {
      status.dispose();
    }
  }

  Future<void> _joinTeam() async {
    final code = await _prompt(
      'Team beitreten',
      'Einladungscode',
      'z.B. a1b2c3d4',
    );
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
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  String _err(Object e) => e is PostgrestException ? e.message : e.toString();

  /// Eigenen Anzeigenamen (Vor- und Nachname) setzen – erscheint in der
  /// Mitgliederliste bei allen und in der Kopfzeile.
  Future<void> _editName() async {
    final cur = CloudService.displayName ?? '';
    final parts = cur.split(' ');
    final first = TextEditingController(
      text: parts.isNotEmpty ? parts.first : '',
    );
    final last = TextEditingController(
      text: parts.length > 1 ? parts.sublist(1).join(' ') : '',
    );
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Mein Name'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: first,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Vorname'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: last,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Nachname'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final name = [
      first.text.trim(),
      last.text.trim(),
    ].where((s) => s.isNotEmpty).join(' ');
    if (name.isEmpty) return;
    try {
      await CloudService.setDisplayName(name);
      if (mounted) setState(() {});
      _snack('Name gespeichert.');
    } catch (e) {
      _snack('Fehler: ${_err(e)}');
    }
  }

  /// Macht ein Team zum aktiven Team (lädt es in den lokalen Cache + startet
  /// den Realtime-Sync). Ab dann laufen alle normalen App-Funktionen darüber.
  Future<void> _activate(
    Map<String, dynamic> team, {
    bool force = false,
  }) async {
    final app = context.read<AppState>();
    final id = team['id'] as String;
    final name = (team['name'] as String?) ?? 'Team';
    if (!force && app.activeCloudTeamId == id) {
      app.ensureTeamSync(id);
      _snack('„$name" ist bereits aktiv.');
      return;
    }
    final navigator = Navigator.of(context);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 16),
            Expanded(child: Text('Team wird aktiviert …')),
          ],
        ),
      ),
    );
    try {
      final players = await CloudService.players(id);
      final matches = await CloudService.matches(id);
      await app.downloadCloudTeam(
        id,
        name,
        players: players,
        matches: matches,
        fupaUrl: team['fupa_url'] as String?,
        logoPath: team['logo'] as String?,
        shortName: team['short_name'] as String?,
      );
      if (mounted) navigator.pop();
      _snack('„$name" ist jetzt aktiv – nutze die App-Funktionen.');
    } catch (e) {
      if (mounted) navigator.pop();
      _snack('Fehler: ${_err(e)}');
    }
  }

  void _openMembers(Map<String, dynamic> team) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CloudMembersScreen(
          teamId: team['id'] as String,
          teamName: (team['name'] as String?) ?? 'Team',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = CloudService.displayName;
    final who = name ?? CloudService.email ?? '—';
    final activeId = context.watch<AppState>().activeCloudTeamId;
    return Column(
      children: [
        Material(
          color: scheme.secondaryContainer,
          child: InkWell(
            onTap: _editName,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    Icons.account_circle,
                    size: 18,
                    color: scheme.onSecondaryContainer,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      name == null
                          ? 'Angemeldet als $who · Name festlegen'
                          : 'Angemeldet als $who',
                      style: TextStyle(color: scheme.onSecondaryContainer),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Icon(
                    Icons.edit,
                    size: 16,
                    color: scheme.onSecondaryContainer,
                  ),
                ],
              ),
            ),
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
                    _TeamCard(
                      team: t,
                      isActive: t['id'] == activeId,
                      onActivate: () => _activate(t),
                      onMembers: () => _openMembers(t),
                      onRefreshFupa: () => _refreshFupa(t),
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

/// Kompakte Team-Karte: antippen = aktiv setzen. Beim aktiven Team (Trainer)
/// gibt es den Zugang zu „Mitglieder & Rollen"; Spielplan/Kader/Ergebnisse
/// halten sich automatisch aktuell (kein manuelles Synchronisieren).
class _TeamCard extends StatelessWidget {
  const _TeamCard({
    required this.team,
    required this.isActive,
    required this.onActivate,
    required this.onMembers,
    required this.onRefreshFupa,
  });

  final Map<String, dynamic> team;
  final bool isActive;
  final VoidCallback onActivate;
  final VoidCallback onMembers;

  /// Voller FuPa-Import jetzt (nur aktives Trainer-Team mit FuPa-Link).
  final VoidCallback onRefreshFupa;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Der Ersteller (created_by) ist Admin und hat immer volle Trainerrechte.
    final isAdmin =
        team['created_by'] != null &&
        team['created_by'] == CloudService.user?.id;
    final isTrainer = team['role'] == 'trainer' || isAdmin;
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: Icon(
              isActive ? Icons.check_circle : Icons.shield_outlined,
              color: isActive ? scheme.primary : null,
            ),
            title: Text((team['name'] as String?) ?? 'Team'),
            subtitle: Text(
              [
                if (isAdmin)
                  'Admin · Code: ${team['invite_code']}'
                else if (isTrainer)
                  'Trainer · Code: ${team['invite_code']}'
                else
                  'Spieler',
                if (isActive) 'aktiv',
              ].join('  ·  '),
            ),
            onTap: isActive ? null : onActivate,
            trailing: isActive
                ? (isTrainer
                      ? OutlinedButton.icon(
                          onPressed: onMembers,
                          icon: const Icon(Icons.manage_accounts, size: 18),
                          label: const Text('Mitglieder'),
                        )
                      : null)
                : FilledButton.tonal(
                    onPressed: onActivate,
                    child: const Text('Aktivieren'),
                  ),
          ),
          // Aktives Trainer-Team: Voll-Import jetzt (fragt bei Bedarf den Link).
          if (isActive && isTrainer)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: onRefreshFupa,
                  icon: const Icon(Icons.cloud_sync, size: 18),
                  label: const Text('Jetzt aus FuPa aktualisieren'),
                ),
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
  const CloudMembersScreen({
    super.key,
    required this.teamId,
    required this.teamName,
  });

  final String teamId;
  final String teamName;

  @override
  State<CloudMembersScreen> createState() => _CloudMembersScreenState();
}

class _CloudMembersScreenState extends State<CloudMembersScreen> {
  late Future<_MembersData> _future = _load();

  Future<_MembersData> _load() async {
    final members = await CloudService.teamMembers(widget.teamId);
    // Kader + Zuordnungen best effort – schlägt fehl, wenn stage28 noch fehlt.
    List<Map<String, dynamic>> roster = const [];
    Map<String, List<String>> links = const {};
    try {
      roster = await CloudService.players(widget.teamId);
    } catch (_) {}
    try {
      links = await CloudService.memberPlayers(widget.teamId);
    } catch (_) {}
    return _MembersData(members, roster, links);
  }

  void _reload() {
    setState(() {
      _future = _load();
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
        content: Text(
          role == 'trainer'
              ? '$label zum Trainer machen? Trainer dürfen alles eintragen und bearbeiten.'
              : '$label auf Spieler zurückstufen? Spieler haben nur Ansicht.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Ändern'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await CloudService.setMemberRole(
        widget.teamId,
        member['user_id'] as String,
        role,
      );
      _reload();
    } catch (e) {
      _snack('Fehler: ${_clean(e)}');
    }
  }

  Future<void> _setTicker(Map<String, dynamic> member, bool value) async {
    try {
      await CloudService.setTicker(
        widget.teamId,
        member['user_id'] as String,
        value,
      );
      _reload();
    } catch (e) {
      _snack('Fehler: ${_clean(e)}');
    }
  }

  String _clean(Object e) => e is PostgrestException ? e.message : e.toString();

  /// Spielerprofile einem Konto zuordnen (ein oder mehrere) – Trainer only.
  Future<void> _assignPlayers(
    Map<String, dynamic> member,
    List<Map<String, dynamic>> roster,
    List<String> current,
  ) async {
    final name = (member['display_name'] as String?)?.trim();
    final mail = (member['email'] as String?)?.trim();
    final label = (name != null && name.isNotEmpty)
        ? name
        : (mail != null && mail.isNotEmpty ? mail : 'Mitglied');
    if (roster.isEmpty) {
      _snack('Kein Kader geladen – bitte zuerst Team/FuPa synchronisieren.');
      return;
    }
    final selected = await showDialog<List<String>>(
      context: context,
      builder: (_) => _AssignPlayersDialog(
        roster: roster,
        initial: current,
        memberName: label,
      ),
    );
    if (selected == null) return;
    try {
      await CloudService.setMemberPlayers(
        widget.teamId,
        member['user_id'] as String,
        selected,
      );
      _reload();
    } catch (e) {
      _snack('Fehler: ${_clean(e)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Mitglieder · ${widget.teamName}')),
      body: FutureBuilder<_MembersData>(
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
          final data = snap.data!;
          final members = data.members;
          if (members.isEmpty) {
            return const Center(
              child: Text(
                'Noch keine Mitglieder.',
                style: TextStyle(color: Colors.grey),
              ),
            );
          }
          return ListView(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(
                  'Trainer dürfen eintragen und bearbeiten. Spieler sehen nur zu. '
                  'Stufe Trainer-Kollegen hier hoch. Ordne jedem Konto ein oder '
                  'mehrere Spielerprofile zu.',
                  style: TextStyle(color: Colors.grey),
                ),
              ),
              for (final m in members)
                _MemberTile(
                  member: m,
                  roster: data.roster,
                  linkedIds: data.links[m['user_id']] ?? const [],
                  onSetRole: (role) => _setRole(m, role),
                  onSetTicker: (v) => _setTicker(m, v),
                  onAssign: () => _assignPlayers(
                    m,
                    data.roster,
                    data.links[m['user_id']] ?? const [],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _MemberTile extends StatelessWidget {
  const _MemberTile({
    required this.member,
    required this.roster,
    required this.linkedIds,
    required this.onSetRole,
    required this.onSetTicker,
    required this.onAssign,
  });

  final Map<String, dynamic> member;
  final List<Map<String, dynamic>> roster;
  final List<String> linkedIds;
  final void Function(String role) onSetRole;
  final void Function(bool value) onSetTicker;
  final VoidCallback onAssign;

  String _playerLabel(Map<String, dynamic> p) {
    final n = p['number'];
    final fn = (p['first_name'] as String?)?.trim() ?? '';
    final ln = (p['last_name'] as String?)?.trim() ?? '';
    final name = [fn, ln].where((s) => s.isNotEmpty).join(' ');
    if (n != null) return name.isEmpty ? '#$n' : '#$n $name';
    return name.isEmpty ? 'Spieler' : name;
  }

  @override
  Widget build(BuildContext context) {
    final name = (member['display_name'] as String?)?.trim();
    final mail = (member['email'] as String?)?.trim();
    final role = member['role'] as String? ?? 'spieler';
    final isMe = member['is_me'] == true;
    final isAdmin = member['is_admin'] == true; // Team-Ersteller
    final isTrainer = role == 'trainer' || isAdmin;
    final canTicker = member['can_ticker'] == true;
    final shown = (name != null && name.isNotEmpty)
        ? name
        : (mail != null && mail.isNotEmpty
              ? mail
              : (isMe ? (CloudService.email ?? 'Unbekannt') : 'Unbekannt'));
    final byId = {for (final p in roster) p['id'] as String: p};
    final linkedNames = [
      for (final id in linkedIds)
        if (byId[id] != null) _playerLabel(byId[id]!),
    ];
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: CircleAvatar(
              child: Icon(
                isAdmin
                    ? Icons.shield
                    : (isTrainer ? Icons.sports : Icons.person),
              ),
            ),
            title: Text(isMe ? '$shown (du)' : shown),
            subtitle: Text(
              isAdmin
                  ? 'Admin · Ersteller'
                  : (isTrainer ? 'Trainer' : 'Spieler'),
            ),
            trailing: isAdmin
                // Der Admin (Ersteller) kann nicht herabgestuft werden.
                ? Chip(label: Text(isMe ? 'Admin (du)' : 'Admin'))
                : isMe
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
          // Trainer/Admin schreiben immer mit. Für Spieler: Ticker-Recht
          // vergeben (sonst nur Zuschauer im Live-Spiel).
          if (!isTrainer && !isAdmin)
            SwitchListTile(
              value: canTicker,
              onChanged: (v) => onSetTicker(v),
              secondary: const Icon(Icons.edit_note),
              dense: true,
              title: const Text('Live-Ticker mitschreiben'),
              subtitle: const Text('Sonst nur Zuschauer (Ticker lesen)'),
            ),
          // Verknüpfte Spielerprofile (Konto ↔ Spieler, Mehrfach möglich).
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
            child: Row(
              children: [
                const Icon(Icons.link, size: 18, color: Colors.grey),
                const SizedBox(width: 8),
                Expanded(
                  child: linkedNames.isEmpty
                      ? const Text(
                          'Kein Spielerprofil verknüpft',
                          style: TextStyle(color: Colors.grey, fontSize: 13),
                        )
                      : Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            for (final n in linkedNames)
                              Chip(
                                label: Text(
                                  n,
                                  style: const TextStyle(fontSize: 12),
                                ),
                                visualDensity: VisualDensity.compact,
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                              ),
                          ],
                        ),
                ),
                TextButton.icon(
                  onPressed: onAssign,
                  icon: const Icon(Icons.edit, size: 16),
                  label: const Text('Zuordnen'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Daten für den Mitglieder-Screen: Mitglieder + Kader + Zuordnungen.
class _MembersData {
  final List<Map<String, dynamic>> members;
  final List<Map<String, dynamic>> roster;
  final Map<String, List<String>> links; // user_id → [player_id]
  const _MembersData(this.members, this.roster, this.links);
}

/// Dialog zum Zuordnen eines oder mehrerer Spielerprofile zu einem Konto.
class _AssignPlayersDialog extends StatefulWidget {
  const _AssignPlayersDialog({
    required this.roster,
    required this.initial,
    required this.memberName,
  });

  final List<Map<String, dynamic>> roster;
  final List<String> initial;
  final String memberName;

  @override
  State<_AssignPlayersDialog> createState() => _AssignPlayersDialogState();
}

class _AssignPlayersDialogState extends State<_AssignPlayersDialog> {
  late final Set<String> _sel = {...widget.initial};
  String _q = '';

  String _label(Map<String, dynamic> p) {
    final n = p['number'];
    final fn = (p['first_name'] as String?)?.trim() ?? '';
    final ln = (p['last_name'] as String?)?.trim() ?? '';
    final name = [fn, ln].where((s) => s.isNotEmpty).join(' ');
    if (n != null) return name.isEmpty ? '#$n' : '#$n  $name';
    return name.isEmpty ? 'Spieler' : name;
  }

  int _num(Map<String, dynamic> p) =>
      (p['number'] is int) ? p['number'] as int : 9999;

  @override
  Widget build(BuildContext context) {
    final roster = [...widget.roster]
      ..sort((a, b) {
        final n = _num(a).compareTo(_num(b));
        return n != 0 ? n : _label(a).compareTo(_label(b));
      });
    final filtered = _q.isEmpty
        ? roster
        : roster.where((p) => _label(p).toLowerCase().contains(_q)).toList();
    return AlertDialog(
      title: Text('Spieler zuordnen · ${widget.memberName}'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              decoration: const InputDecoration(
                hintText: 'Spieler suchen',
                prefixIcon: Icon(Icons.search),
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: filtered.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        'Keine Treffer.',
                        style: TextStyle(color: Colors.grey),
                      ),
                    )
                  : ListView(
                      shrinkWrap: true,
                      children: [
                        for (final p in filtered)
                          CheckboxListTile(
                            dense: true,
                            controlAffinity: ListTileControlAffinity.leading,
                            value: _sel.contains(p['id']),
                            title: Text(_label(p)),
                            onChanged: (v) => setState(() {
                              final id = p['id'] as String;
                              if (v == true) {
                                _sel.add(id);
                              } else {
                                _sel.remove(id);
                              }
                            }),
                          ),
                      ],
                    ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '${_sel.length} ausgewählt',
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (_sel.isNotEmpty)
          TextButton(
            onPressed: () => setState(_sel.clear),
            child: const Text('Keine'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _sel.toList()),
          child: const Text('Speichern'),
        ),
      ],
    );
  }
}
