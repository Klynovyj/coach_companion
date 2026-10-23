import 'enums.dart';

/// Eine Gelbe/Gelb-Rote/Rote Karte eines Spielers – manuell erfasst oder aus
/// dem Live-Modus übernommen (dann mit [matchId]/[matchEventId]/[minute]).
class CardEntry {
  final String id;
  final String playerId;
  final CardType type;
  final DateTime date;

  /// Zugehöriges Spiel (optional).
  final String? matchId;

  /// Verknüpftes Live-Ereignis – damit Löschen im Live-Ticker die Karte mitnimmt.
  final String? matchEventId;

  final int? minute;
  final int minuteExtra;
  final String? note;

  const CardEntry({
    required this.id,
    required this.playerId,
    required this.type,
    required this.date,
    this.matchId,
    this.matchEventId,
    this.minute,
    this.minuteExtra = 0,
    this.note,
  });

  /// Minuten-Anzeige inkl. Nachspielzeit, z.B. "45+2'"; leer wenn keine Minute.
  String get minuteLabel => minute == null
      ? ''
      : (minuteExtra > 0 ? "$minute+$minuteExtra'" : "$minute'");

  CardEntry copyWith({
    CardType? type,
    DateTime? date,
    String? note,
    int? minute,
    String? matchId,
    bool clearMatchId = false,
  }) =>
      CardEntry(
        id: id,
        playerId: playerId,
        type: type ?? this.type,
        date: date ?? this.date,
        matchId: clearMatchId ? null : (matchId ?? this.matchId),
        matchEventId: matchEventId,
        minute: minute ?? this.minute,
        minuteExtra: minuteExtra,
        note: note ?? this.note,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'player_id': playerId,
        'type': type.storageKey,
        'date': date.toIso8601String(),
        'match_id': matchId,
        'match_event_id': matchEventId,
        'minute': minute,
        'minute_extra': minuteExtra,
        'note': note,
      };

  factory CardEntry.fromMap(Map<String, Object?> m) => CardEntry(
        id: m['id'] as String,
        playerId: m['player_id'] as String,
        type: CardType.fromKey(m['type'] as String?),
        date: DateTime.tryParse(m['date'] as String? ?? '') ?? DateTime.now(),
        matchId: m['match_id'] as String?,
        matchEventId: m['match_event_id'] as String?,
        minute: m['minute'] as int?,
        minuteExtra: m['minute_extra'] as int? ?? 0,
        note: m['note'] as String?,
      );
}
