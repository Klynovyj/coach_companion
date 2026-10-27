import 'package:flutter_test/flutter_test.dart';

import 'package:coach_companion/models/enums.dart';
import 'package:coach_companion/services/fupa/fupa_dtos.dart';
import 'package:coach_companion/services/fupa/fupa_redux_importer.dart';

void main() {
  group('FupaReduxImporter.isPlayerUrl', () {
    test('erkennt Spieler-URLs', () {
      expect(
        FupaReduxImporter.isPlayerUrl(
          'https://www.fupa.net/player/max-mustermann',
        ),
        isTrue,
      );
      expect(
        FupaReduxImporter.isPlayerUrl('http://fupa.de/player/abc'),
        isTrue,
      );
    });
    test('lehnt Nicht-Spieler-URLs ab', () {
      expect(
        FupaReduxImporter.isPlayerUrl('https://www.fupa.net/team/xyz'),
        isFalse,
      );
      expect(FupaReduxImporter.isPlayerUrl('7 Max Mustermann'), isFalse);
    });
  });

  group('FupaReduxImporter.parsePlayerHtml', () {
    test('liest Name, Position und Trikotnummer', () {
      const html =
          '<html><script>window.REDUX_DATA = '
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
      const html =
          'window.REDUX_DATA = '
          '{"dataHistory":[{"PlayerPage":{"data":{'
          r'"firstName":"A}B","lastName":"Keller","position":"Tor"'
          '}}}]};';
      final p = FupaReduxImporter.parsePlayerHtml(html);
      expect(p.firstName, 'A}B');
      expect(p.lastName, 'Keller');
      expect(p.position, 'Torwart');
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
      const html =
          'window.REDUX_DATA = '
          '{"dataHistory":[{"TeamPlayersPage":{"data":{"players":['
          '{"firstName":"Felix","lastName":"Leithold","position":"Torwart","jerseyNumber":1,"isDeactivated":false},'
          '{"firstName":"Max","lastName":"Mustermann","position":"Angriff","jerseyNumber":9},'
          '{"firstName":"Weg","lastName":"Gegangen","position":"Abwehr","jerseyNumber":4,"isDeactivated":true}'
          ']}}}]};';
      final squad = FupaReduxImporter.parseTeamPlayersHtml(html);
      expect(squad, hasLength(2));
      expect(squad[0].lastName, 'Leithold');
      expect(squad[0].position, 'Torwart');
      expect(squad[0].number, 1);
      expect(squad[1].position, 'Sturm');
      expect(squad[1].number, 9);
    });

    test('liest Vereinsname, Kurzname und Logo-URL (info.club)', () {
      const html =
          'window.REDUX_DATA = '
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
      expect(
        FupaReduxImporter.isTeamUrl(
          'https://www.fupa.net/team/garather-sv-m1-2026-27',
        ),
        isTrue,
      );
      expect(
        FupaReduxImporter.isTeamUrl('https://www.fupa.net/player/x'),
        isFalse,
      );
      expect(
        FupaReduxImporter.isFupaUrl('https://www.fupa.net/player/x'),
        isTrue,
      );
    });
  });

  group('FupaReduxImporter.parseTeamMatchesHtml', () {
    const html =
        'window.REDUX_DATA = '
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
        html,
        'garather-sv-m1-2026-27',
      );
      expect(list, hasLength(2));
      final m0 = list[0];
      expect(m0.opponentName, 'SV Hösel');
      expect(m0.venue, Venue.home);
      expect(m0.finished, isTrue);
      expect(m0.ownGoals, 6);
      expect(m0.opponentGoals, 2);
      expect(m0.competition, 'Kreisliga B2');
      expect(
        m0.opponentFupaUrl,
        'https://www.fupa.net/team/sv-hoesel-m2-2026-27',
      );
      expect(m0.opponentLogoUrl, 'https://image.fupa.net/club/HOE/');
    });

    test('Auswärtsspiel ohne Ergebnis (Ergebnis-Zuordnung über Venue)', () {
      final list = FupaReduxImporter.parseTeamMatchesHtml(
        html,
        'garather-sv-m1-2026-27',
      );
      final m1 = list[1];
      expect(m1.opponentName, 'Post SV');
      expect(m1.venue, Venue.away);
      expect(m1.finished, isFalse);
      expect(m1.ownGoals, isNull);
    });
  });

  group('FupaReduxImporter.parseTeamStatsHtml', () {
    test('liest Spieler-Saison-Statistik', () {
      const html =
          'window.REDUX_DATA = '
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

  group('FupaReduxImporter.parsePlayerStatsJson', () {
    test('liest die v1-API-Antwort (JSON-Array)', () {
      const body =
          '[{"id":488521,"slug":"matthias-seifert-488521",'
          '"firstName":"Matthias","lastName":"Seifert","matches":2,"goals":0,'
          '"assists":1,"yellowCards":1,"yellowRedCards":0,"redCards":0,'
          '"minutesPlayed":180,"topEleven":0},'
          '{"id":2038273,"firstName":"Max","lastName":"Unger","matches":5,'
          '"goals":3,"assists":2,"minutesPlayed":450,"redCards":1}]';
      final stats = FupaReduxImporter.parsePlayerStatsJson(body);
      expect(stats, hasLength(2));
      expect(stats[0].lastName, 'Seifert');
      expect(stats[0].minutes, 180);
      expect(stats[0].assists, 1);
      expect(stats[1].goals, 3);
      expect(stats[1].minutes, 450);
      expect(stats[1].redCards, 1);
      expect(stats[1].externalId, '2038273');
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
          'name': {'full': 'TSV Urdenbach'},
        },
        'awayTeam': {
          'slug': 'garather-sv-m1-2026-27',
          'name': {'full': 'Garather SV'},
        },
      },
      {
        'id': 2,
        'kickoff': '2026-09-20T15:00:00+02:00',
        'homeGoal': 3,
        'awayGoal': 0,
        'homeTeam': {
          'slug': 'garather-sv-m1-2026-27',
          'name': {'full': 'Garather SV'},
        },
        'awayTeam': {
          'slug': 'vfl-benrath-m2-2026-27',
          'name': {'full': 'VfL Benrath'},
        },
      },
      {
        'id': 3,
        'kickoff': '2026-10-25T13:00:00+01:00',
        'homeGoal': null,
        'awayGoal': null,
        'homeTeam': {
          'slug': 'post-sv-duesseldorf-m1-2026-27',
          'name': {'full': 'Post SV Düsseldorf'},
        },
        'awayTeam': {
          'slug': 'garather-sv-m1-2026-27',
          'name': {'full': 'Garather SV'},
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
          'name': {'full': 'A'},
        },
        'awayTeam': {
          'slug': 'b-m1-2026-27',
          'name': {'full': 'B'},
        },
      },
    ];

    test('filtert eigene Spiele und ordnet Heim/Auswärts + Ergebnis zu', () {
      final res = FupaReduxImporter.parseLeagueMatches(
        items,
        'garather-sv-m1-2026-27',
        competition: 'Kreisliga B2',
      );
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
      expect(
        res[2].opponentFupaUrl,
        'https://www.fupa.net/team/post-sv-duesseldorf-m1-2026-27',
      );
    });
  });

  group('FupaReduxImporter.parseStandingRow', () {
    test('findet die Tabellenzeile eines Teams', () {
      const html =
          'window.REDUX_DATA = '
          '{"dataHistory":[{"LeagueStandingPage":{"total":{"data":{"standings":['
          '{"rank":7,"matches":10,"wins":6,"draws":0,"defeats":4,"ownGoals":30,"againstGoals":27,"goalDifference":3,"points":18,"team":{"slug":"sv-hoesel-m2-2026-27","name":{"full":"SV Hösel"}}},'
          '{"rank":1,"matches":10,"wins":8,"draws":1,"defeats":1,"ownGoals":43,"againstGoals":13,"goalDifference":30,"points":25,"team":{"slug":"djk-tusa-06-duesseldorf-m2-2026-27","name":{"full":"DJK Tusa"}}}'
          ']}}}}]};';
      final row = FupaReduxImporter.parseStandingRow(
        html,
        'sv-hoesel-m2-2026-27',
      );
      expect(row, isNotNull);
      expect(row!.rank, 7);
      expect(row.points, 18);
      expect(row.goalDiff, 3);
      expect(row.totalTeams, 2);
      expect(row.teamName, 'SV Hösel');
      expect(row.teamSlug, 'sv-hoesel-m2-2026-27');

      // Komplette Tabelle: beide Zeilen.
      final table = FupaReduxImporter.parseStanding(html);
      expect(table, hasLength(2));
      expect(table.first.rank, 7);
      expect(table.last.rank, 1);
    });
  });

  group('FupaReduxImporter.parseTeamForm', () {
    test('filtert gespielte Spiele, sortiert neueste zuerst', () {
      final items = [
        {
          'kickoff': '2026-09-20T15:00:00+02:00',
          'homeGoal': 5,
          'awayGoal': 2,
          'section': 'POST',
          'homeTeam': {
            'slug': 'sv-hoesel-m2-2026-27',
            'name': {'full': 'SV Hösel'},
          },
          'awayTeam': {
            'slug': 'tsv-urdenbach-m1-2026-27',
            'name': {'full': 'TSV Urdenbach'},
          },
        },
        {
          'kickoff': '2026-10-18T13:00:00+02:00',
          'homeGoal': 2,
          'awayGoal': 6,
          'section': 'POST',
          'homeTeam': {
            'slug': 'sv-hoesel-m2-2026-27',
            'name': {'full': 'SV Hösel'},
          },
          'awayTeam': {
            'slug': 'garather-sv-m1-2026-27',
            'name': {'full': 'Garather SV'},
          },
        },
        {
          'kickoff': '2026-11-01T13:00:00+01:00',
          'homeGoal': null,
          'awayGoal': null,
          'section': 'PRE',
          'homeTeam': {
            'slug': 'sv-hoesel-m2-2026-27',
            'name': {'full': 'SV Hösel'},
          },
          'awayTeam': {
            'slug': 'x',
            'name': {'full': 'X'},
          },
        },
        // fremdes Spiel – ignoriert
        {
          'kickoff': '2026-09-13T13:00:00+02:00',
          'homeGoal': 1,
          'awayGoal': 1,
          'section': 'POST',
          'homeTeam': {
            'slug': 'a',
            'name': {'full': 'A'},
          },
          'awayTeam': {
            'slug': 'b',
            'name': {'full': 'B'},
          },
        },
      ];
      final form = FupaReduxImporter.parseTeamForm(
        items,
        'sv-hoesel-m2-2026-27',
      );
      expect(form, hasLength(2));
      // Neuestes zuerst: 18.10. Niederlage 2:6
      expect(form[0].ownGoals, 2);
      expect(form[0].oppGoals, 6);
      expect(form[0].result, 'N');
      expect(form[0].home, isTrue);
      expect(form[0].opponentName, 'Garather SV');
      // 20.09. Sieg 5:2
      expect(form[1].result, 'S');
      expect(form[1].opponentName, 'TSV Urdenbach');
    });
  });

  group('Geburtsdatum', () {
    test('parseBirthday liest "birthday" aus Profil-HTML', () {
      const html =
          '...{"firstName":"Felix","lastName":"Leithold","birthday":"2006-09-28","image":{}}...';
      expect(FupaReduxImporter.parseBirthday(html), DateTime(2006, 9, 28));
    });

    test('parseBirthday ohne Feld → null', () {
      expect(FupaReduxImporter.parseBirthday('{"firstName":"X"}'), isNull);
    });
  });

  group('FupaReduxImporter.parsePlayerCareerHtml', () {
    String station(
      String slug,
      String club,
      String comp,
      int sp,
      int to,
      int as,
    ) =>
        '<a href="/team/$slug">'
        '<span class="sc-lhxcmh-0 jOiTFY sc-v2incs-4 jmEKAz">$club</span>'
        '<span class="sc-lhxcmh-0 jOiTFY"></span>'
        '<span class="sc-lhxcmh-0 hudpXq sc-v2incs-4 jmEKAz">$comp</span></a>'
        '<div class="stats">'
        '<span class="jOiTFY cWnPsJ">$sp</span><span class="hudpXq">Spiele</span>'
        '<span class="jOiTFY cWnPsJ">$to</span><span class="hudpXq">Tore</span>'
        '<span class="jOiTFY cWnPsJ">$as</span><span class="hudpXq">Assists</span>'
        '</div>';

    final html =
        '<span class="t">Bilanz: <!-- -->100 Spiele, 41 Tore, 52 Assists, '
        '6 Gelb, 0 Gelb-Rot, 0 Rot, 7 Elf d. W.</span>'
        '${station('garather-sv-m1-2026-27', 'Garather SV', 'KL B2 Düsseldorf<!-- --><!-- -->26/27', 11, 2, 7)}'
        '${station('garather-sv-m1-2025-26', 'Garather SV', 'KL C2 Düsseldorf<!-- --><!-- -->25/26', 26, 12, 16)}'
        '${station('sportfreunde-baumberg-u19-2-2016-17', 'SF Baumberg', 'Bergische A-Jun.-LK<!-- --><!-- -->16/17', 3, 0, 0)}';

    test('liest Bilanz und alle Stationen', () {
      final c = FupaReduxImporter.parsePlayerCareerHtml(html);
      expect(c.stations.length, 3);
      expect(c.totalMatches, 100);
      expect(c.totalGoals, 41);
      expect(c.totalAssists, 52);
      expect(c.totalYellow, 6);
      expect(c.totalTopEleven, 7);
      expect(c.stations.first.teamSlug, 'garather-sv-m1-2026-27');
      expect(c.stations.first.clubName, 'Garather SV');
      expect(c.stations.first.matches, 11);
      expect(c.stations.first.goals, 2);
      expect(c.stations.first.assists, 7);
    });

    test('clubTotal summiert nur den Verein (per Slug)', () {
      final c = FupaReduxImporter.parsePlayerCareerHtml(html);
      final t = c.clubTotal(clubSlug: 'garather-sv');
      expect(t.seasons, 2);
      expect(t.matches, 37); // 11 + 26
      expect(t.goals, 14); // 2 + 12
      expect(t.assists, 23); // 7 + 16
      expect(t.scorerPoints, 37);
      expect(t.hasAny, isTrue);
    });

    test('clubTotal per Name als Rückfall', () {
      final c = FupaReduxImporter.parsePlayerCareerHtml(html);
      final t = c.clubTotal(clubName: 'Garather SV');
      expect(t.seasons, 2);
      expect(t.matches, 37);
      expect(t.goals, 14);
    });

    test('pflichtOnly schließt Freundschaftsspiele aus, Pokal zählt', () {
      final h =
          html +
          station(
            'garather-sv-m1-2026-27',
            'Garather SV',
            'Freundschaft<!-- --><!-- -->26/27',
            5,
            3,
            1,
          ) +
          station(
            'garather-sv-m1-2026-27',
            'Garather SV',
            'Kreispokal Düsseldorf<!-- --><!-- -->26/27',
            4,
            2,
            0,
          );
      final c = FupaReduxImporter.parsePlayerCareerHtml(h);
      final all = c.clubTotal(clubSlug: 'garather-sv');
      final pflicht = c.clubTotal(clubSlug: 'garather-sv', pflichtOnly: true);
      expect(all.matches, 46); // 37 + 5 Freundschaft + 4 Pokal
      expect(pflicht.matches, 41); // 37 Liga + 4 Pokal, ohne Freundschaft
      expect(pflicht.goals, 16); // 14 + 2 Pokal
    });

    test('clubSlugFromTeamUrl entfernt Team-/Saison-Suffix', () {
      expect(
        FupaReduxImporter.clubSlugFromTeamUrl(
          'https://www.fupa.net/team/garather-sv-m1-2026-27',
        ),
        'garather-sv',
      );
    });
  });
}
