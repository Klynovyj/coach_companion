import 'enums.dart';

/// Ein Spieler, fest einem [Team] zugeordnet.
class Player {
  final String id;
  final String teamId;
  final String firstName;
  final String lastName;

  /// Rückennummer (optional).
  final int? number;

  /// Position/Spielort als Freitext (z.B. "Sturm", "IV").
  final String? position;

  /// Wunschposition (Freitext).
  final String? wishPosition;

  /// Verfügbarkeitsstatus (Fit/Verletzt/Krank/Gesperrt).
  final PlayerStatus status;

  /// Kapitäns-Rolle (je eine pro Mannschaft).
  final CaptainRole captainRole;

  /// Externer Bezeichner aus der Importquelle – für Duplikaterkennung.
  final String? externalId;

  /// Spielerfoto als Data-URL (image/jpeg), falls synchronisiert.
  final String? photoPath;

  final DataSource source;

  /// false = gilt aktuell als nicht im Kader (z.B. abgemeldet).
  final bool active;

  final DateTime createdAt;

  const Player({
    required this.id,
    required this.teamId,
    required this.firstName,
    required this.lastName,
    this.number,
    this.position,
    this.wishPosition,
    this.status = PlayerStatus.fit,
    this.captainRole = CaptainRole.none,
    this.externalId,
    this.photoPath,
    this.source = DataSource.manual,
    this.active = true,
    required this.createdAt,
  });

  String get fullName {
    final f = firstName.trim();
    final l = lastName.trim();
    if (f.isEmpty) return l;
    if (l.isEmpty) return f;
    return '$f $l';
  }

  String get displayName {
    final n = number != null ? '#$number ' : '';
    return '$n$fullName';
  }

  /// Normalisierter Name für die Duplikaterkennung ohne externalId.
  String get dedupKey =>
      '${firstName.trim().toLowerCase()}|${lastName.trim().toLowerCase()}';

  Player copyWith({
    String? teamId,
    String? firstName,
    String? lastName,
    int? number,
    bool clearNumber = false,
    String? position,
    String? wishPosition,
    PlayerStatus? status,
    CaptainRole? captainRole,
    String? externalId,
    String? photoPath,
    DataSource? source,
    bool? active,
  }) {
    return Player(
      id: id,
      teamId: teamId ?? this.teamId,
      firstName: firstName ?? this.firstName,
      lastName: lastName ?? this.lastName,
      number: clearNumber ? null : (number ?? this.number),
      position: position ?? this.position,
      wishPosition: wishPosition ?? this.wishPosition,
      status: status ?? this.status,
      captainRole: captainRole ?? this.captainRole,
      externalId: externalId ?? this.externalId,
      photoPath: photoPath ?? this.photoPath,
      source: source ?? this.source,
      active: active ?? this.active,
      createdAt: createdAt,
    );
  }

  Map<String, Object?> toMap() => {
        'id': id,
        'team_id': teamId,
        'first_name': firstName,
        'last_name': lastName,
        'number': number,
        'position': position,
        'wish_position': wishPosition,
        'status': status.storageKey,
        'captain_role': captainRole.storageKey,
        'external_id': externalId,
        'photo_path': photoPath,
        'source': source.storageKey,
        'active': active ? 1 : 0,
        'created_at': createdAt.toIso8601String(),
      };

  factory Player.fromMap(Map<String, Object?> m) => Player(
        id: m['id'] as String,
        teamId: m['team_id'] as String,
        firstName: m['first_name'] as String? ?? '',
        lastName: m['last_name'] as String? ?? '',
        number: m['number'] as int?,
        position: m['position'] as String?,
        wishPosition: m['wish_position'] as String?,
        status: PlayerStatus.fromKey(m['status'] as String?),
        captainRole: CaptainRole.fromKey(m['captain_role'] as String?),
        externalId: m['external_id'] as String?,
        photoPath: m['photo_path'] as String?,
        source: DataSource.fromKey(m['source'] as String?),
        active: (m['active'] as int? ?? 1) == 1,
        createdAt:
            DateTime.tryParse(m['created_at'] as String? ?? '') ??
                DateTime.now(),
      );
}
