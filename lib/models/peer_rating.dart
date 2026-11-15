import 'dart:math';

/// Bewertung durch Spieler ohne App-Zugang (Web-Link je Spieler, Cloud-Stufe 59).

/// Adresse der Bewertungs-Webseite (GitHub Pages).
const kPeerRatingBaseUrl =
    'https://klynovyj.github.io/coach_companion/bewerten/';

/// Persönlicher, dauerhafter Bewertungs-Link eines Spielers. Der Token steht
/// hinter `#`, damit er nicht in Server-Protokollen landet.
String peerRatingLink(String token) => '$kPeerRatingBaseUrl#t=$token';

const _tokenChars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';

/// Neuer zufälliger Token (24 Zeichen, ~138 Bit).
String newPeerToken([Random? random]) {
  final r = random ?? Random.secure();
  return List.generate(
    24,
    (_) => _tokenChars[r.nextInt(_tokenChars.length)],
  ).join();
}

/// Spieler einer Bewertungsrunde (mit Einsatz im Spiel).
class PeerRoundPlayer {
  const PeerRoundPlayer({required this.id, required this.name, this.number});

  final String id;
  final String name;
  final int? number;

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'number': number};

  factory PeerRoundPlayer.fromJson(Map<String, dynamic> m) => PeerRoundPlayer(
    id: m['id'].toString(),
    name: (m['name'] as String?) ?? '',
    number: (m['number'] as num?)?.toInt(),
  );
}

/// Selbsteinschätzung eines Spielers in einem Spiel.
class PeerSelf {
  const PeerSelf({required this.playerId, this.stars, this.note});

  final String playerId;
  final int? stars;
  final String? note;

  factory PeerSelf.fromJson(Map<String, dynamic> m) => PeerSelf(
    playerId: m['id'].toString(),
    stars: (m['stars'] as num?)?.toInt(),
    note: m['note'] as String?,
  );
}

/// Auswertung der Spieler-Bewertung eines Spiels (nur Schnitte, anonym).
class PeerSummary {
  const PeerSummary({
    required this.matchId,
    required this.closesAt,
    required this.open,
    required this.players,
    required this.voters,
    required this.avg,
    required this.motm,
    this.matchAvg,
    this.matchCount = 0,
    this.matchNotes = const [],
    this.self = const [],
  });

  final String matchId;
  final DateTime closesAt;
  final bool open;
  final List<PeerRoundPlayer> players;

  /// Spieler, die abgestimmt haben.
  final Set<String> voters;

  /// Mannschafts-Schnitt je Spieler: (Schnitt, Anzahl Stimmen).
  final Map<String, (double, int)> avg;

  /// Spieler-des-Spiels-Stimmen, absteigend: (Spieler-ID, Stimmen).
  final List<(String, int)> motm;

  final double? matchAvg;
  final int matchCount;
  final List<String> matchNotes;
  final List<PeerSelf> self;

  /// Spieler der Runde, die noch nicht abgestimmt haben.
  List<PeerRoundPlayer> get missing => [
    for (final p in players)
      if (!voters.contains(p.id)) p,
  ];

  factory PeerSummary.fromJson(Map<String, dynamic> m) {
    final avgRaw = m['avg'];
    return PeerSummary(
      matchId: m['match_id'].toString(),
      closesAt:
          DateTime.tryParse(m['closes_at']?.toString() ?? '') ?? DateTime.now(),
      open: m['open'] == true,
      players: [
        for (final p in (m['players'] as List? ?? const []))
          if (p is Map) PeerRoundPlayer.fromJson(Map<String, dynamic>.from(p)),
      ],
      voters: {
        for (final v in (m['voters'] as List? ?? const [])) v.toString(),
      },
      avg: {
        if (avgRaw is Map)
          for (final e in avgRaw.entries)
            if (e.value is Map)
              e.key.toString(): (
                ((e.value as Map)['avg'] as num?)?.toDouble() ?? 0,
                ((e.value as Map)['n'] as num?)?.toInt() ?? 0,
              ),
      },
      motm: [
        for (final v in (m['motm'] as List? ?? const []))
          if (v is Map)
            (v['id'].toString(), (v['votes'] as num?)?.toInt() ?? 0),
      ],
      matchAvg: (m['match_avg'] as num?)?.toDouble(),
      matchCount: (m['match_n'] as num?)?.toInt() ?? 0,
      matchNotes: [
        for (final n in (m['match_notes'] as List? ?? const []))
          if (n is String && n.trim().isNotEmpty) n.trim(),
      ],
      self: [
        for (final s in (m['self'] as List? ?? const []))
          if (s is Map) PeerSelf.fromJson(Map<String, dynamic>.from(s)),
      ],
    );
  }
}

/// Eintrag im Verlauf der Selbsteinschätzung eines Spielers.
class PeerSelfEntry {
  const PeerSelfEntry({
    required this.matchId,
    required this.title,
    this.matchDate,
    this.stars,
    this.note,
  });

  final String matchId;
  final String title;
  final DateTime? matchDate;
  final int? stars;
  final String? note;

  factory PeerSelfEntry.fromJson(Map<String, dynamic> m) => PeerSelfEntry(
    matchId: m['match_id'].toString(),
    title: (m['title'] as String?) ?? '',
    matchDate: DateTime.tryParse(m['match_date']?.toString() ?? ''),
    stars: (m['stars'] as num?)?.toInt(),
    note: (m['note'] as String?)?.trim(),
  );
}

/// Persönlicher Bewertungs-Link eines Trainers (Trainer-Seite, Stufe 60).
String coachRatingLink(String token) =>
    '${kPeerRatingBaseUrl}trainer.html#t=$token';

/// Bewerter-ID für Trainer/Betreuer aus dem Kader ohne App-Konto.
String staffRaterId(String playerId) => 'staff:$playerId';
