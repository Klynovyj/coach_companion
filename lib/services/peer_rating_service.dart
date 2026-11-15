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
}
