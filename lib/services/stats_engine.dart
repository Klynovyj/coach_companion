import '../models/enums.dart';
import '../models/match.dart';
import '../models/match_event.dart';
import '../models/peer_rating.dart';
import 'on_pitch_stats.dart';

/// Rechenkern des Statistik-Baukastens: reine Logik ohne UI, damit testbar.
///
/// Ablauf: [StatMatchData] je beendetem Spiel (Ereignisse, Startelf/Minuten,
/// Noten) → [MatchFilter] wählt die Spiele → [StatMetric]s rechnen je Spieler
/// bzw. Spiel → [subjectValue] fasst über Spiele (und Gruppen) zusammen.

enum StatTopic { players, matches }

/// Wie eine Gruppe ausgewertet wird.
enum GroupMode {
  sum('Summe'),
  avg('Schnitt je Spieler'),
  each('Jeder einzeln');

  const GroupMode(this.label);
  final String label;
}

/// Wie Werte über mehrere Spiele zusammengefasst werden.
enum MetricAgg {
  /// Zählwert: Summe über Spiele.
  sum,

  /// Schnittwert (z. B. Note): Mittel der vorhandenen Werte.
  mean,
}

// ---------------------------------------------------------------- Aktionen
/// Aktionen (Label → Ereignistypen) – gemeinsam für Saison-Statistik und
/// Baukasten.
const kStatActionRows = <(String, Set<MatchEventType>)>[
  ('Tore', {MatchEventType.goal, MatchEventType.penalty}),
  ('Eigentore', {MatchEventType.ownGoal}),
  ('Schüsse', {MatchEventType.shot}),
  ('Distanzschüsse', {MatchEventType.longShot}),
  ('Kopfbälle', {MatchEventType.header}),
  ('Großchancen', {MatchEventType.bigChance}),
  (
    'Elfmeter',
    {
      MatchEventType.penalty,
      MatchEventType.penaltyMissed,
      MatchEventType.penaltySaved,
    },
  ),
  ('Ecken', {MatchEventType.corner}),
  ('Freistöße', {MatchEventType.freeKick}),
  ('Fouls', {MatchEventType.foul}),
  ('Gelbe Karten', {MatchEventType.yellowCard}),
  ('Gelb-Rote Karten', {MatchEventType.secondYellow}),
  ('Rote Karten', {MatchEventType.redCard}),
  ('Paraden', {MatchEventType.save}),
  ('Meckern', {MatchEventType.meckern}),
  ('Behandlungen', {MatchEventType.injury}),
  ('Verletzt raus', {MatchEventType.injuredOff}),
  ('Wechsel', {MatchEventType.substitution}),
];

const _goalTypes = {MatchEventType.goal, MatchEventType.penalty};

// ------------------------------------------------------------- Spiel-Daten
/// Alle Daten eines beendeten Spiels für die Auswertung.
class StatMatchData {
  StatMatchData({
    required this.match,
    required List<MatchEvent> events,
    this.starters = const {},
    this.trainerRatings = const {},
    this.matchRatings = const [],
    this.peer,
  }) : events = [
         for (final e in events)
           if (e.matchId == match.id) e,
       ] {
    onPitch = starters.isEmpty
        ? null
        : analyzeOnPitch(match, this.events, starters);
    // HZ-Marken (früheste) für die Halbzeit-Zuordnung.
    for (final e in this.events) {
      if (e.type == MatchEventType.secondHalfStart) {
        if (_secondStart == null || e.createdAt.isBefore(_secondStart!)) {
          _secondStart = e.createdAt;
        }
      } else if (e.type == MatchEventType.halftime) {
        if (_halftime == null || e.createdAt.isBefore(_halftime!)) {
          _halftime = e.createdAt;
        }
      }
    }
  }

  final GameMatch match;
  final List<MatchEvent> events;

  /// Startelf (leer = keine freigegebene Aufstellung → keine Minuten).
  final Set<String> starters;

  /// Ø Trainer-Sterne je Spieler (1–5).
  final Map<String, double> trainerRatings;

  /// Abgegebene Spielnoten der Trainer (1–5).
  final List<double> matchRatings;

  /// Spieler-Bewertung per Link (nur geladen, wenn gebraucht).
  PeerSummary? peer;

  /// Besetzung/Minuten – null ohne Startelf.
  late final OnPitchMatch? onPitch;

  DateTime? _secondStart;
  DateTime? _halftime;

  String get ownId => match.ownTeamId;

  /// Live erfasst = mindestens eine Phasen-Marke (wie Saison-Statistik).
  bool get tracked => events.any((e) => e.type.isPhaseMarker);

  /// 'W', 'D' oder 'L'.
  String get result => match.ownScore > match.opponentScore
      ? 'W'
      : match.ownScore < match.opponentScore
      ? 'L'
      : 'D';

  /// Halbzeit eines Ereignisses: 1 oder 2 (Phasen-Marken, sonst Minute).
  int halfOf(MatchEvent e) {
    if (_secondStart != null) {
      return e.createdAt.isBefore(_secondStart!) ? 1 : 2;
    }
    if (_halftime != null) return e.createdAt.isAfter(_halftime!) ? 2 : 1;
    return e.minute <= 45 ? 1 : 2;
  }

  /// 15-Minuten-Abschnitt 0–5 (Nachspielzeit zählt zum letzten Abschnitt
  /// der jeweiligen Halbzeit).
  int bucketOf(MatchEvent e) {
    if (halfOf(e) == 1) {
      final m = e.minute < 1 ? 1 : e.minute;
      return ((m - 1) ~/ 15).clamp(0, 2);
    }
    final m = e.minute < 46 ? 46 : e.minute;
    return 3 + ((m - 46) ~/ 15).clamp(0, 2);
  }

  /// Tor-Ereignisse: (Ereignis, für uns?).
  Iterable<(MatchEvent, bool)> get goalEvents sync* {
    for (final e in events) {
      final own = e.teamId == ownId;
      if (_goalTypes.contains(e.type)) yield (e, own);
      if (e.type == MatchEventType.ownGoal) yield (e, !own);
    }
  }

  bool played(String playerId) => onPitch?.played(playerId) ?? false;
}

// ---------------------------------------------------------------- Filter
/// Auswahl der Spiele – alle Kriterien kombinierbar.
class MatchFilter {
  MatchFilter({
    Set<String>? excluded,
    this.period = 'all',
    this.from,
    this.to,
    this.venue,
    Set<String>? competitions,
    Set<String>? results,
    Set<String>? opponents,
    this.trackedOnly = false,
  }) : excluded = excluded ?? {},
       competitions = competitions ?? {},
       results = results ?? {},
       opponents = opponents ?? {};

  /// Einzeln abgewählte Spiele.
  Set<String> excluded;

  /// 'all', 'season', 'first' (Hinrunde), 'second' (Rückrunde), 'custom'.
  String period;
  DateTime? from;
  DateTime? to;

  /// null = Heim und Auswärts.
  Venue? venue;

  /// Leer = alle.
  Set<String> competitions;

  /// 'W'/'D'/'L' – leer = alle.
  Set<String> results;

  /// Gegnernamen – leer = alle.
  Set<String> opponents;

  /// Nur live erfasste Spiele.
  bool trackedOnly;

  static const periodLabels = {
    'all': 'Alle',
    'season': 'Saison',
    'first': 'Hinrunde',
    'second': 'Rückrunde',
    'custom': 'Zeitraum',
  };

  /// Startjahr der Saison (Juli–Juni) eines Datums.
  static int seasonOf(DateTime d) => d.month >= 7 ? d.year : d.year - 1;

  /// Zeitraum-Grenzen (inklusive) für [seasonStart]; null = offen.
  (DateTime?, DateTime?) range(int seasonStart) {
    switch (period) {
      case 'season':
        return (DateTime(seasonStart, 7), DateTime(seasonStart + 1, 7));
      case 'first':
        return (DateTime(seasonStart, 7), DateTime(seasonStart + 1, 1));
      case 'second':
        return (DateTime(seasonStart + 1, 1), DateTime(seasonStart + 1, 7));
      case 'custom':
        return (from, to?.add(const Duration(days: 1)));
      default:
        return (null, null);
    }
  }

  /// Passt das Spiel zu allen Kriterien außer der Einzel-Abwahl?
  bool matchesCriteria(StatMatchData d, int seasonStart) {
    final m = d.match;
    if (trackedOnly && !d.tracked) return false;
    final (a, b) = range(seasonStart);
    if (a != null || b != null) {
      final k = m.kickoff;
      if (k == null) return false;
      if (a != null && k.isBefore(a)) return false;
      if (b != null && !k.isBefore(b)) return false;
    }
    if (venue != null && m.venue != venue) return false;
    if (competitions.isNotEmpty &&
        !competitions.contains(m.competition ?? '')) {
      return false;
    }
    if (results.isNotEmpty && !results.contains(d.result)) return false;
    if (opponents.isNotEmpty && !opponents.contains(m.opponentName)) {
      return false;
    }
    return true;
  }

  bool matches(StatMatchData d, int seasonStart) =>
      !excluded.contains(d.match.id) && matchesCriteria(d, seasonStart);

  List<StatMatchData> apply(List<StatMatchData> all, int seasonStart) => [
    for (final d in all)
      if (matches(d, seasonStart)) d,
  ];

  bool get isDefault =>
      excluded.isEmpty &&
      period == 'all' &&
      venue == null &&
      competitions.isEmpty &&
      results.isEmpty &&
      opponents.isEmpty &&
      !trackedOnly;

  Map<String, dynamic> toJson() => {
    'excluded': excluded.toList(),
    'period': period,
    'from': from?.toIso8601String(),
    'to': to?.toIso8601String(),
    'venue': venue?.storageKey,
    'competitions': competitions.toList(),
    'results': results.toList(),
    'opponents': opponents.toList(),
    'trackedOnly': trackedOnly,
  };

  static Set<String> _set(Object? v) =>
      v is List ? {for (final e in v) e.toString()} : <String>{};

  factory MatchFilter.fromJson(Map<String, dynamic>? j) {
    if (j == null) return MatchFilter();
    final v = j['venue'] as String?;
    return MatchFilter(
      excluded: _set(j['excluded']),
      period: (j['period'] as String?) ?? 'all',
      from: DateTime.tryParse((j['from'] as String?) ?? ''),
      to: DateTime.tryParse((j['to'] as String?) ?? ''),
      venue: v == null
          ? null
          : Venue.values.where((x) => x.storageKey == v).firstOrNull,
      competitions: _set(j['competitions']),
      results: _set(j['results']),
      opponents: _set(j['opponents']),
      trackedOnly: j['trackedOnly'] == true,
    );
  }

  MatchFilter copy() => MatchFilter.fromJson(toJson());
}

// -------------------------------------------------------------- Kennzahlen
typedef PlayerFn = num? Function(String playerId, StatMatchData d);
typedef MatchFn = num? Function(StatMatchData d);

/// Eine wählbare Kennzahl.
class StatMetric {
  const StatMetric({
    required this.id,
    required this.label,
    required this.short,
    required this.section,
    required this.topic,
    this.agg = MetricAgg.sum,
    this.per90able = false,
    this.decimals = 0,
    this.needsPeer = false,
    this.player,
    this.match,
  });

  final String id;
  final String label;

  /// Kurz für Tabellenköpfe.
  final String short;

  /// Abschnitt in der Auswahl (z. B. „Einsätze").
  final String section;
  final StatTopic topic;
  final MetricAgg agg;

  /// Darf „je 90 Min." gerechnet werden (Zählwerte von Spielern).
  final bool per90able;
  final int decimals;

  /// Braucht die Spieler-Bewertung per Link (Cloud).
  final bool needsPeer;
  final PlayerFn? player;
  final MatchFn? match;
}

bool _own(MatchEvent e, StatMatchData d) => e.teamId == d.ownId;

/// Zählt eigene Ereignisse eines Spielers (Hauptspieler).
PlayerFn _countPlayer(Set<MatchEventType> types) => (p, d) {
  var n = 0;
  for (final e in d.events) {
    if (e.playerId == p && types.contains(e.type) && _own(e, d)) n++;
  }
  return n;
};

int _countTeam(StatMatchData d, Set<MatchEventType> types, bool own) {
  var n = 0;
  for (final e in d.events) {
    if (types.contains(e.type) && _own(e, d) == own) n++;
  }
  return n;
}

num? _onPitchSplit(StatMatchData d, String p, int part) {
  final op = d.onPitch;
  if (op == null) return null;
  final s = op.split(p);
  return switch (part) {
    0 => s.$1,
    1 => s.$2,
    2 => s.$1 - s.$2,
    _ => s.$3 - s.$4,
  };
}

const _bucketLabels = ['1–15', '16–30', '31–45', '46–60', '61–75', '76–90'];

final List<StatMetric> kStatMetrics = _buildMetrics();

final Map<String, StatMetric> kStatMetricById = {
  for (final m in kStatMetrics) m.id: m,
};

List<StatMetric> _buildMetrics() {
  final list = <StatMetric>[];
  const pl = StatTopic.players, ma = StatTopic.matches;

  // ---- Spieler: Einsätze
  list.addAll([
    StatMetric(
      id: 'p_games',
      label: 'Spiele',
      short: 'Sp.',
      section: 'Einsätze',
      topic: pl,
      player: (p, d) => d.onPitch == null ? null : (d.played(p) ? 1 : 0),
    ),
    StatMetric(
      id: 'p_starts',
      label: 'Startelf',
      short: 'Start',
      section: 'Einsätze',
      topic: pl,
      player: (p, d) =>
          d.onPitch == null ? null : (d.starters.contains(p) ? 1 : 0),
    ),
    StatMetric(
      id: 'p_subin',
      label: 'Einwechslungen',
      short: 'Ein',
      section: 'Einsätze',
      topic: pl,
      player: (p, d) => d.onPitch == null
          ? null
          : (d.played(p) && !d.starters.contains(p) ? 1 : 0),
    ),
    StatMetric(
      id: 'p_minutes',
      label: 'Minuten',
      short: 'Min.',
      section: 'Einsätze',
      topic: pl,
      player: (p, d) => d.onPitch == null ? null : (d.onPitch!.minutes[p] ?? 0),
    ),
  ]);

  // ---- Spieler: Aktionen
  StatMetric act(String id, String label, String short, PlayerFn fn) =>
      StatMetric(
        id: id,
        label: label,
        short: short,
        section: 'Aktionen',
        topic: pl,
        per90able: true,
        player: fn,
      );
  final goals = _countPlayer(_goalTypes);
  num assists(String p, StatMatchData d) {
    var n = 0;
    for (final e in d.events) {
      if (_goalTypes.contains(e.type) && e.assistPlayerId == p && _own(e, d)) {
        n++;
      }
    }
    return n;
  }

  list.addAll([
    act('p_goals', 'Tore', 'Tore', goals),
    act('p_assists', 'Vorlagen', 'Vorl.', assists),
    act(
      'p_scorer',
      'Scorerpunkte',
      'Scorer',
      (p, d) => goals(p, d)! + assists(p, d),
    ),
    act(
      'p_pengoals',
      'Elfmetertore',
      'Elf-Tor',
      _countPlayer({MatchEventType.penalty}),
    ),
    act(
      'p_penmiss',
      'Elfmeter verschossen',
      'Elf-X',
      _countPlayer({MatchEventType.penaltyMissed}),
    ),
    act('p_shots', 'Schüsse', 'Schüsse', _countPlayer({MatchEventType.shot})),
    act(
      'p_longshots',
      'Distanzschüsse',
      'Distanz',
      _countPlayer({MatchEventType.longShot}),
    ),
    act(
      'p_headers',
      'Kopfbälle',
      'Kopfb.',
      _countPlayer({MatchEventType.header}),
    ),
    act(
      'p_chances',
      'Großchancen',
      'Chancen',
      _countPlayer({MatchEventType.bigChance}),
    ),
    act('p_fouls', 'Fouls', 'Fouls', _countPlayer({MatchEventType.foul})),
    act(
      'p_meckern',
      'Meckern',
      'Meckern',
      _countPlayer({MatchEventType.meckern}),
    ),
    act(
      'p_yellow',
      'Gelbe Karten',
      'Gelb',
      _countPlayer({MatchEventType.yellowCard}),
    ),
    act(
      'p_yellowred',
      'Gelb-Rote Karten',
      'G-R',
      _countPlayer({MatchEventType.secondYellow}),
    ),
    act('p_red', 'Rote Karten', 'Rot', _countPlayer({MatchEventType.redCard})),
    act('p_saves', 'Paraden', 'Paraden', _countPlayer({MatchEventType.save})),
  ]);

  // ---- Spieler: Bewertungen
  list.addAll([
    StatMetric(
      id: 'p_trainer',
      label: 'Ø Trainer-Bewertung (Sterne)',
      short: 'Ø Trainer',
      section: 'Bewertungen',
      topic: pl,
      agg: MetricAgg.mean,
      decimals: 2,
      player: (p, d) => d.trainerRatings[p],
    ),
    StatMetric(
      id: 'p_peer',
      label: 'Ø Spieler-Bewertung (Team)',
      short: 'Ø Team',
      section: 'Bewertungen',
      topic: pl,
      agg: MetricAgg.mean,
      decimals: 2,
      needsPeer: true,
      player: (p, d) => d.peer?.avg[p]?.$1,
    ),
    StatMetric(
      id: 'p_motm',
      label: 'Spieler des Spiels',
      short: 'SdS',
      section: 'Bewertungen',
      topic: pl,
      needsPeer: true,
      player: (p, d) {
        final pe = d.peer;
        if (pe == null) return null;
        return pe.podium.any((x) => x.$1 == p && x.$3 == 1) ? 1 : 0;
      },
    ),
  ]);

  // ---- Spieler: Auf dem Feld
  StatMetric onp(String id, String label, String short, int part) => StatMetric(
    id: id,
    label: label,
    short: short,
    section: 'Auf dem Feld',
    topic: pl,
    per90able: part < 3,
    player: (p, d) => _onPitchSplit(d, p, part),
  );
  list.addAll([
    onp('p_on_for', 'Tore mit ihm', 'Tore mit', 0),
    onp('p_on_against', 'Gegentore mit ihm', 'Gegent. mit', 1),
    onp('p_on_diff', '+/- mit ihm', '+/- mit', 2),
    onp('p_off_diff', '+/- ohne ihn', '+/- ohne', 3),
  ]);

  // ---- Spiele: Bilanz
  StatMetric bil(String id, String label, String short, MatchFn fn) =>
      StatMetric(
        id: id,
        label: label,
        short: short,
        section: 'Bilanz',
        topic: ma,
        match: fn,
      );
  list.addAll([
    bil('m_win', 'Siege', 'S', (d) => d.result == 'W' ? 1 : 0),
    bil('m_draw', 'Unentschieden', 'U', (d) => d.result == 'D' ? 1 : 0),
    bil('m_loss', 'Niederlagen', 'N', (d) => d.result == 'L' ? 1 : 0),
    bil(
      'm_points',
      'Punkte',
      'Pkt.',
      (d) => d.result == 'W' ? 3 : (d.result == 'D' ? 1 : 0),
    ),
    bil('m_for', 'Tore', 'Tore', (d) => d.match.ownScore),
    bil('m_against', 'Gegentore', 'Gegent.', (d) => d.match.opponentScore),
    bil(
      'm_diff',
      'Tordifferenz',
      'Diff.',
      (d) => d.match.ownScore - d.match.opponentScore,
    ),
    bil(
      'm_clean',
      'Zu Null',
      'zu 0',
      (d) => d.match.opponentScore == 0 ? 1 : 0,
    ),
  ]);

  // ---- Spiele: Aktionen wir vs. Gegner
  for (final (label, types) in kStatActionRows) {
    if (label == 'Tore') continue; // steht in der Bilanz
    final key = types.first.storageKey;
    for (final own in [true, false]) {
      list.add(
        StatMetric(
          id: 'm_act_${key}_${own ? 'us' : 'opp'}',
          label: '$label (${own ? 'wir' : 'Gegner'})',
          short: '$label ${own ? 'wir' : 'Geg.'}',
          section: 'Aktionen',
          topic: ma,
          match: (d) => d.tracked ? _countTeam(d, types, own) : null,
        ),
      );
    }
  }

  // ---- Spiele: Torzeitpunkte
  for (var b = 0; b < 6; b++) {
    for (final forUs in [true, false]) {
      list.add(
        StatMetric(
          id: 'm_goal_b${b}_${forUs ? 'for' : 'against'}',
          label: '${forUs ? 'Tore' : 'Gegentore'} ${_bucketLabels[b]}. Min.',
          short: '${forUs ? 'T' : 'GT'} ${_bucketLabels[b]}',
          section: 'Torzeitpunkte',
          topic: ma,
          match: (d) {
            if (!d.tracked) return null;
            var n = 0;
            for (final (e, f) in d.goalEvents) {
              if (f == forUs && d.bucketOf(e) == b) n++;
            }
            return n;
          },
        ),
      );
    }
  }
  for (final half in [1, 2]) {
    for (final forUs in [true, false]) {
      list.add(
        StatMetric(
          id: 'm_goal_h${half}_${forUs ? 'for' : 'against'}',
          label: '${forUs ? 'Tore' : 'Gegentore'} $half. Halbzeit',
          short: '${forUs ? 'T' : 'GT'} $half. HZ',
          section: 'Torzeitpunkte',
          topic: ma,
          match: (d) {
            if (!d.tracked) return null;
            var n = 0;
            for (final (e, f) in d.goalEvents) {
              if (f == forUs && d.halfOf(e) == half) n++;
            }
            return n;
          },
        ),
      );
    }
  }

  // ---- Spiele: Noten
  list.addAll([
    StatMetric(
      id: 'm_rating',
      label: 'Ø Spielnote Trainer (Sterne)',
      short: 'Ø Note',
      section: 'Noten',
      topic: ma,
      agg: MetricAgg.mean,
      decimals: 2,
      match: (d) => d.matchRatings.isEmpty
          ? null
          : d.matchRatings.reduce((a, b) => a + b) / d.matchRatings.length,
    ),
    StatMetric(
      id: 'm_peer',
      label: 'Ø Spielnote Team (Sterne)',
      short: 'Ø Team',
      section: 'Noten',
      topic: ma,
      agg: MetricAgg.mean,
      decimals: 2,
      needsPeer: true,
      match: (d) => d.peer?.matchAvg,
    ),
  ]);
  return list;
}

// ------------------------------------------------------------- Auswertung
/// Ein Auswertungs-Subjekt: ein Spieler oder eine Gruppe.
class StatSubject {
  const StatSubject({
    required this.key,
    required this.label,
    required this.playerIds,
    this.isGroup = false,
  });

  final String key;
  final String label;
  final List<String> playerIds;
  final bool isGroup;
}

/// Wert einer Kennzahl für einen Spieler über [matches]; null = keine Daten.
num? playerValue(
  StatMetric m,
  String playerId,
  List<StatMatchData> matches, {
  bool per90 = false,
}) {
  final fn = m.player;
  if (fn == null) return null;
  num sum = 0;
  var n = 0;
  for (final d in matches) {
    final v = fn(playerId, d);
    if (v == null) continue;
    sum += v;
    n++;
  }
  if (n == 0) return null;
  if (m.agg == MetricAgg.mean) return sum / n;
  if (per90 && m.per90able) {
    final min = playerMinutes(playerId, matches);
    return min > 0 ? sum * 90 / min : null;
  }
  return sum;
}

/// Gespielte Minuten eines Spielers (nur Spiele mit Startelf).
int playerMinutes(String playerId, List<StatMatchData> matches) {
  var min = 0;
  for (final d in matches) {
    min += d.onPitch?.minutes[playerId] ?? 0;
  }
  return min;
}

/// Wert für ein Subjekt. Gruppen: Summe bzw. Schnitt der Mitglieder; bei
/// Schnittwerten (Noten) immer der Mittelwert der Mitglieder mit Wert.
/// „je 90" bei Summe = Gruppen-Gesamt je 90 gespielte Minuten.
num? subjectValue(
  StatMetric m,
  StatSubject s,
  List<StatMatchData> matches, {
  GroupMode mode = GroupMode.sum,
  bool per90 = false,
}) {
  if (!s.isGroup || s.playerIds.length == 1) {
    if (s.playerIds.isEmpty) return null;
    return playerValue(m, s.playerIds.first, matches, per90: per90);
  }
  if (s.playerIds.isEmpty) return null;
  if (m.agg == MetricAgg.sum && per90 && m.per90able && mode == GroupMode.sum) {
    num total = 0;
    var min = 0;
    for (final p in s.playerIds) {
      total += playerValue(m, p, matches) ?? 0;
      min += playerMinutes(p, matches);
    }
    return min > 0 ? total * 90 / min : null;
  }
  final vals = [
    for (final p in s.playerIds) ?playerValue(m, p, matches, per90: per90),
  ];
  if (vals.isEmpty) return null;
  final sum = vals.fold<num>(0, (a, b) => a + b);
  if (m.agg == MetricAgg.mean || mode == GroupMode.avg) {
    return sum / vals.length;
  }
  return sum;
}

/// Verlauf: Wert des Subjekts je Spiel (in der Reihenfolge von [matches]).
List<num?> subjectSeries(
  StatMetric m,
  StatSubject s,
  List<StatMatchData> matches, {
  GroupMode mode = GroupMode.sum,
  bool per90 = false,
}) => [
  for (final d in matches) subjectValue(m, s, [d], mode: mode, per90: per90),
];

/// Wert einer Spiel-Kennzahl für ein Spiel.
num? matchValue(StatMetric m, StatMatchData d) => m.match?.call(d);

/// Zusammenfassung einer Spiel-Kennzahl über Spiele: (Summe bzw. Schnitt,
/// Schnitt je Spiel). Bei Schnittwerten sind beide gleich.
(num?, num?) matchSummary(StatMetric m, List<StatMatchData> matches) {
  num sum = 0;
  var n = 0;
  for (final d in matches) {
    final v = matchValue(m, d);
    if (v == null) continue;
    sum += v;
    n++;
  }
  if (n == 0) return (null, null);
  final avg = sum / n;
  return (m.agg == MetricAgg.mean ? avg : sum, avg);
}

/// Formatiert einen Wert (Komma als Dezimaltrenner, „–" für keine Daten).
String formatStat(num? v, {int decimals = 0}) {
  if (v == null) return '–';
  if (decimals == 0 && v == v.roundToDouble()) return v.round().toString();
  final d = decimals == 0 ? 2 : decimals;
  return v.toStringAsFixed(d).replaceAll('.', ',');
}

// ------------------------------------------------------------- Positionen
/// Automatische Positionsgruppen (Kürzel aus `kPositionOptions`).
const kPositionGroups = <(String, String, Set<String>)>[
  ('pos:tw', 'Torwart', {'TW'}),
  ('pos:abw', 'Abwehr', {'IV', 'LV', 'RV'}),
  ('pos:mf', 'Mittelfeld', {'DM', 'ZM', 'OM', 'LM', 'RM', '6', '8', '10'}),
  ('pos:st', 'Sturm', {'LA', 'RA', 'ST'}),
];

/// Hauptposition eines Spielers → Positionsgruppen-Schlüssel (oder null).
/// Erste passende Position gewinnt; freie Texte werden grob zugeordnet.
String? positionGroupOf(List<String> positions, String? position) {
  final all = [...positions, ?position];
  for (final raw in all) {
    final p = raw.trim().toUpperCase();
    for (final (key, _, set) in kPositionGroups) {
      if (set.contains(p)) return key;
    }
    final l = raw.toLowerCase();
    if (l.contains('tor')) return 'pos:tw';
    if (l.contains('abwehr') || l.contains('verteid')) return 'pos:abw';
    if (l.contains('mittel')) return 'pos:mf';
    if (l.contains('sturm') || l.contains('angriff')) return 'pos:st';
  }
  return null;
}
