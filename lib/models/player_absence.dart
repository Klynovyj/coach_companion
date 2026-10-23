import 'enums.dart';

/// Ein Abwesenheits-Eintrag („Antrag") eines Spielers: Status + Zeitraum
/// (von–bis) + optionaler Grund. Dient als Protokoll; nach Ablauf wird der
/// Spielerstatus automatisch wieder auf „Fit" gesetzt.
class PlayerAbsence {
  final String id;
  final String playerId;
  final PlayerStatus status;
  final DateTime from;
  final DateTime until;
  final String? note;
  final DateTime createdAt;

  const PlayerAbsence({
    required this.id,
    required this.playerId,
    required this.status,
    required this.from,
    required this.until,
    this.note,
    required this.createdAt,
  });

  /// Nur das Datum (ohne Uhrzeit) als ISO-String „YYYY-MM-DD".
  static String _d(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Map<String, Object?> toMap() => {
        'id': id,
        'player_id': playerId,
        'status': status.storageKey,
        'from_date': _d(from),
        'until_date': _d(until),
        'note': note,
        'created_at': createdAt.toIso8601String(),
      };

  factory PlayerAbsence.fromMap(Map<String, Object?> m) => PlayerAbsence(
        id: m['id'] as String,
        playerId: m['player_id'] as String,
        status: PlayerStatus.fromKey(m['status'] as String?),
        from: DateTime.tryParse(m['from_date'] as String? ?? '') ??
            DateTime.now(),
        until: DateTime.tryParse(m['until_date'] as String? ?? '') ??
            DateTime.now(),
        note: m['note'] as String?,
        createdAt: DateTime.tryParse(m['created_at'] as String? ?? '') ??
            DateTime.now(),
      );
}
