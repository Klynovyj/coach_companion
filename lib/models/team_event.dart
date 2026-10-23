import 'enums.dart';

/// Ein Mannschafts-Termin (z.B. Weihnachtsfeier, Mannschaftsfoto, Grillen).
class TeamEvent {
  final String id;
  final String teamId;
  final String title;
  final TeamEventType type;

  /// Datum/Uhrzeit des Termins.
  final DateTime date;

  final String? location;
  final String? note;
  final DateTime createdAt;

  const TeamEvent({
    required this.id,
    required this.teamId,
    required this.title,
    required this.type,
    required this.date,
    this.location,
    this.note,
    required this.createdAt,
  });

  TeamEvent copyWith({
    String? title,
    TeamEventType? type,
    DateTime? date,
    String? location,
    String? note,
  }) =>
      TeamEvent(
        id: id,
        teamId: teamId,
        title: title ?? this.title,
        type: type ?? this.type,
        date: date ?? this.date,
        location: location ?? this.location,
        note: note ?? this.note,
        createdAt: createdAt,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'team_id': teamId,
        'title': title,
        'type': type.storageKey,
        'date': date.toIso8601String(),
        'location': location,
        'note': note,
        'created_at': createdAt.toIso8601String(),
      };

  factory TeamEvent.fromMap(Map<String, Object?> m) => TeamEvent(
        id: m['id'] as String,
        teamId: m['team_id'] as String,
        title: m['title'] as String? ?? '',
        type: TeamEventType.fromKey(m['type'] as String?),
        date: DateTime.tryParse(m['date'] as String? ?? '') ?? DateTime.now(),
        location: m['location'] as String?,
        note: m['note'] as String?,
        createdAt: DateTime.tryParse(m['created_at'] as String? ?? '') ??
            DateTime.now(),
      );
}

/// Zu-/Absage eines Spielers zu einem Termin (gleicher Status wie Nominierung).
class EventAttendance {
  final String id;
  final String eventId;
  final String playerId;
  final NominationStatus status;
  final DateTime updatedAt;

  const EventAttendance({
    required this.id,
    required this.eventId,
    required this.playerId,
    required this.status,
    required this.updatedAt,
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'event_id': eventId,
        'player_id': playerId,
        'status': status.storageKey,
        'updated_at': updatedAt.toIso8601String(),
      };

  factory EventAttendance.fromMap(Map<String, Object?> m) => EventAttendance(
        id: m['id'] as String,
        eventId: m['event_id'] as String,
        playerId: m['player_id'] as String,
        status: NominationStatus.fromKey(m['status'] as String?),
        updatedAt: DateTime.tryParse(m['updated_at'] as String? ?? '') ??
            DateTime.now(),
      );
}
