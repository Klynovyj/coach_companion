import 'package:coach_companion/models/enums.dart';
import 'package:coach_companion/models/match.dart';
import 'package:coach_companion/models/match_event.dart';
import 'package:coach_companion/services/stats_engine.dart';
import 'package:flutter_test/flutter_test.dart';

var _seq = 0;

GameMatch _match(
  String id, {
  int own = 0,
  int opp = 0,
  DateTime? kickoff,
  Venue venue = Venue.home,
  String opponent = 'Gegner',
  String? competition,
}) => GameMatch(
  id: id,
  ownTeamId: 'us',
  opponentTeamId: 'them',
  opponentName: opponent,
  kickoff: kickoff,
  venue: venue,
  competition: competition,
  status: MatchStatus.finished,
  ownScore: own,
  opponentScore: opp,
  createdAt: DateTime(2026),
);

MatchEvent _e(
  String match,
  MatchEventType type,
  int minute, {
  String team = 'us',
  String? player,
  String? assist,
}) => MatchEvent(
  id: 'e${_seq++}',
  matchId: match,
  teamId: team,
  minute: minute,
  type: type,
  playerId: player,
  assistPlayerId: assist,
  createdAt: DateTime(2026, 11, 1, 15).add(Duration(seconds: _seq)),
);

StatMetric _m(String id) => kStatMetricById[id]!;

void main() {
  // Spiel 1: 2:1 Heimsieg, a trifft 2x (Vorlage b), b raus in 60. für d.
  final d1 = StatMatchData(
    match: _match(
      'm1',
      own: 2,
      opp: 1,
      kickoff: DateTime(2026, 9, 1),
      competition: 'Liga',
      opponent: 'Alpha',
    ),
    events: [
      _e('m1', MatchEventType.kickoff, 0),
      _e('m1', MatchEventType.goal, 10, player: 'a', assist: 'b'),
      _e('m1', MatchEventType.shot, 20, player: 'a'),
      _e('m1', MatchEventType.foul, 30, team: 'them'),
      _e('m1', MatchEventType.substitution, 60, player: 'd', assist: 'b'),
      _e('m1', MatchEventType.goal, 70, team: 'them'),
      _e('m1', MatchEventType.goal, 80, player: 'a'),
      _e('m1', MatchEventType.fulltime, 90),
    ],
    starters: {'a', 'b', 'c'},
    trainerRatings: {'a': 4.5, 'b': 3},
    matchRatings: [4, 5],
  );
  // Spiel 2: 0:2 Auswärtsniederlage im Februar, ohne Aufstellung.
  final d2 = StatMatchData(
    match: _match(
      'm2',
      opp: 2,
      kickoff: DateTime(2027, 2, 1),
      venue: Venue.away,
      competition: 'Pokal',
      opponent: 'Beta',
    ),
    events: [
      _e('m2', MatchEventType.kickoff, 0),
      _e('m2', MatchEventType.goal, 5, team: 'them'),
      _e('m2', MatchEventType.yellowCard, 50, player: 'a'),
      _e('m2', MatchEventType.goal, 90, team: 'them'),
      _e('m2', MatchEventType.fulltime, 90),
    ],
    trainerRatings: {'a': 2.5},
  );
  final all = [d1, d2];

  group('Filter', () {
    test('Zeitraum Hin-/Rückrunde', () {
      final season = MatchFilter.seasonOf(DateTime(2027, 2, 1));
      expect(season, 2026);
      expect(MatchFilter(period: 'first').apply(all, season), [d1]);
      expect(MatchFilter(period: 'second').apply(all, season), [d2]);
      expect(MatchFilter(period: 'season').apply(all, season), all);
    });

    test('Heim, Wettbewerb, Ergebnis, Gegner, Abwahl', () {
      expect(MatchFilter(venue: Venue.away).apply(all, 2026), [d2]);
      expect(MatchFilter(competitions: {'Liga'}).apply(all, 2026), [d1]);
      expect(MatchFilter(results: {'L'}).apply(all, 2026), [d2]);
      expect(MatchFilter(opponents: {'Alpha'}).apply(all, 2026), [d1]);
      expect(MatchFilter(excluded: {'m1'}).apply(all, 2026), [d2]);
      expect(
        MatchFilter(venue: Venue.home, results: {'L'}).apply(all, 2026),
        isEmpty,
      );
    });

    test('JSON hin und zurück', () {
      final f = MatchFilter(
        period: 'custom',
        from: DateTime(2026, 8, 1),
        venue: Venue.away,
        results: {'W'},
      );
      final g = MatchFilter.fromJson(f.toJson());
      expect(g.period, 'custom');
      expect(g.from, DateTime(2026, 8, 1));
      expect(g.venue, Venue.away);
      expect(g.results, {'W'});
    });
  });

  group('Spieler', () {
    test('Zählwerte, Minuten, je 90', () {
      expect(playerValue(_m('p_goals'), 'a', all), 2);
      expect(playerValue(_m('p_assists'), 'b', all), 1);
      expect(playerValue(_m('p_scorer'), 'a', all), 2);
      expect(playerValue(_m('p_yellow'), 'a', all), 1);
      expect(playerValue(_m('p_games'), 'a', all), 1);
      expect(playerValue(_m('p_minutes'), 'b', all), 60);
      expect(playerValue(_m('p_subin'), 'd', all), 1);
      // b: 1 Vorlage in 60 Minuten → 1,5 je 90.
      expect(playerValue(_m('p_assists'), 'b', all, per90: true), 1.5);
    });

    test('Schnittwerte ohne Daten sind null', () {
      expect(playerValue(_m('p_trainer'), 'a', all), 3.5);
      expect(playerValue(_m('p_trainer'), 'c', all), isNull);
      // Spiele/Minuten nur aus Spielen mit Startelf → ohne: null.
      expect(playerValue(_m('p_games'), 'a', [d2]), isNull);
    });

    test('Auf dem Feld', () {
      expect(playerValue(_m('p_on_for'), 'b', all), 1);
      expect(playerValue(_m('p_on_against'), 'b', all), 0);
      expect(playerValue(_m('p_off_diff'), 'b', all), 0);
      expect(playerValue(_m('p_on_diff'), 'a', all), 1);
    });

    test('Gruppen: Summe, Schnitt, je 90', () {
      const g = StatSubject(
        key: 'g',
        label: 'G',
        playerIds: ['a', 'b'],
        isGroup: true,
      );
      expect(subjectValue(_m('p_goals'), g, all), 2);
      expect(subjectValue(_m('p_goals'), g, all, mode: GroupMode.avg), 1);
      // Noten: immer Mittel der Mitglieder (a 3,5 · b 3).
      expect(subjectValue(_m('p_trainer'), g, all), 3.25);
      // 2 Tore + 0 in 90 + 60 Minuten → 1,2 je 90.
      expect(subjectValue(_m('p_goals'), g, all, per90: true), 1.2);
      expect(subjectSeries(_m('p_goals'), g, all), [2, 0]);
    });
  });

  group('Spiele', () {
    test('Bilanz und Zusammenfassung', () {
      expect(matchValue(_m('m_points'), d1), 3);
      expect(matchValue(_m('m_points'), d2), 0);
      expect(matchSummary(_m('m_points'), all), (3, 1.5));
      expect(matchSummary(_m('m_rating'), all), (4.5, 4.5));
      expect(matchSummary(_m('m_clean'), all), (0, 0));
    });

    test('Aktionen wir vs. Gegner', () {
      expect(matchValue(_m('m_act_foul_us'), d1), 0);
      expect(matchValue(_m('m_act_foul_opp'), d1), 1);
      expect(matchValue(_m('m_act_shot_us'), d1), 1);
    });

    test('Torzeitpunkte', () {
      expect(matchValue(_m('m_goal_b0_for'), d1), 1);
      expect(matchValue(_m('m_goal_b5_for'), d1), 1);
      expect(matchValue(_m('m_goal_b4_against'), d1), 1);
      expect(matchValue(_m('m_goal_b0_against'), d2), 1);
      expect(matchValue(_m('m_goal_b5_against'), d2), 1);
      expect(matchValue(_m('m_goal_h1_for'), d1), 1);
      expect(matchValue(_m('m_goal_h2_for'), d1), 1);
    });
  });

  test('Positionsgruppen', () {
    expect(positionGroupOf(['IV'], null), 'pos:abw');
    expect(positionGroupOf([], 'ST'), 'pos:st');
    expect(positionGroupOf([], 'Torwart'), 'pos:tw');
    expect(positionGroupOf([], null), isNull);
  });

  test('Formatierung', () {
    expect(formatStat(null), '–');
    expect(formatStat(3), '3');
    expect(formatStat(1.5), '1,50');
    expect(formatStat(3.25, decimals: 2), '3,25');
  });
}
