import 'dart:convert';

import 'drill_diagram.dart';

/// Eine Trainings-Übung aus der Bibliothek. Enthält Textfelder, eine optionale
/// Skizze, Video-Links und optional das Original-Skizzenfoto. Lokal ohne
/// `team_id`; die Cloud-Zeile bekommt beim Push team_id.
class Exercise {
  final String id;
  final String title;

  /// Trainingsarten/Tags (z.B. „Taktik", „Standards").
  final List<String> categories;

  final String aufbau;
  final String ablauf;
  final String coachingPoints;
  final String varianten;

  /// Minimale Feldspielerzahl (null = egal), ob ein Torwart gebraucht wird und
  /// wie viele Torhüter dafür vorgesehen sind.
  final int? minPlayers;
  final bool needsGoalkeeper;
  final int? goalkeepers;

  final int? durationMin;
  final String material;

  final DrillDiagram? diagram;
  final List<String> videoLinks;

  /// Data-URL des hochgeladenen Original-Skizzenfotos (optional).
  final String? sketchPhotoUrl;

  /// manual | ai | photo | video
  final String source;
  final String? createdBy;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Favorit (oben in der Bibliothek) bzw. archiviert (standardmäßig versteckt).
  final bool favorite;
  final bool archived;

  const Exercise({
    required this.id,
    required this.title,
    this.categories = const [],
    this.aufbau = '',
    this.ablauf = '',
    this.coachingPoints = '',
    this.varianten = '',
    this.minPlayers,
    this.needsGoalkeeper = false,
    this.goalkeepers,
    this.durationMin,
    this.material = '',
    this.diagram,
    this.videoLinks = const [],
    this.sketchPhotoUrl,
    this.source = 'manual',
    this.createdBy,
    required this.createdAt,
    required this.updatedAt,
    this.favorite = false,
    this.archived = false,
  });

  Exercise copyWith({
    String? title,
    List<String>? categories,
    String? aufbau,
    String? ablauf,
    String? coachingPoints,
    String? varianten,
    int? minPlayers,
    bool clearMinPlayers = false,
    bool? needsGoalkeeper,
    int? goalkeepers,
    bool clearGoalkeepers = false,
    int? durationMin,
    bool clearDuration = false,
    String? material,
    DrillDiagram? diagram,
    bool clearDiagram = false,
    List<String>? videoLinks,
    String? sketchPhotoUrl,
    bool clearSketchPhoto = false,
    String? source,
    DateTime? updatedAt,
    bool? favorite,
    bool? archived,
  }) => Exercise(
    id: id,
    title: title ?? this.title,
    categories: categories ?? this.categories,
    aufbau: aufbau ?? this.aufbau,
    ablauf: ablauf ?? this.ablauf,
    coachingPoints: coachingPoints ?? this.coachingPoints,
    varianten: varianten ?? this.varianten,
    minPlayers: clearMinPlayers ? null : (minPlayers ?? this.minPlayers),
    needsGoalkeeper: needsGoalkeeper ?? this.needsGoalkeeper,
    goalkeepers: clearGoalkeepers ? null : (goalkeepers ?? this.goalkeepers),
    durationMin: clearDuration ? null : (durationMin ?? this.durationMin),
    material: material ?? this.material,
    diagram: clearDiagram ? null : (diagram ?? this.diagram),
    videoLinks: videoLinks ?? this.videoLinks,
    sketchPhotoUrl: clearSketchPhoto
        ? null
        : (sketchPhotoUrl ?? this.sketchPhotoUrl),
    source: source ?? this.source,
    createdBy: createdBy,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    favorite: favorite ?? this.favorite,
    archived: archived ?? this.archived,
  );

  Map<String, Object?> toMap() => {
    'id': id,
    'title': title,
    'categories': categories.isEmpty ? null : jsonEncode(categories),
    'aufbau': aufbau,
    'ablauf': ablauf,
    'coaching_points': coachingPoints,
    'varianten': varianten,
    'min_players': minPlayers,
    'needs_goalkeeper': needsGoalkeeper ? 1 : 0,
    'goalkeepers': goalkeepers,
    'duration_min': durationMin,
    'material': material,
    'diagram': diagram?.encode(),
    'video_links': videoLinks.isEmpty ? null : jsonEncode(videoLinks),
    'sketch_photo': sketchPhotoUrl,
    'source': source,
    'created_by': createdBy,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
    'favorite': favorite ? 1 : 0,
    'archived': archived ? 1 : 0,
  };

  factory Exercise.fromMap(Map<String, Object?> m) => Exercise(
    id: m['id'] as String,
    title: (m['title'] as String?) ?? '',
    categories: _decodeList(m['categories']),
    aufbau: (m['aufbau'] as String?) ?? '',
    ablauf: (m['ablauf'] as String?) ?? '',
    coachingPoints: (m['coaching_points'] as String?) ?? '',
    varianten: (m['varianten'] as String?) ?? '',
    minPlayers: (m['min_players'] as num?)?.toInt(),
    needsGoalkeeper:
        m['needs_goalkeeper'] == 1 || m['needs_goalkeeper'] == true,
    goalkeepers: (m['goalkeepers'] as num?)?.toInt(),
    durationMin: (m['duration_min'] as num?)?.toInt(),
    material: (m['material'] as String?) ?? '',
    diagram: DrillDiagram.decode(m['diagram'] as String?),
    videoLinks: _decodeList(m['video_links']),
    sketchPhotoUrl: m['sketch_photo'] as String?,
    source: (m['source'] as String?) ?? 'manual',
    createdBy: m['created_by'] as String?,
    createdAt:
        DateTime.tryParse(m['created_at'] as String? ?? '') ?? DateTime.now(),
    updatedAt:
        DateTime.tryParse(m['updated_at'] as String? ?? '') ?? DateTime.now(),
    favorite: m['favorite'] == 1 || m['favorite'] == true,
    archived: m['archived'] == 1 || m['archived'] == true,
  );

  static List<String> _decodeList(Object? v) {
    final s = v as String?;
    if (s == null || s.isEmpty) return const [];
    try {
      return [for (final e in jsonDecode(s) as List) e.toString()];
    } catch (_) {
      return const [];
    }
  }
}
