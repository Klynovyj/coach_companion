import 'package:flutter/material.dart';

import '../services/fupa/fupa_dtos.dart';

/// Status eines beobachteten (gescouteten) Spielers. Feste Liste.
enum ScoutStatus {
  beobachten('beobachten', 'Beobachten', Color(0xFF607D8B)),
  avisiert('avisiert', 'Avisiert', Color(0xFF1565C0)),
  imGespraech('im_gespraech', 'Im Gespräch', Color(0xFFEF6C00)),
  zugesagt('zugesagt', 'Zugesagt', Color(0xFF2E7D32)),
  abgelehnt('abgelehnt', 'Abgelehnt', Color(0xFFC62828));

  const ScoutStatus(this.storageKey, this.label, this.color);
  final String storageKey;
  final String label;
  final Color color;

  static ScoutStatus fromKey(String? key) => ScoutStatus.values.firstWhere(
    (e) => e.storageKey == key,
    orElse: () => ScoutStatus.beobachten,
  );
}

/// Ein beobachteter Spieler im Scouting (team-weit geteilt, cloud-synchron).
/// Lokal OHNE team_id – die Cloud-Zeile bekommt beim Push team_id ergänzt.
class ScoutPlayer {
  final String id;
  final String name;
  final String? position;
  final int? number;

  /// FuPa-Spieler-Link (falls per Link angelegt) – für Statistik & Profil.
  final String? fupaUrl;
  final String? externalId;

  /// Basis-URL des FuPa-Fotos (ohne Größen-Suffix), falls vorhanden.
  final String? photoUrl;

  /// Aktueller Status (denormalisiert aus dem jüngsten Status-Eintrag).
  final ScoutStatus status;
  final DateTime statusDate;

  /// Gecachte FuPa-Statistik (JSON) + Stand.
  final String? statsJson;
  final DateTime? statsUpdatedAt;

  /// Autor (wer den Spieler angelegt hat).
  final String? actorId;
  final String actorName;
  final DateTime createdAt;

  const ScoutPlayer({
    required this.id,
    required this.name,
    this.position,
    this.number,
    this.fupaUrl,
    this.externalId,
    this.photoUrl,
    this.status = ScoutStatus.beobachten,
    required this.statusDate,
    this.statsJson,
    this.statsUpdatedAt,
    this.actorId,
    this.actorName = 'Trainer',
    required this.createdAt,
  });

  /// Direkt nutzbare Foto-URL (FuPa-Basis + Größen-Suffix), sonst null.
  String? get photoDisplayUrl {
    final u = photoUrl?.trim();
    if (u == null || u.isEmpty) return null;
    if (!u.startsWith('http')) return null;
    if (u.endsWith('.jpeg') || u.endsWith('.jpg') || u.endsWith('.png')) {
      return u;
    }
    return '$u/128x128.jpeg';
  }

  ScoutPlayer copyWith({
    String? name,
    String? position,
    int? number,
    String? fupaUrl,
    String? externalId,
    String? photoUrl,
    ScoutStatus? status,
    DateTime? statusDate,
    String? statsJson,
    DateTime? statsUpdatedAt,
  }) => ScoutPlayer(
    id: id,
    name: name ?? this.name,
    position: position ?? this.position,
    number: number ?? this.number,
    fupaUrl: fupaUrl ?? this.fupaUrl,
    externalId: externalId ?? this.externalId,
    photoUrl: photoUrl ?? this.photoUrl,
    status: status ?? this.status,
    statusDate: statusDate ?? this.statusDate,
    statsJson: statsJson ?? this.statsJson,
    statsUpdatedAt: statsUpdatedAt ?? this.statsUpdatedAt,
    actorId: actorId,
    actorName: actorName,
    createdAt: createdAt,
  );

  Map<String, Object?> toMap() => {
    'id': id,
    'name': name,
    'position': position,
    'number': number,
    'fupa_url': fupaUrl,
    'external_id': externalId,
    'photo_url': photoUrl,
    'status': status.storageKey,
    'status_date': statusDate.toIso8601String(),
    'stats_json': statsJson,
    'stats_updated_at': statsUpdatedAt?.toIso8601String(),
    'actor_id': actorId,
    'actor_name': actorName,
    'created_at': createdAt.toIso8601String(),
  };

  factory ScoutPlayer.fromMap(Map<String, Object?> m) => ScoutPlayer(
    id: m['id'] as String,
    name: (m['name'] as String?) ?? '',
    position: m['position'] as String?,
    number: (m['number'] as num?)?.toInt(),
    fupaUrl: m['fupa_url'] as String?,
    externalId: m['external_id'] as String?,
    photoUrl: m['photo_url'] as String?,
    status: ScoutStatus.fromKey(m['status'] as String?),
    statusDate:
        DateTime.tryParse(m['status_date'] as String? ?? '') ?? DateTime.now(),
    statsJson: m['stats_json'] as String?,
    statsUpdatedAt: DateTime.tryParse(m['stats_updated_at'] as String? ?? ''),
    actorId: m['actor_id'] as String?,
    actorName: (m['actor_name'] as String?) ?? 'Trainer',
    createdAt:
        DateTime.tryParse(m['created_at'] as String? ?? '') ?? DateTime.now(),
  );
}

/// Verlaufs-Eintrag zu einem Scouting-Spieler: entweder eine Status-Änderung
/// (kind = 'status') oder eine Notiz (kind = 'note'). Gemeinsamer, datierter
/// Verlauf; team-weit geteilt, mit Autor.
class ScoutEntry {
  final String id;
  final String scoutId;

  /// 'status' oder 'note'.
  final String kind;

  /// Bei kind = 'status': der gesetzte Status.
  final ScoutStatus? status;

  /// Bei kind = 'note': der Notiztext.
  final String? text;

  /// Datum des Eintrags (bei Status das vom Nutzer gewählte Datum).
  final DateTime entryDate;

  final String? actorId;
  final String actorName;
  final DateTime createdAt;

  const ScoutEntry({
    required this.id,
    required this.scoutId,
    required this.kind,
    this.status,
    this.text,
    required this.entryDate,
    this.actorId,
    this.actorName = 'Trainer',
    required this.createdAt,
  });

  bool get isStatus => kind == 'status';

  Map<String, Object?> toMap() => {
    'id': id,
    'scout_id': scoutId,
    'kind': kind,
    'status': status?.storageKey,
    'text': text,
    'entry_date': entryDate.toIso8601String(),
    'actor_id': actorId,
    'actor_name': actorName,
    'created_at': createdAt.toIso8601String(),
  };

  factory ScoutEntry.fromMap(Map<String, Object?> m) => ScoutEntry(
    id: m['id'] as String,
    scoutId: m['scout_id'] as String,
    kind: (m['kind'] as String?) ?? 'note',
    status: m['status'] == null
        ? null
        : ScoutStatus.fromKey(m['status'] as String?),
    text: m['text'] as String?,
    entryDate:
        DateTime.tryParse(m['entry_date'] as String? ?? '') ?? DateTime.now(),
    actorId: m['actor_id'] as String?,
    actorName: (m['actor_name'] as String?) ?? 'Trainer',
    createdAt:
        DateTime.tryParse(m['created_at'] as String? ?? '') ?? DateTime.now(),
  );
}

/// Serialisiert die genutzten Felder einer FuPa-Laufbahn für den Cache.
Map<String, Object?> fupaCareerToMap(FupaCareer c) => {
  'totalMatches': c.totalMatches,
  'totalGoals': c.totalGoals,
  'totalAssists': c.totalAssists,
  'totalYellow': c.totalYellow,
  'totalYellowRed': c.totalYellowRed,
  'totalRed': c.totalRed,
  'totalTopEleven': c.totalTopEleven,
  'stations': [
    for (final s in c.stations)
      {
        'club': s.clubName,
        'competition': s.competition,
        'matches': s.matches,
        'goals': s.goals,
        'assists': s.assists,
      },
  ],
};
