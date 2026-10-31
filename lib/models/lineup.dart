import 'enums.dart';

/// Aufstellung eines Teams für ein Spiel.
///
/// Eigene Startelf/Formation/Bank bestimmt der Trainer – FuPa liefert hierfür
/// bewusst keine Daten (nur Stammdaten der Spieler). Mehrere Trainer können je
/// eine eigene Aufstellung haben; genau eine kann für „Live" freigegeben sein.
class Lineup {
  final String id;
  final String matchId;
  final String teamId;

  /// Formation als Freitext, z.B. "4-4-2", "3-5-2".
  final String formation;

  /// Frei wählbarer Name des Plans (z.B. „Plan A offensiv"). null → in der UI
  /// wird ein Default („Aufstellung N") angezeigt.
  final String? name;

  /// Reihenfolge in der Aufstellungs-Liste (0 = oben). Die oberste Aufstellung
  /// ist die gültige Start-11 (zählt für Live & Spielbericht).
  final int sortIndex;

  /// Trainer, der diese Aufstellung erstellt hat (Cloud-User-ID). Nur er darf
  /// sie bearbeiten; andere erstellen Vorschläge.
  final String? createdBy;

  /// Anzeigename des Erstellers (denormalisiert, für die Liste).
  final String? creatorName;

  /// true = für „Live" freigegeben (genau eine je Spiel/Team).
  final bool released;

  /// Falls diese Aufstellung ein Vorschlag zu einer anderen ist: deren ID
  /// (Phase 2). null = eigenständige Aufstellung.
  final String? suggestionOf;

  final DateTime createdAt;

  const Lineup({
    required this.id,
    required this.matchId,
    required this.teamId,
    this.formation = '4-4-2',
    this.name,
    this.sortIndex = 0,
    this.createdBy,
    this.creatorName,
    this.released = false,
    this.suggestionOf,
    required this.createdAt,
  });

  Lineup copyWith({
    String? formation,
    String? name,
    bool clearName = false,
    int? sortIndex,
    String? createdBy,
    String? creatorName,
    bool? released,
    String? suggestionOf,
  }) => Lineup(
    id: id,
    matchId: matchId,
    teamId: teamId,
    formation: formation ?? this.formation,
    name: clearName ? null : (name ?? this.name),
    sortIndex: sortIndex ?? this.sortIndex,
    createdBy: createdBy ?? this.createdBy,
    creatorName: creatorName ?? this.creatorName,
    released: released ?? this.released,
    suggestionOf: suggestionOf ?? this.suggestionOf,
    createdAt: createdAt,
  );

  Map<String, Object?> toMap() => {
    'id': id,
    'match_id': matchId,
    'team_id': teamId,
    'formation': formation,
    'name': name,
    'sort_index': sortIndex,
    'created_by': createdBy,
    'creator_name': creatorName,
    'released': released ? 1 : 0,
    'suggestion_of': suggestionOf,
    'created_at': createdAt.toIso8601String(),
  };

  factory Lineup.fromMap(Map<String, Object?> m) => Lineup(
    id: m['id'] as String,
    matchId: m['match_id'] as String,
    teamId: m['team_id'] as String,
    formation: m['formation'] as String? ?? '4-4-2',
    name: (m['name'] as String?)?.trim().isEmpty == true
        ? null
        : m['name'] as String?,
    sortIndex: (m['sort_index'] as num?)?.toInt() ?? 0,
    createdBy: m['created_by'] as String?,
    creatorName: m['creator_name'] as String?,
    released: (m['released'] as num?)?.toInt() == 1,
    suggestionOf: m['suggestion_of'] as String?,
    createdAt:
        DateTime.tryParse(m['created_at'] as String? ?? '') ?? DateTime.now(),
  );
}

/// Eintrag einer Aufstellung: ordnet einen Spieler einer Rolle zu.
class LineupEntry {
  final String id;
  final String lineupId;
  final String playerId;
  final LineupRole role;

  /// Positionsbezeichnung (z.B. "ST", "LV") – optional.
  final String? positionLabel;

  /// Sortier-/Platzierungsindex innerhalb der Rolle.
  final int orderIndex;

  /// Freie Position auf dem Feld, relativ 0..1 (nur für Starter).
  final double? posX;
  final double? posY;

  const LineupEntry({
    required this.id,
    required this.lineupId,
    required this.playerId,
    required this.role,
    this.positionLabel,
    this.orderIndex = 0,
    this.posX,
    this.posY,
  });

  LineupEntry copyWith({
    LineupRole? role,
    String? positionLabel,
    int? orderIndex,
    double? posX,
    double? posY,
  }) => LineupEntry(
    id: id,
    lineupId: lineupId,
    playerId: playerId,
    role: role ?? this.role,
    positionLabel: positionLabel ?? this.positionLabel,
    orderIndex: orderIndex ?? this.orderIndex,
    posX: posX ?? this.posX,
    posY: posY ?? this.posY,
  );

  Map<String, Object?> toMap() => {
    'id': id,
    'lineup_id': lineupId,
    'player_id': playerId,
    'role': role.storageKey,
    'position_label': positionLabel,
    'order_index': orderIndex,
    'pos_x': posX,
    'pos_y': posY,
  };

  factory LineupEntry.fromMap(Map<String, Object?> m) => LineupEntry(
    id: m['id'] as String,
    lineupId: m['lineup_id'] as String,
    playerId: m['player_id'] as String,
    role: LineupRole.fromKey(m['role'] as String?),
    positionLabel: m['position_label'] as String?,
    orderIndex: m['order_index'] as int? ?? 0,
    posX: (m['pos_x'] as num?)?.toDouble(),
    posY: (m['pos_y'] as num?)?.toDouble(),
  );
}
