import 'enums.dart';

/// Eine Mannschaft – eigenes Team oder Gegner.
class Team {
  final String id;
  final String name;

  /// Vereinskürzel / Kurzname (optional, für kompakte Anzeige).
  final String? shortName;

  /// Original FuPa-Teamlink, wie vom Trainer eingegeben.
  final String? fupaUrl;

  /// Aus dem Link ermittelter, stabiler Team-Bezeichner (Slug).
  final String? fupaRef;

  /// Vereinslogo als Data-URL (image/png), falls importiert.
  final String? logoPath;

  /// true = die vom Trainer geführte eigene Mannschaft.
  final bool isOwnTeam;

  final DataSource source;

  /// Zeitpunkt der letzten erfolgreichen Synchronisierung.
  final DateTime? lastSyncedAt;

  final DateTime createdAt;

  const Team({
    required this.id,
    required this.name,
    this.shortName,
    this.fupaUrl,
    this.fupaRef,
    this.logoPath,
    this.isOwnTeam = false,
    this.source = DataSource.manual,
    this.lastSyncedAt,
    required this.createdAt,
  });

  Team copyWith({
    String? name,
    String? shortName,
    String? fupaUrl,
    String? fupaRef,
    String? logoPath,
    bool? isOwnTeam,
    DataSource? source,
    DateTime? lastSyncedAt,
  }) {
    return Team(
      id: id,
      name: name ?? this.name,
      shortName: shortName ?? this.shortName,
      fupaUrl: fupaUrl ?? this.fupaUrl,
      fupaRef: fupaRef ?? this.fupaRef,
      logoPath: logoPath ?? this.logoPath,
      isOwnTeam: isOwnTeam ?? this.isOwnTeam,
      source: source ?? this.source,
      lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      createdAt: createdAt,
    );
  }

  Map<String, Object?> toMap() => {
    'id': id,
    'name': name,
    'short_name': shortName,
    'fupa_url': fupaUrl,
    'fupa_ref': fupaRef,
    'logo_path': logoPath,
    'is_own_team': isOwnTeam ? 1 : 0,
    'source': source.storageKey,
    'last_synced_at': lastSyncedAt?.toIso8601String(),
    'created_at': createdAt.toIso8601String(),
  };

  factory Team.fromMap(Map<String, Object?> m) => Team(
    id: m['id'] as String,
    name: m['name'] as String,
    shortName: m['short_name'] as String?,
    fupaUrl: m['fupa_url'] as String?,
    fupaRef: m['fupa_ref'] as String?,
    logoPath: m['logo_path'] as String?,
    isOwnTeam: (m['is_own_team'] as int? ?? 0) == 1,
    source: DataSource.fromKey(m['source'] as String?),
    lastSyncedAt: _parseDate(m['last_synced_at'] as String?),
    createdAt: _parseDate(m['created_at'] as String?) ?? DateTime.now(),
  );
}

DateTime? _parseDate(String? s) => s == null ? null : DateTime.tryParse(s);
