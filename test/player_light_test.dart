import 'package:coach_companion/screens/startelf_graphic_screen.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

/// Wendet die 4×5-Matrix auf eine RGB-Farbe (0..255) an.
List<double> _apply(List<double> m, double r, double g, double b) => [
  for (var row = 0; row < 3; row++)
    m[row * 5] * r + m[row * 5 + 1] * g + m[row * 5 + 2] * b + m[row * 5 + 4],
];

void main() {
  test('Licht angleichen: k = 0 lässt das Bild unverändert', () {
    final m = lightMatchMatrix(const Color(0xFF0A5A2A), 0);
    final out = _apply(m, 200, 120, 80);
    expect(out[0], closeTo(200, 0.01));
    expect(out[1], closeTo(120, 0.01));
    expect(out[2], closeTo(80, 0.01));
  });

  test(
    'Grüner Hintergrund zieht ein warm beleuchtetes Gesicht Richtung Grün',
    () {
      final m = lightMatchMatrix(const Color(0xFF0A5A2A), 0.3);
      final out = _apply(m, 220, 150, 110); // Hautton mit Sonnenlicht
      // Verhältnis Grün/Rot steigt (weniger Orange-Stich).
      expect(out[1] / out[0], greaterThan(150 / 220));
      // Dunkle Szene → Spieler etwas dunkler, aber nicht abgesoffen.
      final lumIn = 0.2126 * 220 + 0.7152 * 150 + 0.0722 * 110;
      final lumOut = 0.2126 * out[0] + 0.7152 * out[1] + 0.0722 * out[2];
      expect(lumOut, lessThan(lumIn));
      expect(lumOut, greaterThan(lumIn * 0.8));
    },
  );

  test('Neutral graues Licht ändert die Farbe kaum', () {
    final m = lightMatchMatrix(const Color(0xFF808080), 0.5);
    final out = _apply(m, 200, 100, 50);
    // Farbverhältnis bleibt ähnlich (nur leicht entsättigt).
    expect(out[0], greaterThan(out[1]));
    expect(out[1], greaterThan(out[2]));
  });

  test('FuPa-Style ist als erste Look-Vorlage vorhanden', () {
    expect(kGradePresets.first.$1, kFupaStyleName);
    final v = kGradePresets.first.$2;
    expect(v['warmth']!, greaterThan(0));
    expect(v['glow']!, greaterThan(0));
    expect(v['match']!, greaterThan(0));
    expect(v['shade']!, greaterThan(0));
  });
}
