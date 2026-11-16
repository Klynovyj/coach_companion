import '../models/enums.dart';
import '../models/match.dart';
import '../models/match_event.dart';

/// Ein Tor bzw. Gegentor mit der Besetzung, die in dem Moment auf dem Feld
/// stand.
class OnPitchGoal {
  const OnPitchGoal({
    required this.event,
    required this.forUs,
    required this.onPitch,
  });

  final MatchEvent event;

  /// true = Tor für uns, false = Gegentor.
  final bool forUs;

  /// Eigene Spieler, die beim Tor auf dem Feld standen.
  final Set<String> onPitch;

  /// Eigentor (eines eigenen Spielers bzw. des Gegners).
  bool get isOwnGoal => event.type == MatchEventType.ownGoal;
}

/// Auswertung eines Spiels: Tore mit Besetzung, Minuten je Spieler.
class OnPitchMatch {
  const OnPitchMatch({
    required this.match,
    required this.goals,
    required this.minutes,
    required this.missingFor,
    required this.missingAgainst,
  });

  final GameMatch match;
  final List<OnPitchGoal> goals;

  /// Gespielte Minuten je eigenem Spieler (nur wer auf dem Feld war).
  final Map<String, int> minutes;

  /// Tore laut Spielstand, die nicht als Ereignis erfasst sind.
  final int missingFor;
  final int missingAgainst;

  bool played(String playerId) => minutes.containsKey(playerId);
}

/// Bilanz eines Spielers über mehrere Spiele.
class OnPitchSummary {
  const OnPitchSummary({
    required this.games,
    required this.minutes,
    required this.goalsFor,
    required this.goalsAgainst,
  });

  final int games;
  final int minutes;
  final int goalsFor;
  final int goalsAgainst;

  int get diff => goalsFor - goalsAgainst;

  double? get forPer90 => minutes > 0 ? goalsFor * 90 / minutes : null;
  double? get againstPer90 => minutes > 0 ? goalsAgainst * 90 / minutes : null;
}

const _goalTypes = {MatchEventType.goal, MatchEventType.penalty};

int _compareEvents(MatchEvent a, MatchEvent b) {
  final m = a.minute.compareTo(b.minute);
  if (m != 0) return m;
  final x = a.minuteExtra.compareTo(b.minuteExtra);
  if (x != 0) return x;
  return a.createdAt.compareTo(b.createdAt);
}

/// Wertet ein Spiel aus: Startelf ([starters]) fortgeschrieben durch Wechsel,
/// „Verletzt raus" und Platzverweise des eigenen Teams; je Tor die Besetzung.
OnPitchMatch analyzeOnPitch(
  GameMatch match,
  List<MatchEvent> events,
  Set<String> starters,
) {
  final ownId = match.ownTeamId;
  final sorted = [
    for (final e in events)
      if (e.matchId == match.id) e,
  ]..sort(_compareEvents);

  // Spielende: Abpfiff-Marke, sonst max(90, letzte Minute).
  final fulltime = sorted
      .where((e) => e.type == MatchEventType.fulltime)
      .map((e) => e.minute)
      .fold<int?>(null, (a, b) => a == null || b > a ? b : a);
  var lastMinute = 0;
  for (final e in sorted) {
    if (e.minute > lastMinute) lastMinute = e.minute;
  }
  final end = fulltime ?? (lastMinute > 90 ? lastMinute : 90);

  final onPitch = <String>{...starters};
  final since = <String, int>{for (final id in starters) id: 0};
  final minutes = <String, int>{};

  void leave(String id, int minute) {
    if (!onPitch.remove(id)) return;
    final from = since.remove(id) ?? 0;
    final m = (minute.clamp(0, end) - from).clamp(0, end);
    minutes[id] = (minutes[id] ?? 0) + m;
  }

  void enter(String id, int minute) {
    if (!onPitch.add(id)) return;
    since[id] = minute.clamp(0, end);
    minutes.putIfAbsent(id, () => 0);
  }

  final goals = <OnPitchGoal>[];
  for (final e in sorted) {
    final own = e.teamId == ownId;
    switch (e.type) {
      case MatchEventType.substitution:
      case MatchEventType.injuredOff:
        if (!own) break;
        final off = e.assistPlayerId, on = e.playerId;
        if (off != null) leave(off, e.minute);
        if (on != null) enter(on, e.minute);
      case MatchEventType.redCard:
      case MatchEventType.secondYellow:
        if (own && e.playerId != null) leave(e.playerId!, e.minute);
      default:
        if (_goalTypes.contains(e.type)) {
          goals.add(OnPitchGoal(event: e, forUs: own, onPitch: {...onPitch}));
        } else if (e.type == MatchEventType.ownGoal) {
          goals.add(OnPitchGoal(event: e, forUs: !own, onPitch: {...onPitch}));
        }
    }
  }
  for (final id in [...onPitch]) {
    leave(id, end);
  }
  // Startelf zählt als gespielt, auch bei 0 Minuten (z. B. sofort raus).
  for (final id in starters) {
    minutes.putIfAbsent(id, () => 0);
  }

  final gFor = goals.where((g) => g.forUs).length;
  final gAgainst = goals.length - gFor;
  return OnPitchMatch(
    match: match,
    goals: goals,
    minutes: minutes,
    missingFor: (match.ownScore - gFor).clamp(0, 99),
    missingAgainst: (match.opponentScore - gAgainst).clamp(0, 99),
  );
}

/// Bilanz eines Spielers über die ausgewerteten Spiele.
OnPitchSummary summarizeOnPitch(String playerId, List<OnPitchMatch> matches) {
  var games = 0, minutes = 0, gf = 0, ga = 0;
  for (final m in matches) {
    if (!m.played(playerId)) continue;
    games++;
    minutes += m.minutes[playerId] ?? 0;
    for (final g in m.goals) {
      if (!g.onPitch.contains(playerId)) continue;
      if (g.forUs) {
        gf++;
      } else {
        ga++;
      }
    }
  }
  return OnPitchSummary(
    games: games,
    minutes: minutes,
    goalsFor: gf,
    goalsAgainst: ga,
  );
}
