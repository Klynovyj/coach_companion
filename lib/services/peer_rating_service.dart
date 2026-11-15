import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/peer_rating.dart';
import 'cloud_service.dart';

/// Cloud-Zugriffe für die Spieler-Bewertung per Web-Link (Stufe 59).
/// Alles nur online und nur mit angemeldetem Konto; Fehler (z. B. fehlende
/// Cloud-Stufe) werden als `null`/leer gemeldet statt zu werfen.
class PeerRatingService {
  PeerRatingService._();

  static SupabaseClient get _c => Supabase.instance.client;

  static bool get available => CloudService.ready && CloudService.signedIn;

  /// Bewertungsrunde eines Spiels anlegen/aktualisieren (nur Trainer).
  static Future<bool> publishRound({
    required String matchId,
    required String teamId,
    required String title,
    DateTime? matchDate,
    required DateTime closesAt,
    required List<PeerRoundPlayer> players,
  }) async {
    if (!available) return false;
    try {
      await _c.from('peer_rating_rounds').upsert({
        'match_id': matchId,
        'team_id': teamId,
        'title': title,
        'match_date': matchDate?.toUtc().toIso8601String(),
        'closes_at': closesAt.toUtc().toIso8601String(),
        'players': [for (final p in players) p.toJson()],
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Auswertung eines Spiels; `null` = keine Runde oder Cloud-Stufe fehlt.
  static Future<PeerSummary?> summary(String matchId) async {
    if (!available) return null;
    try {
      final res = await _c.rpc(
        'peer_rating_summary',
        params: {'p_match_id': matchId},
      );
      if (res is Map) {
        return PeerSummary.fromJson(Map<String, dynamic>.from(res));
      }
    } catch (_) {}
    return null;
  }

  /// Persönliche Links des Teams: Spieler-ID → Token. `null` = nicht lesbar
  /// (Cloud-Stufe 59 fehlt oder offline).
  static Future<Map<String, String>?> links(String teamId) async {
    if (!available) return null;
    try {
      final rows = await _c
          .from('peer_rating_links')
          .select('player_id, token')
          .eq('team_id', teamId);
      return {
        for (final r in rows) r['player_id'].toString(): r['token'].toString(),
      };
    } catch (_) {
      return null;
    }
  }

  /// Link anlegen oder neu erzeugen (alter Link wird ungültig). Gibt den
  /// neuen Token zurück oder `null` bei Fehler.
  static Future<String?> createLink(String playerId, String teamId) async {
    if (!available) return null;
    final token = newPeerToken();
    try {
      await _c.from('peer_rating_links').upsert({
        'player_id': playerId,
        'team_id': teamId,
        'token': token,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
      return token;
    } catch (_) {
      return null;
    }
  }

  /// Verlauf der Selbsteinschätzung eines Spielers (neueste zuerst).
  static Future<List<PeerSelfEntry>?> selfRatings(String playerId) async {
    if (!available) return null;
    try {
      final res = await _c.rpc(
        'peer_self_ratings',
        params: {'p_player_id': playerId},
      );
      if (res is List) {
        return [
          for (final e in res)
            if (e is Map) PeerSelfEntry.fromJson(Map<String, dynamic>.from(e)),
        ];
      }
    } catch (_) {}
    return null;
  }

  // ---------------------------------------------------------- Trainer-Links
  /// Trainer-Links des Teams: Bewerter-ID → Token. `null` = nicht lesbar
  /// (Cloud-Stufe 60 fehlt oder offline).
  static Future<Map<String, String>?> coachLinks(String teamId) async {
    if (!available) return null;
    try {
      final rows = await _c
          .from('coach_rating_links')
          .select('rater_id, token')
          .eq('team_id', teamId);
      return {
        for (final r in rows) r['rater_id'].toString(): r['token'].toString(),
      };
    } catch (_) {
      return null;
    }
  }

  /// Trainer-Link anlegen oder neu erzeugen. [raterId] = User-ID (App) oder
  /// `staff:<playerId>`; [name] erscheint auf der Seite und bei Berichten.
  static Future<String?> createCoachLink(
    String raterId,
    String teamId,
    String name, {
    String? playerId,
    String? photo,
  }) async {
    if (!available) return null;
    final token = newPeerToken();
    try {
      await _c.from('coach_rating_links').upsert({
        'rater_id': raterId,
        'team_id': teamId,
        'token': token,
        'name': name,
        'player_id': ?playerId,
        'photo': ?photo,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
      return token;
    } catch (_) {
      return null;
    }
  }

  /// Fotos an bestehenden Trainer-Links aktualisieren (Bewerter-ID → kleine
  /// Data-URL). Reine Trainer haben keine Spieler-Zeile in der Cloud.
  static Future<void> updateCoachPhotos(
    String teamId,
    Map<String, String> photos,
  ) async {
    if (!available || photos.isEmpty) return;
    for (final e in photos.entries) {
      try {
        await _c
            .from('coach_rating_links')
            .update({'photo': e.value})
            .eq('team_id', teamId)
            .eq('rater_id', e.key);
      } catch (_) {}
    }
  }

  /// Namen der Trainer-Links: Bewerter-ID → Name. Reine Trainer haben je Gerät
  /// eine eigene lokale ID – über den Namen wird ein vorhandener Link erkannt.
  static Future<Map<String, String>> coachLinkNames(String teamId) async {
    if (!available) return const {};
    try {
      final rows = await _c
          .from('coach_rating_links')
          .select('rater_id, name')
          .eq('team_id', teamId);
      return {
        for (final r in rows)
          r['rater_id'].toString(): (r['name'] ?? '').toString(),
      };
    } catch (_) {
      return const {};
    }
  }

  /// Kader-Person je Trainer-Link: Bewerter-ID → Spieler-ID (player_id oder
  /// 'staff:<id>'); `null` = nicht lesbar.
  static Future<Map<String, String>?> coachLinkPlayers(String teamId) async {
    if (!available) return null;
    try {
      final rows = await _c
          .from('coach_rating_links')
          .select('rater_id, player_id')
          .eq('team_id', teamId);
      final out = <String, String>{};
      for (final r in rows) {
        final rid = r['rater_id'].toString();
        final pid =
            r['player_id']?.toString() ??
            (rid.startsWith('staff:') ? rid.substring(6) : null);
        if (pid != null) out[rid] = pid;
      }
      return out;
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------- Übersicht (Stufe 66)
  /// Abstimm-Übersicht aller Spiele mit Runde (nur Trainer); `null` = nicht
  /// verfügbar (offline, Cloud-Stufe 66 fehlt).
  static Future<Map<String, PeerOverview>?> overview(String teamId) async {
    if (!available) return null;
    try {
      final res = await _c.rpc('rating_overview', params: {'p_team': teamId});
      if (res is List) {
        return {
          for (final e in res)
            if (e is Map)
              e['match_id'].toString(): PeerOverview.fromJson(
                Map<String, dynamic>.from(e),
              ),
        };
      }
    } catch (_) {}
    return null;
  }

  /// Einzelne Trainer-Stimmen eines Spiels (nur Trainer); `null` = nicht
  /// verfügbar.
  static Future<List<CoachVote>?> coachVotes(String matchId) async {
    if (!available) return null;
    try {
      final res = await _c.rpc(
        'rating_coach_votes',
        params: {'p_match_id': matchId},
      );
      if (res is List) {
        return [
          for (final e in res)
            if (e is Map) CoachVote.fromJson(Map<String, dynamic>.from(e)),
        ];
      }
    } catch (_) {}
    return null;
  }

  // ---------------------------------------- Spieler des Monats (Stufe 68)
  /// Stand der Kürung eines Monats; `null` = nicht verfügbar.
  static Future<CrownState?> crownState(String teamId, String yearMonth) async {
    if (!available) return null;
    try {
      final res = await _c.rpc(
        'app_crown_state',
        params: {'p_team': teamId, 'p_year_month': yearMonth},
      );
      if (res is Map && res['ok'] == true) {
        return CrownState.fromJson(Map<String, dynamic>.from(res));
      }
    } catch (_) {}
    return null;
  }

  /// Eigene Zustimmung setzen ([playerId] null = zurücknehmen). Gekürt wird
  /// serverseitig erst, wenn alle Trainer denselben Spieler bestätigen.
  static Future<CrownState?> crownVote(
    String teamId,
    String yearMonth,
    String? playerId,
  ) async {
    if (!available) return null;
    try {
      final res = await _c.rpc(
        'app_crown_vote',
        params: {
          'p_team': teamId,
          'p_year_month': yearMonth,
          'p_player_id': playerId,
        },
      );
      if (res is Map && res['ok'] == true) {
        return CrownState.fromJson({
          'me': CloudService.userId,
          'state': res['state'],
        });
      }
    } catch (_) {}
    return null;
  }

  /// Live-Änderungen der Zustimmungen eines Teams (Realtime).
  static RealtimeChannel? subscribeCrown(String teamId, VoidCallback onChange) {
    if (!available) return null;
    final ch = _c.channel('crown_$teamId');
    ch
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'month_crown_votes',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'team_id',
            value: teamId,
          ),
          callback: (_) => onChange(),
        )
        .subscribe();
    return ch;
  }

  static Future<void> unsubscribe(RealtimeChannel? ch) async {
    if (ch == null) return;
    try {
      await _c.removeChannel(ch);
    } catch (_) {}
  }
}
