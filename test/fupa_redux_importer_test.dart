import 'package:flutter_test/flutter_test.dart';

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
}
