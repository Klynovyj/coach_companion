import 'package:coach_companion/services/fupa/fupa_redux_importer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('extractTeamUrl', () {
    test('normaler Teamlink', () {
      expect(
        FupaReduxImporter.extractTeamUrl(
          'https://www.fupa.net/team/sv-hilden-ost-m2-2025-26',
        ),
        'https://www.fupa.net/team/sv-hilden-ost-m2-2025-26',
      );
    });

    test('geteilter Link mit Text, Unterseite und Query', () {
      expect(
        FupaReduxImporter.extractTeamUrl(
          'Schau mal: https://fupa.de/team/SV-Wersten-04-m1/matches?x=1 !',
        ),
        'https://www.fupa.net/team/sv-wersten-04-m1',
      );
    });

    test('kein Teamlink', () {
      expect(
        FupaReduxImporter.extractTeamUrl('https://www.fupa.net/club/sv-x'),
        isNull,
      );
      expect(FupaReduxImporter.extractTeamUrl('Hilden Ost 2'), isNull);
    });
  });
}
