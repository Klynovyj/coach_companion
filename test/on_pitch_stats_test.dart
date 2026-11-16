import 'package:coach_companion/models/enums.dart';
import 'package:coach_companion/models/match.dart';
import 'package:coach_companion/models/match_event.dart';
import 'package:coach_companion/services/on_pitch_stats.dart';
import 'package:flutter_test/flutter_test.dart';

final _t0 = DateTime(2026, 11, 1, 15);
var _seq = 0;

GameMatch _match({int own = 0, int opp = 0}) => GameMatch(
  id: 'm1',
  ownTeamId: 'us',
  opponentTeamId: 'them',
  opponentName: 'Gegner',
  status: MatchStatus.finished,
  ownScore: own,
  opponentScore: opp,
  createdAt: _t0,
);

MatchEvent _e(
  MatchEventType type,
  int minute, {
  String team = 'us',
  String? player,
  String? assist,
  int extra = 0,
}) => MatchEvent(
  id: 'e${_seq++}',
  matchId: 'm1',
  teamId: team,
  minute: minute,
  minuteExtra: extra,
  type: type,
  playerId: player,
  assistPlayerId: assist,
  createdAt: _t0.add(Duration(seconds: _seq)),
);

void main() {
  const starters = {'a', 'b', 'c'};

  test('Tor/Gegentor mit Besetzung, Wechsel dazwischen', () {
    final r = analyzeOnPitch(_match(own: 1, opp: 1), [
      _e(MatchEventType.goal, 10, player: 'a'),
      _e(MatchEventType.substitution, 60, player: 'd', assist: 'b'),
      _e(MatchEventType.goal, 70, team: 'them', player: 'x'),
      _e(MatchEventType.fulltime, 90, team: 'us'),
    ], starters);
    expect(r.goals.length, 2);
    expect(r.goals[0].forUs, isTrue);
    expect(r.goals[0].onPitch, {'a', 'b', 'c'});
    expect(r.goals[1].forUs, isFalse);
    expect(r.goals[1].onPitch, {'a', 'c', 'd'});
    expect(r.minutes, {'a': 90, 'b': 60, 'c': 90, 'd': 30});
    expect(r.missingFor, 0);
    expect(r.missingAgainst, 0);
  });

  test('Wechsel und Tor in derselben Minute: Reihenfolge der Erfassung', () {
    final r = analyzeOnPitch(_match(own: 1), [
      _e(MatchEventType.substitution, 50, player: 'd', assist: 'a'),
      _e(MatchEventType.goal, 50, player: 'd'),
    ], starters);
    expect(r.goals.single.onPitch, {'b', 'c', 'd'});
  });

  test('Nachgetragener Wechsel wird nach Minute einsortiert', () {
    final r = analyzeOnPitch(_match(own: 1), [
      _e(MatchEventType.goal, 80, player: 'c'),
      _e(MatchEventType.substitution, 30, player: 'd', assist: 'a'),
    ], starters);
    expect(r.goals.single.onPitch, {'b', 'c', 'd'});
  });

  test('Hin- und Rueckwechsel, Minuten summiert', () {
    final r = analyzeOnPitch(_match(), [
      _e(MatchEventType.substitution, 20, player: 'd', assist: 'a'),
      _e(MatchEventType.substitution, 50, player: 'a', assist: 'd'),
    ], starters);
    expect(r.minutes['a'], 60);
    expect(r.minutes['d'], 30);
  });

  test('Platzverweis: Spieler ab der Minute nicht mehr auf dem Feld', () {
    final r = analyzeOnPitch(_match(opp: 1), [
      _e(MatchEventType.redCard, 40, player: 'b'),
      _e(MatchEventType.goal, 41, team: 'them'),
    ], starters);
    expect(r.goals.single.onPitch, {'a', 'c'});
    expect(r.minutes['b'], 40);
  });

  test('Eigentor des Gegners zaehlt fuer uns, eigenes Eigentor dagegen', () {
    final r = analyzeOnPitch(_match(own: 1, opp: 1), [
      _e(MatchEventType.ownGoal, 5, team: 'them'),
      _e(MatchEventType.ownGoal, 6, player: 'a'),
    ], starters);
    expect(r.goals[0].forUs, isTrue);
    expect(r.goals[1].forUs, isFalse);
  });

  test('Gegnerische Wechsel aendern die eigene Besetzung nicht', () {
    final r = analyzeOnPitch(_match(own: 1), [
      _e(
        MatchEventType.substitution,
        10,
        team: 'them',
        player: 'y',
        assist: 'a',
      ),
      _e(MatchEventType.goal, 20, player: 'a'),
    ], starters);
    expect(r.goals.single.onPitch, starters);
  });

  test('Fehlende Tore laut Spielstand', () {
    final r = analyzeOnPitch(_match(own: 2, opp: 4), [
      _e(MatchEventType.goal, 10, team: 'them'),
      _e(MatchEventType.goal, 20, team: 'them'),
      _e(MatchEventType.goal, 30, team: 'them'),
    ], starters);
    expect(r.missingFor, 2);
    expect(r.missingAgainst, 1);
  });

  test('Bilanz ueber mehrere Spiele', () {
    final r = analyzeOnPitch(_match(own: 1, opp: 1), [
      _e(MatchEventType.goal, 10, player: 'a'),
      _e(MatchEventType.substitution, 45, player: 'd', assist: 'b'),
      _e(MatchEventType.goal, 70, team: 'them'),
    ], starters);
    final b = summarizeOnPitch('b', [r]);
    expect(b.games, 1);
    expect(b.minutes, 45);
    expect(b.goalsFor, 1);
    expect(b.goalsAgainst, 0);
    expect(b.forPer90, 2.0);
    final d = summarizeOnPitch('d', [r]);
    expect(d.goalsFor, 0);
    expect(d.goalsAgainst, 1);
    expect(d.diff, -1);
    expect(summarizeOnPitch('zz', [r]).games, 0);
    // Ohne ihn: b war beim Gegentor schon draussen, d beim Tor noch nicht drin.
    expect(b.withoutFor, 0);
    expect(b.withoutAgainst, 1);
    expect(b.withoutMinutes, 45);
    expect(b.withoutAgainstPer90, 2.0);
    expect(d.withoutFor, 1);
    expect(d.withoutAgainst, 0);
    expect(d.withoutMinutes, 45);
    expect(r.split('d'), (0, 1, 1, 0));
    final z = summarizeOnPitch('zz', [r]);
    expect((z.withoutFor, z.withoutAgainst, z.withoutMinutes), (1, 1, 90));
  });
}
