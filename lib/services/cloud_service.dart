// Mehrbenutzer-Cloud (Supabase): Auth, Teams, Spiele, Ereignisse + Realtime.
// Stufe 1: Trainer schreiben, alle Mitglieder sehen in Echtzeit zu.

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

class CloudService {
  CloudService._();

  /// true, sobald Supabase erfolgreich initialisiert wurde (siehe main.dart).
  static bool ready = false;

  static SupabaseClient get _c => Supabase.instance.client;

  static User? get user => _c.auth.currentUser;
  static bool get signedIn => user != null;
  static Stream<AuthState> get authChanges => _c.auth.onAuthStateChange;

  /// E-Mail des angemeldeten Kontos.
  static String? get email => user?.email;

  /// Anzeigename (aus den Registrierungs-Metadaten), falls hinterlegt.
  static String? get displayName {
    final n = user?.userMetadata?['display_name'];
    return (n is String && n.trim().isNotEmpty) ? n.trim() : null;
  }

  // ----------------------------------------------------------------- Auth
  static Future<void> signIn(String email, String password) =>
      _c.auth.signInWithPassword(email: email.trim(), password: password);

  static Future<void> signUp(
      String email, String password, String displayName) async {
    // Name als Metadaten; profiles-Eintrag macht serverseitig ein Trigger
    // (siehe supabase/schema.sql) – kein direkter Insert (RLS/Session).
    await _c.auth.signUp(
      email: email.trim(),
      password: password,
      data: {'display_name': displayName.trim()},
    );
  }

  static Future<void> signOut() => _c.auth.signOut();

  /// Setzt den Anzeigenamen des angemeldeten Kontos – in der profiles-Tabelle
  /// (für die Mitgliederliste sichtbar) und in den Auth-Metadaten (Kopfzeile).
  static Future<void> setDisplayName(String name) async {
    final n = name.trim();
    await _c.from('profiles').update({'display_name': n}).eq('id', user!.id);
    await _c.auth.updateUser(UserAttributes(data: {'display_name': n}));
  }

  // ---------------------------------------------------------------- Teams
  /// Teams, in denen ich Mitglied bin (inkl. meiner Rolle).
  static Future<List<Map<String, dynamic>>> myTeams() async {
    final rows = await _c
        .from('team_members')
        .select('role, teams(id, name, invite_code, created_by, fupa_url, logo)')
        .eq('user_id', user!.id);
    return [
      for (final r in rows)
        {
          'role': r['role'],
          ...(r['teams'] as Map<String, dynamic>),
        }
    ];
  }

  static Future<Map<String, dynamic>> createTeam(String name,
      {String? fupaUrl}) async {
    // Eigene ID vergeben, damit wir NICHT direkt zurücklesen müssen (die
    // Lese-Regel greift erst, wenn man Mitglied ist). Erst Team + Mitglied-
    // schaft anlegen, dann lesen.
    final id = const Uuid().v4();
    await _c.from('teams').insert({
      'id': id,
      'name': name.trim(),
      'created_by': user!.id,
      if (fupaUrl != null && fupaUrl.isNotEmpty) 'fupa_url': fupaUrl,
    });
    await _c.from('team_members').insert({
      'team_id': id,
      'user_id': user!.id,
      'role': 'trainer',
    });
    return await _c.from('teams').select().eq('id', id).single();
  }

  /// Team per Einladungscode beitreten (als Spieler).
  static Future<void> joinTeam(String code) =>
      _c.rpc('join_team', params: {'code': code.trim()});

  /// Team-Felder aktualisieren (z.B. name, logo).
  static Future<void> updateTeam(String teamId, Map<String, dynamic> fields) =>
      _c.from('teams').update(fields).eq('id', teamId);

  /// Ersetzt die Cloud-Statistik eines Teams (delete + insert, ein Stand).
  static Future<void> uploadStats(
      String teamId, List<Map<String, dynamic>> rows) async {
    await _c.from('player_stats').delete().eq('team_id', teamId);
    if (rows.isEmpty) return;
    await _c.from('player_stats').insert([
      for (final r in rows) {'team_id': teamId, ...r}
    ]);
  }

  /// Mitglieder eines Teams mit Namen + Rolle (über SECURITY-DEFINER-Funktion,
  /// damit auch fremde Profilnamen sichtbar sind).
  static Future<List<Map<String, dynamic>>> teamMembers(String teamId) async {
    final rows = await _c.rpc('list_team_members', params: {'t': teamId});
    return List<Map<String, dynamic>>.from(rows as List);
  }

  /// Rolle eines Mitglieds ändern (nur Trainer; letzter Trainer bleibt).
  static Future<void> setMemberRole(
          String teamId, String userId, String role) =>
      _c.rpc('set_member_role',
          params: {'t': teamId, 'target': userId, 'new_role': role});

  // ---------------------------------------------------------------- Kader
  static Future<List<Map<String, dynamic>>> players(String teamId) async {
    final rows = await _c
        .from('players')
        .select()
        .eq('team_id', teamId)
        .order('number', ascending: true)
        .order('last_name', ascending: true);
    return List<Map<String, dynamic>>.from(rows);
  }

  /// Ersetzt den Cloud-Kader eines Teams durch die übergebenen Spieler.
  /// [roster] = Liste von {first_name,last_name,number,position}.
  static Future<void> uploadRoster(
      String teamId, List<Map<String, dynamic>> roster) async {
    await _c.from('players').delete().eq('team_id', teamId);
    if (roster.isEmpty) return;
    final rows = [
      for (final p in roster) {'team_id': teamId, ...p}
    ];
    await _c.from('players').insert(rows);
  }

  // --------------------------------------------------------------- Spiele
  static Future<List<Map<String, dynamic>>> matches(String teamId) async {
    final rows = await _c
        .from('matches')
        .select()
        .eq('team_id', teamId)
        .order('created_at', ascending: false);
    return List<Map<String, dynamic>>.from(rows);
  }

  /// Lädt den Spielplan in die Cloud – nur Spiele, die noch nicht da sind
  /// (dedupliziert über Gegner + Anstoß), damit getrackte Spiele nicht
  /// verloren gehen. Gibt die Anzahl NEU hinzugefügter Spiele zurück.
  static Future<int> uploadSchedule(
      String teamId, List<Map<String, dynamic>> matches) async {
    final existing =
        await _c.from('matches').select('opponent, kickoff').eq('team_id', teamId);
    final seen = <String>{
      for (final e in existing) '${e['opponent']}|${e['kickoff']}'
    };
    final toInsert = [
      for (final m in matches)
        if (!seen.contains('${m['opponent']}|${m['kickoff']}'))
          {'team_id': teamId, ...m}
    ];
    if (toInsert.isNotEmpty) {
      await _c.from('matches').insert(toInsert);
    }
    return toInsert.length;
  }

  /// Spiele id-stabil in die Cloud spiegeln (Insert oder Update per id) –
  /// aktualisiert bestehende Spiele (Ergebnis/Status) ohne sie zu löschen.
  static Future<void> upsertMatches(List<Map<String, dynamic>> rows) {
    if (rows.isEmpty) return Future.value();
    return _c.from('matches').upsert(rows, onConflict: 'id');
  }

  static Future<Map<String, dynamic>> createMatch(
      String teamId, String opponent) async {
    return await _c
        .from('matches')
        .insert({
          'team_id': teamId,
          'opponent': opponent.trim(),
          'kickoff': DateTime.now().toUtc().toIso8601String(),
          'status': 'live',
          'created_by': user!.id,
        })
        .select()
        .single();
  }

  static Future<void> setScore(String matchId, int own, int opp) =>
      _c.from('matches').update(
          {'own_score': own, 'opponent_score': opp}).eq('id', matchId);

  /// Setzt Status + Spielstand (z.B. beim Zurücksetzen auf „scheduled", 0:0).
  static Future<void> setMatchState(
          String matchId, String status, int own, int opp) =>
      _c.from('matches').update({
        'status': status,
        'own_score': own,
        'opponent_score': opp,
      }).eq('id', matchId);

  /// Beliebige Spiel-Felder aktualisieren (z.B. locally_managed beim Reset).
  static Future<void> updateMatch(String matchId, Map<String, dynamic> fields) =>
      _c.from('matches').update(fields).eq('id', matchId);

  // ----------------------------------------------------- Generische Bereiche
  // Für die „eigene Tabelle pro Bereich"-Spiegelung (Nominierung, Aufstellung,
  // Karten, Notizen, Bewertungen, Aufgaben, Gespräche, Abwesenheiten …). Der
  // lokale Cache ist Abbild genau eines Teams; team_id scoped die Cloud-Zeile.

  /// Spiegelt eine Zeile in die Cloud (Insert oder Update). [onConflict] gibt
  /// bei Bedarf die Konflikt-Spalten an (z.B. 'match_id,player_id').
  static Future<void> upsertRow(String table, Map<String, dynamic> row,
          {String? onConflict}) =>
      _c.from(table).upsert(row, onConflict: onConflict);

  /// Löscht Cloud-Zeilen anhand eines Spalten-Filters (z.B. {id: …} oder
  /// {match_id: …, player_id: …}).
  static Future<void> deleteWhere(
      String table, Map<String, dynamic> filter) async {
    var q = _c.from(table).delete();
    for (final e in filter.entries) {
      q = q.eq(e.key, e.value as Object);
    }
    await q;
  }

  /// Alle Zeilen einer Bereichstabelle eines Teams.
  static Future<List<Map<String, dynamic>>> fetchForTeam(
      String table, String teamId) async {
    final rows = await _c.from(table).select().eq('team_id', teamId);
    return List<Map<String, dynamic>>.from(rows);
  }

  // ------------------------------------------------------------ Ereignisse
  static Future<List<Map<String, dynamic>>> events(String matchId) async {
    final rows = await _c
        .from('match_events')
        .select()
        .eq('match_id', matchId)
        .order('created_at');
    return List<Map<String, dynamic>>.from(rows);
  }

  static Future<void> addEvent({
    String? id,
    required String matchId,
    required String teamId,
    required String type,
    int minute = 0,
    int minuteExtra = 0,
    String? playerId,
    String? assistPlayerId,
    String? playerName,
    String? note,
    bool isOpponent = false,
  }) =>
      // Upsert per id: gespiegelte Ereignisse behalten ihre lokale ID (damit
      // Erwähnungen sie referenzieren können); ohne id vergibt die DB eine.
      _c.from('match_events').upsert({
        'id': ?id,
        'match_id': matchId,
        'team_id': teamId,
        'type': type,
        'minute': minute,
        'minute_extra': minuteExtra,
        'player_id': playerId,
        'assist_player_id': assistPlayerId,
        'player_name': playerName,
        'note': note,
        'is_opponent': isOpponent,
        'created_by': user!.id,
      }, onConflict: 'id');

  static Future<void> deleteEvent(String eventId) =>
      _c.from('match_events').delete().eq('id', eventId);

  /// Alle Ereignisse eines Spiels in der Cloud löschen (z.B. „Spiel zurück-
  /// setzen").
  static Future<void> deleteEventsForMatch(String matchId) =>
      _c.from('match_events').delete().eq('match_id', matchId);

  /// Realtime-Abo für die Ereignisse eines Spiels. [onChange] wird bei jeder
  /// Änderung (insert/update/delete) aufgerufen.
  static RealtimeChannel subscribeEvents(
      String matchId, void Function() onChange) {
    final ch = _c.channel('events_$matchId');
    ch
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'match_events',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'match_id',
            value: matchId,
          ),
          callback: (_) => onChange(),
        )
        .subscribe();
    return ch;
  }

  /// Realtime-Abo für ein ganzes Team: Spiele + Kader. [onChange] wird bei
  /// jeder Änderung an matches/players dieses Teams aufgerufen (z.B. wenn ein
  /// Trainer-Kollege auf einem anderen Gerät ein Spiel oder den Spielstand
  /// ändert). So bleibt der lokale Cache überall aktuell.
  /// Alle team-scoped Tabellen, die per Realtime beobachtet und gespiegelt
  /// werden (gemeinsam genutzte Bereiche).
  static const teamTables = <String>[
    'matches',
    'players',
    'match_events',
    'event_mentions',
    'lineups',
    'lineup_entries',
    'match_nominations',
    'card_entries',
    'player_notes',
    'note_categories',
    'player_ratings',
    'todos',
    'todo_topics',
    'player_talks',
    'player_absences',
    'player_stats',
  ];

  static RealtimeChannel subscribeTeam(
      String teamId, void Function() onChange) {
    final ch = _c.channel('team_$teamId');
    for (final table in teamTables) {
      ch.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: table,
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'team_id',
          value: teamId,
        ),
        callback: (_) => onChange(),
      );
    }
    ch.subscribe();
    return ch;
  }

  static Future<void> removeChannel(RealtimeChannel ch) =>
      _c.removeChannel(ch);
}
