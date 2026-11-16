import 'dart:convert';

/// Eigene Spieler-Gruppe für den Statistik-Baukasten (z. B. „Abwehr", „U23").
/// Team-weit geteilt (Cloud-Tabelle `stat_groups`, lokal ohne team_id).
class StatGroup {
  const StatGroup({
    required this.id,
    required this.name,
    required this.playerIds,
    this.createdBy,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final List<String> playerIds;
  final String? createdBy;
  final String updatedAt;

  StatGroup copyWith({String? name, List<String>? playerIds}) => StatGroup(
    id: id,
    name: name ?? this.name,
    playerIds: playerIds ?? this.playerIds,
    createdBy: createdBy,
    updatedAt: DateTime.now().toUtc().toIso8601String(),
  );

  Map<String, Object?> toRow() => {
    'id': id,
    'name': name,
    'player_ids': jsonEncode(playerIds),
    'created_by': createdBy,
    'updated_at': updatedAt,
  };

  static StatGroup? fromRow(Map<String, Object?> r) {
    final id = r['id'] as String?;
    if (id == null) return null;
    var ids = <String>[];
    try {
      ids = [
        for (final e
            in jsonDecode((r['player_ids'] as String?) ?? '[]') as List)
          e.toString(),
      ];
    } catch (_) {}
    return StatGroup(
      id: id,
      name: (r['name'] as String?) ?? '',
      playerIds: ids,
      createdBy: r['created_by'] as String?,
      updatedAt: (r['updated_at'] as String?) ?? '',
    );
  }
}
