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
}
