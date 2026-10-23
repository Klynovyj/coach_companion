import 'enums.dart';

/// Ein Live-Ereignis in einem Spiel, immer einem Team zugeordnet.
///
/// Belegung der Spielerfelder je Typ:
///  - [goal] / [ownGoal]: [playerId] = Torschütze, [assistPlayerId] = Vorlage
///  - [substitution]: [playerId] = kommt (ein), [assistPlayerId] = geht (raus)
///  - Karten: [playerId] = verwarnter Spieler
class MatchEvent {
  final String id;
  final String matchId;
  final String teamId;

  /// Spielminute (automatisch aus der Live-Uhr, manuell korrigierbar).
  final int minute;

  /// Nachspielzeit-Zusatz (z.B. 2 für „45+2"); 0 = reguläre Zeit.
  final int minuteExtra;

  final MatchEventType type;

  /// Haupt-Spieler (Torschütze / eingewechselt / verwarnt).
  final String? playerId;

  /// Zweit-Spieler (Vorlagengeber / ausgewechselt).
  final String? assistPlayerId;

  final String? note;

  final DateTime createdAt;

  const MatchEvent({
    required this.id,
    required this.matchId,
    required this.teamId,
    required this.minute,
    this.minuteExtra = 0,
    required this.type,
    this.playerId,
    this.assistPlayerId,
    this.note,
    required this.createdAt,
  });

  /// Anzeige der Spielminute inkl. Nachspielzeit, z.B. "45+2'".
  String get minuteLabel =>
      minuteExtra > 0 ? "$minute+$minuteExtra'" : "$minute'";

  MatchEvent copyWith({
    int? minute,
    int? minuteExtra,
    MatchEventType? type,
    String? playerId,
    String? assistPlayerId,
    String? note,
  }) {
    return MatchEvent(
      id: id,
      matchId: matchId,
      teamId: teamId,
      minute: minute ?? this.minute,
      minuteExtra: minuteExtra ?? this.minuteExtra,
      type: type ?? this.type,
      playerId: playerId ?? this.playerId,
      assistPlayerId: assistPlayerId ?? this.assistPlayerId,
      note: note ?? this.note,
      createdAt: createdAt,
    );
  }

  Map<String, Object?> toMap() => {
        'id': id,
        'match_id': matchId,
        'team_id': teamId,
        'minute': minute,
        'minute_extra': minuteExtra,
        'type': type.storageKey,
        'player_id': playerId,
        'assist_player_id': assistPlayerId,
        'note': note,
        'created_at': createdAt.toIso8601String(),
      };

  factory MatchEvent.fromMap(Map<String, Object?> m) => MatchEvent(
        id: m['id'] as String,
        matchId: m['match_id'] as String,
        teamId: m['team_id'] as String,
        minute: m['minute'] as int? ?? 0,
        minuteExtra: m['minute_extra'] as int? ?? 0,
        type: MatchEventType.fromKey(m['type'] as String?),
        playerId: m['player_id'] as String?,
        assistPlayerId: m['assist_player_id'] as String?,
        note: m['note'] as String?,
        createdAt:
            DateTime.tryParse(m['created_at'] as String? ?? '') ??
                DateTime.now(),
      );
}
