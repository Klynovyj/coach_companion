import 'enums.dart';

/// Nominierung/Verfügbarkeit eines Spielers für ein konkretes Spiel.
///
/// „Offen" wird nicht gespeichert (Abwesenheit eines Datensatzes = offen),
/// analog zum Attendance-Modell in Coach Studio.
class Nomination {
  final String id;
  final String matchId;
  final String playerId;
  final NominationStatus status;
  final DateTime updatedAt;

  const Nomination({
    required this.id,
    required this.matchId,
    required this.playerId,
    required this.status,
    required this.updatedAt,
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'match_id': matchId,
        'player_id': playerId,
        'status': status.storageKey,
        'updated_at': updatedAt.toIso8601String(),
      };

  factory Nomination.fromMap(Map<String, Object?> m) => Nomination(
        id: m['id'] as String,
        matchId: m['match_id'] as String,
        playerId: m['player_id'] as String,
        status: NominationStatus.fromKey(m['status'] as String?),
        updatedAt: DateTime.tryParse(m['updated_at'] as String? ?? '') ??
            DateTime.now(),
      );
}
