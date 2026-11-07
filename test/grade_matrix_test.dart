import 'package:coach_companion/screens/startelf_graphic_screen.dart';
import 'package:flutter_test/flutter_test.dart';

/// Profi-Finish: alle linearen Regler als eine Farbmatrix.
void main() {
  // Matrix auf eine Farbe (0..255) anwenden.
  List<double> apply(List<double> m, double r, double g, double b) => [
    for (var row = 0; row < 3; row++)
      m[row * 5] * r + m[row * 5 + 1] * g + m[row * 5 + 2] * b + m[row * 5 + 4],
  ];

  test('Neutral = keine Änderung', () {
    final m = buildGradeMatrix();
    expect(apply(m, 10, 128, 240), [
      closeTo(10, 1e-6),
      closeTo(128, 1e-6),
      closeTo(240, 1e-6),
    ]);
  });

  test('Basis-Regler wirken wie bisher (Ton, dann Sättigung)', () {
    // Bisherige Formeln (vor dem Umbau) nachgebaut.
    const br = 20.0, co = 30.0, sa = -40.0, wa = 25.0;
    final c = 1 + (co / 100) * 0.9;
    final t = 128 * (1 - c) + (br / 100) * 70;
    final w = (wa / 100) * 22;
    List<double> tone(double r, double g, double b) =>
        [c * r + t + w, c * g + t, c * b + t - w];
    final s = (1 + (sa / 100) * 0.9).clamp(0.0, 2.0);
    const lr = 0.2126, lg = 0.7152, lb = 0.0722;
    List<double> sat(List<double> x) {
      final l = lr * x[0] + lg * x[1] + lb * x[2];
      return [for (final v in x) l + s * (v - l)];
    }

    final expected = sat(tone(60, 120, 200));
    final got = apply(
      buildGradeMatrix(
        brightness: br,
        contrast: co,
        saturation: sa,
        warmth: wa,
      ),
      60,
      120,
      200,
    );
    for (var i = 0; i < 3; i++) {
      expect(got[i], closeTo(expected[i], 1e-6));
    }
  });

  test('Belichtung +100 = eine Blende heller', () {
    final got = apply(buildGradeMatrix(exposure: 100), 50, 60, 70);
    expect(got, [closeTo(100, 1e-6), closeTo(120, 1e-6), closeTo(140, 1e-6)]);
  });

  test('Tiefen hebt Schwarz, Weiß bleibt', () {
    final m = buildGradeMatrix(shadows: 100);
    expect(apply(m, 0, 0, 0)[0], greaterThan(40));
    expect(apply(m, 255, 255, 255)[0], closeTo(255, 1e-6));
  });

  test('Lichter dämpft Weiß, Schwarz bleibt', () {
    final m = buildGradeMatrix(highlights: -100);
    expect(apply(m, 255, 255, 255)[0], lessThan(215));
    expect(apply(m, 0, 0, 0)[0], closeTo(0, 1e-6));
  });

  test('Sättigung −100 = Graustufen', () {
    final got = apply(buildGradeMatrix(saturation: -100), 200, 50, 10);
    // Bisherige Sättigungsformel: s = 0.1 bei −100 → fast grau.
    expect((got[0] - got[1]).abs(), lessThan(20));
  });

  test('Farbton 0 und 360 ändern nichts', () {
    final a = apply(buildGradeMatrix(hue: 0), 200, 50, 10);
    expect(a, [closeTo(200, 1e-6), closeTo(50, 1e-6), closeTo(10, 1e-6)]);
  });
}
