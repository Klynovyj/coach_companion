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
  final double? stars;
  final String? note;

  factory PeerSelf.fromJson(Map<String, dynamic> m) => PeerSelf(
    playerId: m['id'].toString(),
    stars: (m['stars'] as num?)?.toDouble(),
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
    this.podium = const [],
    this.podiumSource = 'trainer',
  });

  /// Podest nach Sternen: (Spieler-ID, Schnitt, Platz 1–3; Gleichstand teilt).
  final List<(String, double, int)> podium;

  /// Grundlage des Podests: 'trainer' oder 'team'.
  final String podiumSource;

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
      podium: [
        if (m['podium'] is Map)
          for (final e
              in ((m['podium'] as Map)['ranking'] as List? ?? const []))
            if (e is Map)
              (
                e['id'].toString(),
                (e['avg'] as num?)?.toDouble() ?? 0,
                (e['place'] as num?)?.toInt() ?? 0,
              ),
      ],
      podiumSource: m['podium'] is Map
          ? ((m['podium'] as Map)['source'] as String? ?? 'trainer')
          : 'trainer',
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
  final double? stars;
  final String? note;

  factory PeerSelfEntry.fromJson(Map<String, dynamic> m) => PeerSelfEntry(
    matchId: m['match_id'].toString(),
    title: (m['title'] as String?) ?? '',
    matchDate: DateTime.tryParse(m['match_date']?.toString() ?? ''),
    stars: (m['stars'] as num?)?.toDouble(),
    note: (m['note'] as String?)?.trim(),
  );
}

/// Persönlicher Bewertungs-Link eines Trainers (Trainer-Seite, Stufe 60).
String coachRatingLink(String token) =>
    '${kPeerRatingBaseUrl}trainer.html#t=$token';

/// Gehört ein App-Konto (Anzeigename/E-Mail) zu einer Person aus dem Kader?
/// Treffer bei gleichem Namen, wenn der E-Mail-Teil vor dem @ den Nachnamen
/// (≥ 4 Zeichen) enthält oder mit dem ersten Teil des Vornamens (≥ 3 Zeichen)
/// beginnt – z. B. „a.chenfeld" ↔ Andrej Chenfeld, „jan…" ↔ Jan-Niklas Ped.
bool accountMatchesPerson({
  required String displayName,
  required String email,
  required String firstName,
  required String lastName,
}) {
  String norm(String s) => s
      .toLowerCase()
      .replaceAll('ä', 'ae')
      .replaceAll('ö', 'oe')
      .replaceAll('ü', 'ue')
      .replaceAll('ß', 'ss')
      .replaceAll(RegExp(r'[^a-z0-9]'), '');
  final full = norm('$firstName $lastName');
  if (full.isNotEmpty && norm(displayName) == full) return true;
  final local = norm(email.split('@').first);
  if (local.isEmpty) return false;
  final last = norm(lastName);
  if (last.length >= 4 && local.contains(last)) return true;
  final first = norm(firstName.split(RegExp(r'[\s-]')).first);
  return first.length >= 3 && local.startsWith(first);
}

/// Bewerter-ID für Trainer/Betreuer aus dem Kader ohne App-Konto.
String staffRaterId(String playerId) => 'staff:$playerId';

/// Abstimm-Übersicht eines Spiels (Trainer + Mannschaft, Stufe 66).
class PeerOverview {
  const PeerOverview({
    required this.matchId,
    required this.open,
    this.closesAt,
    this.coachAvg,
    this.coachN = 0,
    this.coachDone = 0,
    this.coachTotal = 0,
    this.teamAvg,
    this.teamN = 0,
    this.voters = 0,
    this.players = 0,
    this.motmId,
    this.motmName,
    this.motmVotes = 0,
    this.motmAvg,
    this.motmTie = 1,
  });

  /// Schnitt des Besten (Podest nach Sternen) und Anzahl gleichauf.
  final double? motmAvg;
  final int motmTie;

  final String matchId;
  final bool open;
  final DateTime? closesAt;
  final double? coachAvg;
  final int coachN;
  final int coachDone;
  final int coachTotal;
  final double? teamAvg;
  final int teamN;
  final int voters;
  final int players;
  final String? motmId;
  final String? motmName;
  final int motmVotes;

  factory PeerOverview.fromJson(Map<String, dynamic> m) {
    final motm = m['motm'];
    return PeerOverview(
      matchId: m['match_id'].toString(),
      open: m['open'] == true,
      closesAt: DateTime.tryParse(m['closes_at']?.toString() ?? ''),
      coachAvg: (m['coach_avg'] as num?)?.toDouble(),
      coachN: (m['coach_n'] as num?)?.toInt() ?? 0,
      coachDone: (m['coach_done'] as num?)?.toInt() ?? 0,
      coachTotal: (m['coach_total'] as num?)?.toInt() ?? 0,
      teamAvg: (m['team_avg'] as num?)?.toDouble(),
      teamN: (m['team_n'] as num?)?.toInt() ?? 0,
      voters: (m['voters'] as num?)?.toInt() ?? 0,
      players: (m['players'] as num?)?.toInt() ?? 0,
      motmId: motm is Map ? motm['id']?.toString() : null,
      motmName: motm is Map ? motm['name'] as String? : null,
      motmVotes: motm is Map ? (motm['votes'] as num?)?.toInt() ?? 0 : 0,
      motmAvg: motm is Map ? (motm['avg'] as num?)?.toDouble() : null,
      motmTie: motm is Map ? (motm['tie'] as num?)?.toInt() ?? 1 : 1,
    );
  }
}

/// Einzelne Trainer-Stimme eines Spiels (App oder Trainer-Link, Stufe 66).
class CoachVote {
  const CoachVote({
    required this.raterId,
    required this.name,
    this.photo,
    this.matchStars,
    this.abstained = false,
    this.note,
    this.motmPlayerId,
    this.stars = const {},
  });

  final String raterId;
  final String name;

  /// Kader-Foto als Data-URL (nur bei Trainern aus dem Kader).
  final String? photo;
  final double? matchStars;
  final bool abstained;
  final String? note;
  final String? motmPlayerId;
  final Map<String, double> stars;

  factory CoachVote.fromJson(Map<String, dynamic> m) {
    final st = m['stars'];
    return CoachVote(
      raterId: m['rater_id'].toString(),
      name: (m['name'] as String?) ?? 'Trainer',
      photo: m['photo'] as String?,
      matchStars: (m['match_stars'] as num?)?.toDouble(),
      abstained: m['abstained'] == true,
      note: m['note'] as String?,
      motmPlayerId: m['motm_player_id']?.toString(),
      stars: {
        if (st is Map)
          for (final e in st.entries)
            if (e.value is num) e.key.toString(): (e.value as num).toDouble(),
      },
    );
  }
}

/// Stand der Kürung „Spieler des Monats" (alle Trainer müssen zustimmen).
class CrownState {
  const CrownState({
    required this.yearMonth,
    this.me,
    this.required = const [],
    this.counts = const {},
    this.crowned,
    this.leaders = const [],
  });

  final String yearMonth;

  /// Eigene Bewerter-ID (App-Konto).
  final String? me;

  /// Pflicht-Trainer: (Bewerter-ID, Name, gewählter Spieler oder null).
  final List<(String, String, String?)> required;

  /// Zustimmungen je Spieler.
  final Map<String, int> counts;

  /// Fest gekürter Spieler (alle haben zugestimmt) oder null.
  final String? crowned;

  /// Platz 1 der Monats-Rangliste (voraussichtlich; Gleichstand = mehrere).
  final List<String> leaders;

  String? get myVote {
    for (final r in required) {
      if (r.$1 == me) return r.$3;
    }
    return null;
  }

  factory CrownState.fromJson(Map<String, dynamic> m) {
    final st = m['state'] is Map ? Map<String, dynamic>.from(m['state']) : m;
    final counts = st['counts'];
    return CrownState(
      yearMonth: (st['year_month'] ?? '').toString(),
      me: m['me']?.toString(),
      required: [
        for (final r in (st['required'] as List? ?? const []))
          if (r is Map)
            (
              r['rater_id'].toString(),
              (r['name'] as String?) ?? 'Trainer',
              r['player_id']?.toString(),
            ),
      ],
      counts: {
        if (counts is Map)
          for (final e in counts.entries)
            if (e.value is num) e.key.toString(): (e.value as num).toInt(),
      },
      crowned: st['crowned']?.toString(),
      leaders: [
        for (final l in (st['leaders'] as List? ?? const [])) l.toString(),
      ],
    );
  }
}
