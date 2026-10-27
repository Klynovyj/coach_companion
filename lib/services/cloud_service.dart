// Mehrbenutzer-Cloud (Supabase): Auth, Teams, Spiele, Ereignisse + Realtime.
// Stufe 1: Trainer schreiben, alle Mitglieder sehen in Echtzeit zu.

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

class CloudService {
  CloudService._();

  /// true, sobald Supabase erfolgreich initialisiert wurde (siehe main.dart).
  static bool ready = false;

  static SupabaseClient get _c => Supabase.instance.client;

  // Vor der Supabase-Initialisierung (z.B. in Tests) gibt es keinen Client –
  // dann einfach „nicht angemeldet", statt auf den Client zuzugreifen.
  static User? get user => ready ? _c.auth.currentUser : null;
  static bool get signedIn => user != null;
  static Stream<AuthState> get authChanges => _c.auth.onAuthStateChange;

  /// E-Mail des angemeldeten Kontos.
  static String? get email => user?.email;

  /// Eigene User-ID (für Live-Steuerung u.a.).
  static String? get userId => user?.id;

  /// Anzeigename des angemeldeten Nutzers (Name, sonst E-Mail).
  static String? get myName {
    final meta = user?.userMetadata;
    final n = (meta != null ? meta['display_name'] : null) as String?;
    if (n != null && n.trim().isNotEmpty) return n.trim();
    return email;
  }

  /// Anzeigename (aus den Registrierungs-Metadaten), falls hinterlegt.
  static String? get displayName {
    final n = user?.userMetadata?['display_name'];
    return (n is String && n.trim().isNotEmpty) ? n.trim() : null;
  }

  // ----------------------------------------------------------------- Auth
  static Future<void> signIn(String email, String password) =>
      _c.auth.signInWithPassword(email: email.trim(), password: password);

  static Future<void> signUp(
    String email,
    String password,
    String displayName,
  ) async {
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
        .select(
          'role, can_ticker, teams(id, name, short_name, invite_code, created_by, fupa_url, logo, material_duty)',
        )
        .eq('user_id', user!.id);
    return [
      for (final r in rows)
        {
          'role': r['role'],
          'can_ticker': r['can_ticker'],
          ...(r['teams'] as Map<String, dynamic>),
        },
    ];
  }

  static Future<Map<String, dynamic>> createTeam(
    String name, {
    String? fupaUrl,
  }) async {
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

  /// Die komplette Team-Zeile laden (Name/Kurzname/Logo/Materialdienst …).
  static Future<Map<String, dynamic>> teamById(String teamId) =>
      _c.from('teams').select().eq('id', teamId).single();

  /// FCM-Token dieses Geräts/Nutzers hinterlegen (für Push).
  static Future<void> upsertDeviceToken(String token) =>
      _c.from('device_tokens').upsert({
        'token': token,
        'user_id': user!.id,
        'platform': 'android',
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'token');

  /// Push an alle Team-Mitglieder (außer dem Auslöser) auslösen, wenn ein Spiel
  /// live geht (Edge-Function „notify-live"). Fehler werden geschluckt.
  static Future<void> notifyLive(
    String teamId,
    String matchId,
    String opponent,
  ) async {
    try {
      await _c.functions.invoke(
        'notify-live',
        body: {'team_id': teamId, 'match_id': matchId, 'opponent': opponent},
      );
    } catch (_) {}
  }

  /// Push an bestimmte Empfänger (Posteingang-Eintrag), via Edge-Function
  /// „notify-inbox". Fehler werden geschluckt (In-App-Posteingang reicht auch
  /// ohne Push). Die Function muss deployt sein, sonst passiert nichts.
  static Future<void> notifyInbox(
    List<String> recipientIds,
    String title,
    String body,
  ) async {
    if (recipientIds.isEmpty) return;
    try {
      await _c.functions.invoke(
        'notify-inbox',
        body: {'recipient_ids': recipientIds, 'title': title, 'body': body},
      );
    } catch (_) {}
  }

  /// Leichter Abgleich von Status + Ergebnis aller Spiele (für den Live-/
  /// Zurücksetzen-Poll – ohne Logos/Details).
  static Future<List<Map<String, dynamic>>> matchSyncRows(String teamId) async {
    final rows = await _c
        .from('matches')
        .select(
          'id, status, own_score, opponent_score, opponent, '
          'live_controller, live_controller_name',
        )
        .eq('team_id', teamId);
    return List<Map<String, dynamic>>.from(rows);
  }

  /// Ersetzt die Cloud-Statistik eines Teams (delete + insert, ein Stand).
  static Future<void> uploadStats(
    String teamId,
    List<Map<String, dynamic>> rows,
  ) async {
    await _c.from('player_stats').delete().eq('team_id', teamId);
    if (rows.isEmpty) return;
    await _c.from('player_stats').insert([
      for (final r in rows) {'team_id': teamId, ...r},
    ]);
  }

  /// Gegner-Team (Meta) spiegeln – Owner = eigenes Cloud-Team.
  static Future<void> uploadOpponentTeam(
    String ownerTeamId,
    Map<String, dynamic> row,
  ) => _c.from('opponent_teams').upsert({'team_id': ownerTeamId, ...row});

  /// Gegner-Kader ersetzen (delete + insert für diesen Gegner).
  static Future<void> uploadOpponentPlayers(
    String ownerTeamId,
    String opponentTeamId,
    List<Map<String, dynamic>> rows,
  ) async {
    await _c
        .from('opponent_players')
        .delete()
        .eq('opponent_team_id', opponentTeamId);
    if (rows.isEmpty) return;
    await _c.from('opponent_players').insert([
      for (final r in rows)
        {'team_id': ownerTeamId, 'opponent_team_id': opponentTeamId, ...r},
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
    String teamId,
    String userId,
    String role,
  ) => _c.rpc(
    'set_member_role',
    params: {'t': teamId, 'target': userId, 'new_role': role},
  );

  /// Ticker-Recht eines Mitglieds setzen (nur Trainer; Live-Mitschreiben).
  static Future<void> setTicker(String teamId, String userId, bool value) =>
      _c.rpc(
        'set_ticker',
        params: {'t': teamId, 'target': userId, 'value': value},
      );

  // ----------------------------------------------- Konto ↔ Spieler (n:m)
  // Ein Konto kann mit einem oder mehreren Spielerprofilen verknüpft sein
  // (member_players, siehe stage28). Grundlage für „eigene Gespräche" und die
  // Sichtbarkeits-Regeln.

  /// Alle Zuordnungen eines Teams: user_id → Liste der verknüpften player_id.
  static Future<Map<String, List<String>>> memberPlayers(String teamId) async {
    final rows = await _c
        .from('member_players')
        .select('user_id, player_id')
        .eq('team_id', teamId);
    final map = <String, List<String>>{};
    for (final r in rows) {
      (map[r['user_id'] as String] ??= []).add(r['player_id'] as String);
    }
    return map;
  }

  /// Ersetzt die Spieler-Zuordnung eines Mitglieds (löschen + neu setzen).
  static Future<void> setMemberPlayers(
    String teamId,
    String userId,
    List<String> playerIds,
  ) async {
    await _c
        .from('member_players')
        .delete()
        .eq('team_id', teamId)
        .eq('user_id', userId);
    if (playerIds.isEmpty) return;
    await _c.from('member_players').insert([
      for (final pid in playerIds)
        {'team_id': teamId, 'user_id': userId, 'player_id': pid},
    ]);
  }

  /// Die mit dem EIGENEN Konto verknüpften Spieler-IDs in diesem Team.
  static Future<List<String>> myPlayerIds(String teamId) async {
    final uid = user?.id;
    if (uid == null) return const [];
    final rows = await _c
        .from('member_players')
        .select('player_id')
        .eq('team_id', teamId)
        .eq('user_id', uid);
    return [for (final r in rows) r['player_id'] as String];
  }

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

  /// Spiegelt den Kader eines Teams per Upsert (nach id) – OHNE vorheriges
  /// Löschen, damit der Kader nie kurz „leer" ist (sonst flackert/verfälscht es
  /// bei anderen Geräten über Realtime).
  static Future<void> uploadRoster(
    String teamId,
    List<Map<String, dynamic>> roster,
  ) async {
    if (roster.isEmpty) return;
    final rows = [
      for (final p in roster) {'team_id': teamId, ...p},
    ];
    await _upsertStrippingUnknown('players', rows, onConflict: 'id');
  }

  /// Upsert, das gegen in der Cloud (noch) fehlende Spalten robust ist: scheitert
  /// der Upsert an einer unbekannten Spalte (z.B. eine noch nicht ausgeführte
  /// Migration), wird DIESE Spalte aus allen Zeilen entfernt und erneut
  /// versucht. So gehen die übrigen Felder (u.a. `status`/`active`) NICHT
  /// verloren – sonst würde ein einziges fehlendes Feld den ganzen Push
  /// verwerfen und z.B. „inaktiv" nie in die Cloud gelangen.
  static Future<void> _upsertStrippingUnknown(
    String table,
    List<Map<String, dynamic>> rows, {
    String? onConflict,
  }) async {
    var current = rows;
    for (var attempt = 0; attempt < 12; attempt++) {
      try {
        await _c.from(table).upsert(current, onConflict: onConflict);
        return;
      } on PostgrestException catch (e) {
        final col = _unknownColumnFrom(e, current);
        if (col == null) rethrow;
        current = [
          for (final r in current) {...r}..remove(col),
        ];
      }
    }
  }

  /// Ermittelt aus einem PostgREST-Fehler die unbekannte Spalte (PGRST204 bzw.
  /// „column \"x\" ... does not exist"), falls sie zu den gesendeten Feldern
  /// gehört. `id`/`team_id` werden nie entfernt.
  static String? _unknownColumnFrom(
    PostgrestException e,
    List<Map<String, dynamic>> rows,
  ) {
    if (rows.isEmpty) return null;
    final msg = e.message.toLowerCase();
    for (final key in rows.first.keys) {
      if (key == 'id' || key == 'team_id') continue;
      if (msg.contains("'$key'") || msg.contains('"$key"')) return key;
    }
    return null;
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
    String teamId,
    List<Map<String, dynamic>> matches,
  ) async {
    final existing = await _c
        .from('matches')
        .select('opponent, kickoff')
        .eq('team_id', teamId);
    final seen = <String>{
      for (final e in existing) '${e['opponent']}|${e['kickoff']}',
    };
    final toInsert = [
      for (final m in matches)
        if (!seen.contains('${m['opponent']}|${m['kickoff']}'))
          {'team_id': teamId, ...m},
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
    String teamId,
    String opponent,
  ) async {
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

  static Future<void> setScore(String matchId, int own, int opp) => _c
      .from('matches')
      .update({'own_score': own, 'opponent_score': opp})
      .eq('id', matchId);

  /// Setzt Status + Spielstand (z.B. beim Zurücksetzen auf „scheduled", 0:0).
  static Future<void> setMatchState(
    String matchId,
    String status,
    int own,
    int opp,
  ) => _c
      .from('matches')
      .update({'status': status, 'own_score': own, 'opponent_score': opp})
      .eq('id', matchId);

  /// Beliebige Spiel-Felder aktualisieren (z.B. locally_managed beim Reset).
  static Future<void> updateMatch(
    String matchId,
    Map<String, dynamic> fields,
  ) => _c.from('matches').update(fields).eq('id', matchId);

  // ----------------------------------------------------- Generische Bereiche
  // Für die „eigene Tabelle pro Bereich"-Spiegelung (Nominierung, Aufstellung,
  // Karten, Notizen, Bewertungen, Aufgaben, Gespräche, Abwesenheiten …). Der
  // lokale Cache ist Abbild genau eines Teams; team_id scoped die Cloud-Zeile.

  /// Spiegelt eine Zeile in die Cloud (Insert oder Update). [onConflict] gibt
  /// bei Bedarf die Konflikt-Spalten an (z.B. 'match_id,player_id').
  ///
  /// Robust gegen eine noch nicht angelegte `updated_at`-Spalte (Cloud-Stufe 32
  /// noch nicht ausgeführt): in dem Fall wird die Zeile ohne dieses Feld erneut
  /// gesendet, damit Noten/Berichte weiterhin synchronisieren.
  static Future<void> upsertRow(
    String table,
    Map<String, dynamic> row, {
    String? onConflict,
  }) async {
    try {
      await _c.from(table).upsert(row, onConflict: onConflict);
    } on PostgrestException catch (e) {
      final msg = e.message.toLowerCase();
      if (row.containsKey('updated_at') && msg.contains('updated_at')) {
        final fallback = Map<String, dynamic>.from(row)..remove('updated_at');
        await _c.from(table).upsert(fallback, onConflict: onConflict);
      } else {
        rethrow;
      }
    }
  }

  /// Löscht Cloud-Zeilen anhand eines Spalten-Filters (z.B. {id: …} oder
  /// {match_id: …, player_id: …}).
  static Future<void> deleteWhere(
    String table,
    Map<String, dynamic> filter,
  ) async {
    var q = _c.from(table).delete();
    for (final e in filter.entries) {
      q = q.eq(e.key, e.value as Object);
    }
    await q;
  }

  /// Alle Zeilen einer Bereichstabelle eines Teams.
  static Future<List<Map<String, dynamic>>> fetchForTeam(
    String table,
    String teamId,
  ) async {
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
    String? createdAt,
  }) =>
      // Upsert per id: gespiegelte Ereignisse behalten ihre lokale ID (damit
      // Erwähnungen sie referenzieren können); ohne id vergibt die DB eine.
      // created_at wird – wenn übergeben – mit dem lokalen Zeitstempel gesetzt,
      // damit Phasen-Marken auf allen Geräten denselben Uhr-Anker haben.
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
        'created_at': ?createdAt,
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
    String matchId,
    void Function() onChange,
  ) {
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
    'sponsors',
    'graphic_settings',
    'match_ratings',
    'player_of_month',
    'player_stats',
    'activities',
    'opponent_teams',
    'opponent_players',
  ];

  /// Realtime pro Tabelle EIN eigener Kanal. [onChange] liefert die konkrete
  /// geänderte Zeile (Tabelle, Event-Typ insert/update/delete, Datensatz),
  /// damit der Empfänger GEZIELT nur diese Zeile anwendet (sofortige Updates).
  static List<RealtimeChannel> subscribeTeam(
    String teamId,
    void Function(String table, String eventType, Map<String, dynamic> record)
    onChange,
  ) {
    final channels = <RealtimeChannel>[];
    for (final table in teamTables) {
      final ch = _c.channel('team_${teamId}_$table');
      ch
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: table,
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'team_id',
              value: teamId,
            ),
            callback: (payload) {
              final isDelete = payload.eventType == PostgresChangeEvent.delete;
              final rec = isDelete ? payload.oldRecord : payload.newRecord;
              onChange(
                table,
                payload.eventType.name,
                Map<String, dynamic>.from(rec),
              );
            },
          )
          .subscribe();
      channels.add(ch);
    }
    // Die Team-Zeile selbst (Name/Kurzname/Logo/Materialdienst) – gefiltert per
    // id, da teams keine team_id-Spalte hat.
    final teamCh = _c.channel('team_${teamId}_self');
    teamCh
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'teams',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'id',
            value: teamId,
          ),
          callback: (payload) {
            final isDelete = payload.eventType == PostgresChangeEvent.delete;
            final rec = isDelete ? payload.oldRecord : payload.newRecord;
            onChange(
              'teams',
              payload.eventType.name,
              Map<String, dynamic>.from(rec),
            );
          },
        )
        .subscribe();
    channels.add(teamCh);
    // Persönlicher Posteingang: nur MEINE Zeilen abonnieren (recipient_id), damit
    // keine fremden Einträge über Realtime hereinkommen.
    final myId = user?.id;
    if (myId != null) {
      final inboxCh = _c.channel('team_${teamId}_inbox_$myId');
      inboxCh
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'inbox',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'recipient_id',
              value: myId,
            ),
            callback: (payload) {
              final isDelete = payload.eventType == PostgresChangeEvent.delete;
              final rec = isDelete ? payload.oldRecord : payload.newRecord;
              onChange(
                'inbox',
                payload.eventType.name,
                Map<String, dynamic>.from(rec),
              );
            },
          )
          .subscribe();
      channels.add(inboxCh);
    }
    return channels;
  }

  static Future<void> removeChannel(RealtimeChannel ch) => _c.removeChannel(ch);

  static Future<void> removeChannels(List<RealtimeChannel> chs) async {
    for (final ch in chs) {
      await _c.removeChannel(ch);
    }
  }
}
