import 'package:coach_companion/screens/startelf_graphic_screen.dart';
import 'package:flutter_test/flutter_test.dart';

/// Torschützen-Zeilen der ENDSTAND-Grafik („B. KANIA 35' 40' 54' 60'").
void main() {
  test('Kurzname: Nummer weg, Vorname-Kürzel, Nachname groß', () {
    expect(scorerShortName('#7 Ben Kania'), 'B. KANIA');
    expect(scorerShortName('Philipp Trappen'), 'P. TRAPPEN');
    expect(scorerShortName('Furkan-Mustafa Bulut'), 'F. BULUT');
    expect(scorerShortName('Max van der Berg'), 'M. VAN DER BERG');
    expect(scorerShortName('Messi'), 'MESSI');
  });

  test('Unbekannte Torschützen ohne Namen', () {
    expect(scorerShortName('Gegner'), '');
    expect(scorerShortName('  '), '');
  });

  test('Tore je Spieler gruppiert, Minuten sortiert, Reihenfolge erstes Tor', () {
    final g = groupScorers([
      (minute: 40, name: '#7 Ben Kania', photo: null),
      (minute: 35, name: '#7 Ben Kania', photo: null),
      (minute: 82, name: 'Philipp Trappen', photo: null),
      (minute: 59, name: '#7 Ben Kania', photo: null),
      (minute: 88, name: 'Philipp Trappen', photo: null),
    ]);
    expect(g.length, 2);
    expect(g[0].label, 'B. KANIA');
    expect(g[0].minutes, [35, 40, 59]);
    expect(g[1].label, 'P. TRAPPEN');
    expect(g[1].minutes, [82, 88]);
  });

  test('Gegner-Tore ohne Namen landen in einer Zeile', () {
    final g = groupScorers([
      (minute: 48, name: 'Gegner', photo: null),
      (minute: 69, name: 'Gegner', photo: null),
    ]);
    expect(g.single.label, '');
    expect(g.single.minutes, [48, 69]);
  });

}
