import 'package:coach_companion/services/fupa/fupa_redux_importer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('FuPa-Sportstätte → Name + Adresse', () {
    final v = FupaReduxImporter.parseVenue({
      'name': 'Sportplatz SV Wersten 04',
      'street': ' Scheideweg 26',
      'postcode': '40591',
      'city': 'Düsseldorf',
    });
    expect(v?.venue, 'Sportplatz SV Wersten 04');
    expect(v?.address, 'Scheideweg 26, 40591 Düsseldorf');
  });

  test('leere oder fehlende Sportstätte → null', () {
    expect(FupaReduxImporter.parseVenue(null), isNull);
    expect(FupaReduxImporter.parseVenue({'name': ' ', 'city': ''}), isNull);
  });
}
