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

  /// Aktuelle Positionen aus der vordefinierten Liste (mehrere möglich).
  final List<String> positions;

  /// Wunschposition (Freitext).
  final String? wishPosition;

  /// Gehört zur Stammelf (Stamm-11)?
  final bool isStarter;

  /// Verfügbarkeitsstatus (Fit/Verletzt/Krank/Gesperrt).
  final PlayerStatus status;

  /// Kapitäns-Rolle (je eine pro Mannschaft).
  final CaptainRole captainRole;

  /// Geburtsdatum (optional) – u.a. für die Gruppen im Ball-/Materialdienst.
  final DateTime? birthdate;

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
    this.positions = const [],
    this.wishPosition,
    this.isStarter = false,
    this.status = PlayerStatus.fit,
    this.captainRole = CaptainRole.none,
    this.birthdate,
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
    bool clearPosition = false,
    List<String>? positions,
    String? wishPosition,
    bool clearWishPosition = false,
    bool? isStarter,
    PlayerStatus? status,
    CaptainRole? captainRole,
    DateTime? birthdate,
    bool clearBirthdate = false,
    String? externalId,
    String? photoPath,
    bool clearPhotoPath = false,
    DataSource? source,
    bool? active,
  }) {
    return Player(
      id: id,
      teamId: teamId ?? this.teamId,
      firstName: firstName ?? this.firstName,
      lastName: lastName ?? this.lastName,
      number: clearNumber ? null : (number ?? this.number),
      position: clearPosition ? null : (position ?? this.position),
      positions: positions ?? this.positions,
      wishPosition:
          clearWishPosition ? null : (wishPosition ?? this.wishPosition),
      isStarter: isStarter ?? this.isStarter,
      status: status ?? this.status,
      captainRole: captainRole ?? this.captainRole,
      birthdate: clearBirthdate ? null : (birthdate ?? this.birthdate),
      externalId: externalId ?? this.externalId,
      photoPath: clearPhotoPath ? null : (photoPath ?? this.photoPath),
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
        'positions': positions.join(','),
        'wish_position': wishPosition,
        'is_starter': isStarter ? 1 : 0,
        'status': status.storageKey,
        'captain_role': captainRole.storageKey,
        'birthdate': birthdate?.toIso8601String(),
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
        positions: ((m['positions'] as String?) ?? '')
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList(),
        wishPosition: m['wish_position'] as String?,
        isStarter: (m['is_starter'] as int? ?? 0) == 1,
        status: PlayerStatus.fromKey(m['status'] as String?),
        captainRole: CaptainRole.fromKey(m['captain_role'] as String?),
        birthdate: DateTime.tryParse(m['birthdate'] as String? ?? ''),
        externalId: m['external_id'] as String?,
        photoPath: m['photo_path'] as String?,
        source: DataSource.fromKey(m['source'] as String?),
        active: (m['active'] as int? ?? 1) == 1,
        createdAt:
            DateTime.tryParse(m['created_at'] as String? ?? '') ??
                DateTime.now(),
      );
}

/// Vordefinierte Positionen für die Mehrfachauswahl im Spielerprofil.
const List<String> kPositionOptions = [
  'TW',
  'IV',
  'LV',
  'RV',
  'DM',
  'ZM',
  'OM',
  'LM',
  'RM',
  'LA',
  'RA',
  'ST',
  '6',
  '8',
  '10',
];
