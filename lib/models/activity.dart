/// Typ eines Aktivitäts-Eintrags (für Icon/Filterung in der UI).
enum ActivityType {
  rating('rating'),
  goal('goal'),
  card('card'),
  nomination('nomination'),
  status('status'),
  lineup('lineup'),
  result('result'),
  todo('todo'),
  playerOfMonth('player_of_month'),
  other('other');

  const ActivityType(this.storageKey);
  final String storageKey;

  static ActivityType fromKey(String? key) => ActivityType.values.firstWhere(
    (e) => e.storageKey == key,
    orElse: () => ActivityType.other,
  );
}

/// Ein Eintrag im Aktivitäten-Feed: wer (Trainer) hat was wann gemacht.
/// Team-weit, cloud-synchron. Lokal ohne `team_id` (Cache = ein Team); die
/// Cloud-Zeile bekommt beim Push team_id ergänzt.
class Activity {
  final String id;

  /// Auth-User-ID des Trainers (nullable, falls lokal/ohne Konto erzeugt).
  final String? actorId;

  /// Anzeigename des Trainers zum Zeitpunkt der Aktion (denormalisiert).
  final String actorName;

  final ActivityType type;

  /// Haupttext, z.B. „hat Furkan bewertet".
  final String title;

  /// Zusatz, z.B. „Note 3,5" oder der Spielname (optional).
  final String? subtitle;

  final DateTime createdAt;

  const Activity({
    required this.id,
    this.actorId,
    required this.actorName,
    required this.type,
    required this.title,
    this.subtitle,
    required this.createdAt,
  });

  Map<String, Object?> toMap() => {
    'id': id,
    'actor_id': actorId,
    'actor_name': actorName,
    'type': type.storageKey,
    'title': title,
    'subtitle': subtitle,
    'created_at': createdAt.toIso8601String(),
  };

  factory Activity.fromMap(Map<String, Object?> m) => Activity(
    id: m['id'] as String,
    actorId: m['actor_id'] as String?,
    actorName: (m['actor_name'] as String?) ?? 'Trainer',
    type: ActivityType.fromKey(m['type'] as String?),
    title: (m['title'] as String?) ?? '',
    subtitle: m['subtitle'] as String?,
    createdAt:
        DateTime.tryParse(m['created_at'] as String? ?? '') ?? DateTime.now(),
  );
}
