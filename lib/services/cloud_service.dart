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

  // ---------------------------------------------------------------- Teams
  /// Teams, in denen ich Mitglied bin (inkl. meiner Rolle).
  static Future<List<Map<String, dynamic>>> myTeams() async {
    final rows = await _c
        .from('team_members')
        .select('role, teams(id, name, invite_code, created_by)')
        .eq('user_id', user!.id);
    return [
      for (final r in rows)
        {
          'role': r['role'],
          ...(r['teams'] as Map<String, dynamic>),
        }
    ];
  }

  static Future<Map<String, dynamic>> createTeam(String name) async {
    // Eigene ID vergeben, damit wir NICHT direkt zurücklesen müssen (die
    // Lese-Regel greift erst, wenn man Mitglied ist). Erst Team + Mitglied-
    // schaft anlegen, dann lesen.
    final id = const Uuid().v4();
    await _c.from('teams').insert({
      'id': id,
      'name': name.trim(),
      'created_by': user!.id,
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

  // --------------------------------------------------------------- Spiele
  static Future<List<Map<String, dynamic>>> matches(String teamId) async {
    final rows = await _c
        .from('matches')
        .select()
        .eq('team_id', teamId)
        .order('created_at', ascending: false);
    return List<Map<String, dynamic>>.from(rows);
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
    required String matchId,
    required String teamId,
    required String type,
    int minute = 0,
    String? playerName,
    String? note,
  }) =>
      _c.from('match_events').insert({
        'match_id': matchId,
        'team_id': teamId,
        'type': type,
        'minute': minute,
        'player_name': playerName,
        'note': note,
        'created_by': user!.id,
      });

  static Future<void> deleteEvent(String eventId) =>
      _c.from('match_events').delete().eq('id', eventId);

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

  static Future<void> removeChannel(RealtimeChannel ch) =>
      _c.removeChannel(ch);
}
