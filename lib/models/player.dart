import 'enums.dart';

/// Ein Spieler, fest einem [Team] zugeordnet.
class Player {
  final String id;
  final String teamId;
  final String firstName;
  final String lastName;

  /// Spitzname (optional) – z.B. für die Mannschaftsnachricht.
  final String? nickname;

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

  /// Rolle im Trainerteam (z.B. „Trainer", „Co-Trainer"); null = Spieler.
  final String? staffRole;

  /// true = hat eine Trainerrolle (auch spielender Co-Trainer) – kein
  /// Ball-/Materialdienst.
  bool get isStaff => staffRole != null && staffRole!.isNotEmpty;

  /// true = reines Trainerteam (nicht spielend) – eigener Kader-Bereich,
  /// keine Nominierung/Aufstellung. Ein „spielender Co-Trainer" bleibt Spieler.
  bool get isStaffOnly =>
      isStaff && !staffRole!.toLowerCase().contains('spielend');

  /// Effektiver Verfügbarkeitsstatus (abgeleitet): laufende Abwesenheit (Grund)
  /// falls vorhanden, sonst der Grundstatus [baseStatus]. Überall für die
  /// Anzeige/Logik genutzt.
  final PlayerStatus status;

  /// Grundstatus (manuell im Status-Menü gesetzt): nur Fit oder Inaktiv.
  /// Abwesenheiten (krank, verletzt, abwesend …) überlagern ihn nur zeitweise.
  final PlayerStatus baseStatus;

  /// Kapitäns-Rolle (je eine pro Mannschaft).
  final CaptainRole captainRole;

  /// Geburtsdatum (optional) – u.a. für die Gruppen im Ball-/Materialdienst.
  final DateTime? birthdate;

  /// Externer Bezeichner aus der Importquelle – für Duplikaterkennung.
  final String? externalId;

  /// Foto aus dem FuPa-Import (nur der Import schreibt es).
  final String? fupaPhoto;

  /// Selbst hochgeladenes Foto (nur der Upload schreibt es).
  final String? customPhoto;

  /// true = das eigene Foto bevorzugen/anzeigen; false = FuPa-Foto.
  final bool useCustomPhoto;

  /// Das anzuzeigende Foto (überall für die Anzeige genutzt): bei „mein Foto"
  /// das eigene, sonst das FuPa-Foto – je mit Rückfall aufs andere.
  String? get photoPath =>
      useCustomPhoto ? (customPhoto ?? fupaPhoto) : (fupaPhoto ?? customPhoto);

  bool get hasFupaPhoto => fupaPhoto != null && fupaPhoto!.isNotEmpty;
  bool get hasCustomPhoto => customPhoto != null && customPhoto!.isNotEmpty;

  final DataSource source;

  /// false = gilt aktuell als nicht im Kader (z.B. abgemeldet).
  final bool active;

  /// Anzahl noch abzusitzender Spiele einer Sperre (0 = nicht gesperrt).
  /// Manuell gepflegt (Gelb-Rot/Rot/Verbandsstrafe), vom Trainer heruntergezählt.
  final int suspendedGames;

  /// Wettbewerb, für den die Sperre gilt (z.B. „Kreisliga B2" oder
  /// „Kreispokal …"); null = alle. Betrifft nur Spiele dieses Wettbewerbs.
  final String? suspensionCompetition;

  /// Ab wann die Sperre gilt (nur Spiele ab diesem Datum zählen).
  final DateTime? suspensionFrom;

  final DateTime createdAt;

  const Player({
    required this.id,
    required this.teamId,
    required this.firstName,
    required this.lastName,
    this.nickname,
    this.number,
    this.position,
    this.positions = const [],
    this.wishPosition,
    this.isStarter = false,
    this.staffRole,
    this.status = PlayerStatus.fit,
    this.baseStatus = PlayerStatus.fit,
    this.captainRole = CaptainRole.none,
    this.birthdate,
    this.externalId,
    this.fupaPhoto,
    this.customPhoto,
    this.useCustomPhoto = true,
    this.source = DataSource.manual,
    this.active = true,
    this.suspendedGames = 0,
    this.suspensionCompetition,
    this.suspensionFrom,
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

  /// Spitzname, falls gepflegt – sonst der volle Name (Listen/Aufgebot).
  String get shortOrFullName {
    final n = nickname?.trim();
    return (n != null && n.isNotEmpty) ? n : fullName;
  }

  /// Kurzer Anzeigename fürs Feld: Spitzname, sonst Nachname (bzw. Vorname).
  String get pitchName {
    final n = nickname?.trim();
    if (n != null && n.isNotEmpty) return n;
    return lastName.isNotEmpty ? lastName : firstName;
  }

  /// Normalisierter Name für die Duplikaterkennung ohne externalId.
  String get dedupKey =>
      '${firstName.trim().toLowerCase()}|${lastName.trim().toLowerCase()}';

  Player copyWith({
    String? teamId,
    String? firstName,
    String? lastName,
    String? nickname,
    bool clearNickname = false,
    int? number,
    bool clearNumber = false,
    String? position,
    bool clearPosition = false,
    List<String>? positions,
    String? wishPosition,
    bool clearWishPosition = false,
    bool? isStarter,
    String? staffRole,
    bool clearStaffRole = false,
    PlayerStatus? status,
    PlayerStatus? baseStatus,
    CaptainRole? captainRole,
    DateTime? birthdate,
    bool clearBirthdate = false,
    String? externalId,
    String? fupaPhoto,
    bool clearFupaPhoto = false,
    String? customPhoto,
    bool clearCustomPhoto = false,
    bool? useCustomPhoto,
    DataSource? source,
    bool? active,
    int? suspendedGames,
    String? suspensionCompetition,
    bool clearSuspensionCompetition = false,
    DateTime? suspensionFrom,
    bool clearSuspensionFrom = false,
  }) {
    return Player(
      id: id,
      teamId: teamId ?? this.teamId,
      firstName: firstName ?? this.firstName,
      lastName: lastName ?? this.lastName,
      nickname: clearNickname ? null : (nickname ?? this.nickname),
      number: clearNumber ? null : (number ?? this.number),
      position: clearPosition ? null : (position ?? this.position),
      positions: positions ?? this.positions,
      wishPosition: clearWishPosition
          ? null
          : (wishPosition ?? this.wishPosition),
      isStarter: isStarter ?? this.isStarter,
      staffRole: clearStaffRole ? null : (staffRole ?? this.staffRole),
      status: status ?? this.status,
      baseStatus: baseStatus ?? this.baseStatus,
      captainRole: captainRole ?? this.captainRole,
      birthdate: clearBirthdate ? null : (birthdate ?? this.birthdate),
      externalId: externalId ?? this.externalId,
      fupaPhoto: clearFupaPhoto ? null : (fupaPhoto ?? this.fupaPhoto),
      customPhoto: clearCustomPhoto ? null : (customPhoto ?? this.customPhoto),
      useCustomPhoto: useCustomPhoto ?? this.useCustomPhoto,
      source: source ?? this.source,
      active: active ?? this.active,
      suspendedGames: suspendedGames ?? this.suspendedGames,
      suspensionCompetition: clearSuspensionCompetition
          ? null
          : (suspensionCompetition ?? this.suspensionCompetition),
      suspensionFrom: clearSuspensionFrom
          ? null
          : (suspensionFrom ?? this.suspensionFrom),
      createdAt: createdAt,
    );
  }

  Map<String, Object?> toMap() => {
    'id': id,
    'team_id': teamId,
    'first_name': firstName,
    'last_name': lastName,
    'nickname': nickname,
    'number': number,
    'position': position,
    'positions': positions.join(','),
    'wish_position': wishPosition,
    'is_starter': isStarter ? 1 : 0,
    'staff_role': staffRole,
    'status': status.storageKey,
    'base_status': baseStatus.storageKey,
    'captain_role': captainRole.storageKey,
    'birthdate': birthdate?.toIso8601String(),
    'external_id': externalId,
    // Aktives Foto zusätzlich (Abwärtskompatibilität für ältere Clients).
    'photo_path': photoPath,
    'photo_fupa': fupaPhoto,
    'photo_custom': customPhoto,
    'use_custom_photo': useCustomPhoto ? 1 : 0,
    'source': source.storageKey,
    'active': active ? 1 : 0,
    'suspended_games': suspendedGames,
    'suspension_competition': suspensionCompetition,
    'suspension_from': suspensionFrom?.toIso8601String(),
    'created_at': createdAt.toIso8601String(),
  };

  factory Player.fromMap(Map<String, Object?> m) => Player(
    id: m['id'] as String,
    teamId: m['team_id'] as String,
    firstName: m['first_name'] as String? ?? '',
    lastName: m['last_name'] as String? ?? '',
    nickname: m['nickname'] as String?,
    number: m['number'] as int?,
    position: m['position'] as String?,
    positions: ((m['positions'] as String?) ?? '')
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList(),
    wishPosition: m['wish_position'] as String?,
    isStarter: (m['is_starter'] as int? ?? 0) == 1,
    staffRole: m['staff_role'] as String?,
    status: PlayerStatus.fromKey(m['status'] as String?),
    // Grundstatus: fehlt er (Altzeile/Altschema), aus dem Status ableiten
    // (inaktiv bleibt inaktiv, alles andere fit).
    baseStatus: m['base_status'] != null
        ? PlayerStatus.fromKey(m['base_status'] as String?)
        : (PlayerStatus.fromKey(m['status'] as String?) == PlayerStatus.inaktiv
              ? PlayerStatus.inaktiv
              : PlayerStatus.fit),
    captainRole: CaptainRole.fromKey(m['captain_role'] as String?),
    birthdate: DateTime.tryParse(m['birthdate'] as String? ?? ''),
    externalId: m['external_id'] as String?,
    fupaPhoto: m['photo_fupa'] as String?,
    // Abwärtskompat: alte Zeilen ohne neue Spalten → altes Foto als eigenes.
    customPhoto: (m['photo_custom'] as String?) ?? (m['photo_path'] as String?),
    useCustomPhoto: (m['use_custom_photo'] as num?)?.toInt() != 0,
    source: DataSource.fromKey(m['source'] as String?),
    active: (m['active'] as int? ?? 1) == 1,
    suspendedGames: m['suspended_games'] as int? ?? 0,
    suspensionCompetition: m['suspension_competition'] as String?,
    suspensionFrom: DateTime.tryParse(m['suspension_from'] as String? ?? ''),
    createdAt:
        DateTime.tryParse(m['created_at'] as String? ?? '') ?? DateTime.now(),
  );
}

/// Führt doppelte Spielerzeilen desselben Namens zu einer zusammen – bevorzugt
/// die Zeile mit FuPa-ID (externalId) und sonst mehr Infos (Nummer/Position).
/// Reihenfolge bleibt erhalten. Nötig v.a. bei Gegnerkadern, wo sich über die
/// Cloud/mehrere Geräte zwei Zeilen pro Spieler sammeln können.
List<Player> dedupePlayersByName(List<Player> players) {
  final byKey = <String, Player>{};
  final order = <String>[];
  for (final p in players) {
    final key = p.dedupKey;
    final existing = byKey[key];
    if (existing == null) {
      byKey[key] = p;
      order.add(key);
    } else if (playerIsRicher(p, existing)) {
      byKey[key] = p;
    }
  }
  return [for (final k in order) byKey[k]!];
}

/// Welche von zwei Zeilen desselben Spielers ist „reicher" (beim Entdoppeln zu
/// behalten): die mit FuPa-ID (externalId), sonst die mit mehr Infos
/// (Nummer/Position). Gleichstand → [a].
bool playerIsRicher(Player a, Player b) {
  final ax = a.externalId != null && a.externalId!.isNotEmpty;
  final bx = b.externalId != null && b.externalId!.isNotEmpty;
  if (ax != bx) return ax; // Zeile mit FuPa-ID gewinnt.
  final an = (a.number != null ? 1 : 0) + (a.position != null ? 1 : 0);
  final bn = (b.number != null ? 1 : 0) + (b.position != null ? 1 : 0);
  return an >= bn;
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
