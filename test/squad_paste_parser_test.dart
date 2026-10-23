import 'package:flutter_test/flutter_test.dart';

import 'package:coach_companion/services/paste/squad_paste_parser.dart';

void main() {
  group('SquadPasteParser', () {
    test('erkennt Nummer, Name und Position', () {
      final r = SquadPasteParser.parse('7 Max Mustermann Sturm');
      expect(r, hasLength(1));
      expect(r.first.number, 7);
      expect(r.first.firstName, 'Max');
      expect(r.first.lastName, 'Mustermann');
      expect(r.first.position, 'Sturm');
    });

    test('mehrere Zeilen, überspringt Leerzeilen', () {
      final r = SquadPasteParser.parse('1 Jonas Keller Tor\n\n9 Lea Vogt');
      expect(r, hasLength(2));
      expect(r[0].position, 'Tor');
      expect(r[1].number, 9);
      expect(r[1].lastName, 'Vogt');
    });

    test('entfernt Links und Klammer-Zusätze', () {
      final r = SquadPasteParser.parse(
          'https://www.fupa.net/player/max 11 Max Mustermann (12 Spiele, 3 Tore)');
      expect(r, hasLength(1));
      expect(r.first.number, 11);
      expect(r.first.fullName, 'Max Mustermann');
    });

    test('reine Nummern- oder Link-Zeilen ergeben keinen Spieler', () {
      final r = SquadPasteParser.parse('42\nhttps://www.fupa.net/team/x');
      expect(r, isEmpty);
    });

    test('einzelner Name ohne Nummer', () {
      final r = SquadPasteParser.parse('Mustermann');
      expect(r, hasLength(1));
      expect(r.first.firstName, '');
      expect(r.first.lastName, 'Mustermann');
      expect(r.first.number, isNull);
    });
  });
}
