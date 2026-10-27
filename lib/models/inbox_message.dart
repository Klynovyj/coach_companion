import 'package:flutter/material.dart';

/// Typ eines Posteingang-Eintrags (für Icon/Verständnis in der UI).
enum InboxType {
  lineupAdopted('lineup_adopted'),
  lineupRejected('lineup_rejected'),
  taskAssigned('task_assigned'),
  mention('mention'),
  nomination('nomination'),
  result('result'),
  report('report'),
  other('other');

  const InboxType(this.storageKey);
  final String storageKey;

  static InboxType fromKey(String? key) => InboxType.values.firstWhere(
    (e) => e.storageKey == key,
    orElse: () => InboxType.other,
  );

  /// Symbol für die Liste.
  IconData get icon => switch (this) {
    InboxType.lineupAdopted => Icons.download_done,
    InboxType.lineupRejected => Icons.block,
    InboxType.taskAssigned => Icons.checklist,
    InboxType.mention => Icons.alternate_email,
    InboxType.nomination => Icons.how_to_reg,
    InboxType.result => Icons.scoreboard,
    InboxType.report => Icons.rate_review,
    InboxType.other => Icons.notifications,
  };
}

/// Ein persönlicher Posteingang-Eintrag für genau EINEN Trainer ([recipientId]).
/// Im Gegensatz zum team-weiten Aktivitäten-Feed ist dies pro Empfänger. Lokal
/// ohne `team_id` (Cache = meine Einträge); die Cloud-Zeile bekommt team_id.
class InboxMessage {
  final String id;

  /// Auth-User-ID des Empfängers (wem der Eintrag gehört).
  final String recipientId;

  /// Auth-User-ID des Auslösers (nullable).
  final String? actorId;

  /// Anzeigename des Auslösers zum Zeitpunkt der Aktion (denormalisiert).
  final String actorName;

  final InboxType type;
  final String title;
  final String? subtitle;

  /// Sprungziel beim Antippen (z.B. 'match'/'todo') + zugehörige ID.
  final String? linkType;
  final String? linkId;

  final DateTime createdAt;

  /// Zeitpunkt des Lesens (null = ungelesen).
  final DateTime? readAt;

  const InboxMessage({
    required this.id,
    required this.recipientId,
    this.actorId,
    required this.actorName,
    required this.type,
    required this.title,
    this.subtitle,
    this.linkType,
    this.linkId,
    required this.createdAt,
    this.readAt,
  });

  bool get unread => readAt == null;

  InboxMessage copyWith({DateTime? readAt}) => InboxMessage(
    id: id,
    recipientId: recipientId,
    actorId: actorId,
    actorName: actorName,
    type: type,
    title: title,
    subtitle: subtitle,
    linkType: linkType,
    linkId: linkId,
    createdAt: createdAt,
    readAt: readAt ?? this.readAt,
  );

  Map<String, Object?> toMap() => {
    'id': id,
    'recipient_id': recipientId,
    'actor_id': actorId,
    'actor_name': actorName,
    'type': type.storageKey,
    'title': title,
    'subtitle': subtitle,
    'link_type': linkType,
    'link_id': linkId,
    'created_at': createdAt.toIso8601String(),
    'read_at': readAt?.toIso8601String(),
  };

  factory InboxMessage.fromMap(Map<String, Object?> m) => InboxMessage(
    id: m['id'] as String,
    recipientId: (m['recipient_id'] as String?) ?? '',
    actorId: m['actor_id'] as String?,
    actorName: (m['actor_name'] as String?) ?? 'Trainer',
    type: InboxType.fromKey(m['type'] as String?),
    title: (m['title'] as String?) ?? '',
    subtitle: m['subtitle'] as String?,
    linkType: m['link_type'] as String?,
    linkId: m['link_id'] as String?,
    createdAt:
        DateTime.tryParse(m['created_at'] as String? ?? '') ?? DateTime.now(),
    readAt: DateTime.tryParse(m['read_at'] as String? ?? ''),
  );
}
