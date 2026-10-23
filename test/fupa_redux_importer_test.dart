import 'package:flutter_test/flutter_test.dart';

import 'package:coach_companion/models/enums.dart';
import 'package:coach_companion/services/fupa/fupa_redux_importer.dart';

void main() {
  group('FupaReduxImporter.isPlayerUrl', () {
    test('erkennt Spieler-URLs', () {
      expect(FupaReduxImporter.isPlayerUrl(
          'https://www.fupa.net/player/max-mustermann'), isTrue);
      expect(FupaReduxImporter.isPlayerUrl(
          'http://fupa.de/player/abc'), isTrue);
    });
    test('lehnt Nicht-Spieler-URLs ab', () {
      expect(FupaReduxImporter.isPlayerUrl(
          'https://www.fupa.net/team/xyz'), isFalse);
      expect(FupaReduxImporter.isPlayerUrl('7 Max Mustermann'), isFalse);
    });
  });

  group('FupaReduxImporter.parsePlayerHtml', () {
    test('liest Name, Position und Trikotnummer', () {
      const html = '<html><script>window.REDUX_DATA = '
          '{"dataHistory":[{"PlayerPage":{"data":{'
          '"firstName":"Max","lastName":"Mustermann","position":"Sturm",'
          '"playerRole":{"seasons":[{"jerseyNumber":7}]}}}}]}'
          ';</script></html>';
      final p = FupaReduxImporter.parsePlayerHtml(html);
      expect(p.firstName, 'Max');
      expect(p.lastName, 'Mustermann');
      expect(p.position, 'Sturm');
      expect(p.number, 7);
    });

    test('Brace-Counter ist string-sicher (geschweifte Klammer im Text)', () {
      const html = 'window.REDUX_DATA = '
          '{"dataHistory":[{"PlayerPage":{"data":{'
          r'"firstName":"A}B","lastName":"Keller","position":"Tor"'
          '}}}]};';
      final p = FupaReduxImporter.parsePlayerHtml(html);
      expect(p.firstName, 'A}B');
      expect(p.lastName, 'Keller');
      expect(p.position, 'Tor');
    });

    test('wirft bei fehlendem REDUX_DATA', () {
      expect(
        () => FupaReduxImporter.parsePlayerHtml('<html>nichts</html>'),
        throwsA(isA<FupaImportException>()),
      );
    });
  });

  group('FupaReduxImporter.parseTeamPlayersHtml', () {
    test('liest den Kader und überspringt Deaktivierte', () {
      const html = 'window.REDUX_DATA = '
          '{"dataHistory":[{"TeamPlayersPage":{"data":{"players":['
          '{"firstName":"Felix","lastName":"Leithold","position":"Torwart","jerseyNumber":1,"isDeactivated":false},'
          '{"firstName":"Max","lastName":"Mustermann","position":"Angriff","jerseyNumber":9},'
          '{"firstName":"Weg","lastName":"Gegangen","position":"Abwehr","jerseyNumber":4,"isDeactivated":true}'
          ']}}}]};';
      final squad = FupaReduxImporter.parseTeamPlayersHtml(html);
      expect(squad, hasLength(2));
      expect(squad[0].lastName, 'Leithold');
      expect(squad[0].position, 'Tor');
      expect(squad[0].number, 1);
      expect(squad[1].position, 'Sturm');
      expect(squad[1].number, 9);
    });

    test('liest Vereinsname, Kurzname und Logo-URL (info.club)', () {
      const html = 'window.REDUX_DATA = '
          '{"dataHistory":[{"TeamPlayersPage":{"data":{"info":{"club":{'
          '"name":"Garather SV","shortName":"GSV",'
          '"image":{"path":"https://image.fupa.net/club/ABC/"}}},'
          '"players":[]}}}]};';
      final meta = FupaReduxImporter.parseTeamMetaHtml(html);
      expect(meta.name, 'Garather SV');
      expect(meta.shortName, 'GSV');
      expect(meta.logoUrl, 'https://image.fupa.net/club/ABC/');
    });

    test('Team-URL-Erkennung', () {
      expect(FupaReduxImporter.isTeamUrl(
          'https://www.fupa.net/team/garather-sv-m1-2026-27'), isTrue);
      expect(FupaReduxImporter.isTeamUrl(
          'https://www.fupa.net/player/x'), isFalse);
      expect(FupaReduxImporter.isFupaUrl(
          'https://www.fupa.net/player/x'), isTrue);
    });
  });

  group('FupaReduxImporter.parseTeamMatchesHtml', () {
    const html = 'window.REDUX_DATA = '
        '{"dataHistory":[{"TeamMatchesPage":{"items":['
        '{"id":1,"kickoff":"2026-10-18T13:15:00+02:00","homeGoal":6,"awayGoal":2,'
        '"round":{"competitionSeason":{"shortName":"Kreisliga B2"}},'
        '"homeTeam":{"slug":"garather-sv-m1-2026-27","club":{"name":"Garather SV","image":{"path":"https://image.fupa.net/club/OWN/"}},"linkUrl":"/team/garather-sv-m1-2026-27"},'
        '"awayTeam":{"slug":"sv-hoesel-m2-2026-27","club":{"name":"SV Hösel","image":{"path":"https://image.fupa.net/club/HOE/"}},"linkUrl":"/team/sv-hoesel-m2-2026-27"}},'
        '{"id":2,"kickoff":"2026-10-25T15:00:00+01:00","homeGoal":null,"awayGoal":null,'
        '"round":{"competitionSeason":{"shortName":"Kreisliga B2"}},'
        '"homeTeam":{"slug":"post-sv-m1-2026-27","club":{"name":"Post SV"},"linkUrl":"/team/post-sv-m1-2026-27"},'
        '"awayTeam":{"slug":"garather-sv-m1-2026-27","club":{"name":"Garather SV"},"linkUrl":"/team/garather-sv-m1-2026-27"}}'
        ']}}]};';

    test('Heimspiel mit Ergebnis', () {
      final list = FupaReduxImporter.parseTeamMatchesHtml(
          html, 'garather-sv-m1-2026-27');
      expect(list, hasLength(2));
      final m0 = list[0];
      expect(m0.opponentName, 'SV Hösel');
      expect(m0.venue, Venue.home);
      expect(m0.finished, isTrue);
      expect(m0.ownGoals, 6);
      expect(m0.opponentGoals, 2);
      expect(m0.competition, 'Kreisliga B2');
      expect(m0.opponentFupaUrl, 'https://www.fupa.net/team/sv-hoesel-m2-2026-27');
      expect(m0.opponentLogoUrl, 'https://image.fupa.net/club/HOE/');
    });

    test('Auswärtsspiel ohne Ergebnis (Ergebnis-Zuordnung über Venue)', () {
      final list = FupaReduxImporter.parseTeamMatchesHtml(
          html, 'garather-sv-m1-2026-27');
      final m1 = list[1];
      expect(m1.opponentName, 'Post SV');
      expect(m1.venue, Venue.away);
      expect(m1.finished, isFalse);
      expect(m1.ownGoals, isNull);
    });
  });

  group('FupaReduxImporter.parseTeamStatsHtml', () {
    test('liest Spieler-Saison-Statistik', () {
      const html = 'window.REDUX_DATA = '
          '{"dataHistory":[{"TeamPlayerStatsPage":{"season":{"players":['
          '{"id":1,"firstName":"Max","lastName":"Mustermann","matches":10,"goals":7,"assists":3,"yellowCards":2,"yellowRedCards":0,"redCards":0,"minutesPlayed":850,"topEleven":4},'
          '{"id":2,"firstName":"Jonas","lastName":"Keller","matches":12,"goals":0,"assists":0,"minutesPlayed":1080}'
          ']}}}]};';
      final stats = FupaReduxImporter.parseTeamStatsHtml(html);
      expect(stats, hasLength(2));
      expect(stats[0].lastName, 'Mustermann');
      expect(stats[0].goals, 7);
      expect(stats[0].assists, 3);
      expect(stats[0].minutes, 850);
      expect(stats[0].topEleven, 4);
      expect(stats[1].minutes, 1080);
      expect(stats[1].goals, 0);
    });
  });

  group('FupaReduxImporter.parseLeagueMatches', () {
    final items = [
      {
        'id': 1,
        'kickoff': '2026-08-16T13:00:00+02:00',
        'homeGoal': 8,
        'awayGoal': 1,
        'homeTeam': {
          'slug': 'tsv-urdenbach-m1-2026-27',
          'name': {'full': 'TSV Urdenbach'}
        },
        'awayTeam': {
          'slug': 'garather-sv-m1-2026-27',
          'name': {'full': 'Garather SV'}
        },
      },
      {
        'id': 2,
        'kickoff': '2026-09-20T15:00:00+02:00',
        'homeGoal': 3,
        'awayGoal': 0,
        'homeTeam': {
          'slug': 'garather-sv-m1-2026-27',
          'name': {'full': 'Garather SV'}
        },
        'awayTeam': {
          'slug': 'vfl-benrath-m2-2026-27',
          'name': {'full': 'VfL Benrath'}
        },
      },
      {
        'id': 3,
        'kickoff': '2026-10-25T13:00:00+01:00',
        'homeGoal': null,
        'awayGoal': null,
        'homeTeam': {
          'slug': 'post-sv-duesseldorf-m1-2026-27',
          'name': {'full': 'Post SV Düsseldorf'}
        },
        'awayTeam': {
          'slug': 'garather-sv-m1-2026-27',
          'name': {'full': 'Garather SV'}
        },
      },
      // Fremdes Spiel – muss ignoriert werden.
      {
        'id': 4,
        'kickoff': '2026-08-16T13:00:00+02:00',
        'homeGoal': 1,
        'awayGoal': 1,
        'homeTeam': {
          'slug': 'a-m1-2026-27',
          'name': {'full': 'A'}
        },
        'awayTeam': {
          'slug': 'b-m1-2026-27',
          'name': {'full': 'B'}
        },
      },
    ];

    test('filtert eigene Spiele und ordnet Heim/Auswärts + Ergebnis zu', () {
      final res = FupaReduxImporter.parseLeagueMatches(
          items, 'garather-sv-m1-2026-27',
          competition: 'Kreisliga B2');
      expect(res, hasLength(3), reason: 'nur eigene Spiele');

      // Auswärts verloren 1:8
      expect(res[0].venue, Venue.away);
      expect(res[0].finished, isTrue);
      expect(res[0].ownGoals, 1);
      expect(res[0].opponentGoals, 8);
      expect(res[0].opponentName, 'TSV Urdenbach');
      expect(res[0].competition, 'Kreisliga B2');

      // Heim gewonnen 3:0
      expect(res[1].venue, Venue.home);
      expect(res[1].ownGoals, 3);
      expect(res[1].opponentGoals, 0);
      expect(res[1].opponentName, 'VfL Benrath');

      // Noch nicht gespielt
      expect(res[2].venue, Venue.away);
      expect(res[2].finished, isFalse);
      expect(res[2].ownGoals, isNull);
      expect(res[2].opponentFupaUrl,
          'https://www.fupa.net/team/post-sv-duesseldorf-m1-2026-27');
    });
  });
}
