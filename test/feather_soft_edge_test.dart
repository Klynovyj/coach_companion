import 'dart:math' as math;
import 'dart:typed_data';

import 'package:coach_companion/screens/startelf_graphic_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  test(
    'Weiche Kanten: großes Foto bekommt einen breiten, weichen Übergang',
    () {
      // 1000×1000, Motiv mit harter Kante bei x = 500.
      final im = img.Image(width: 1000, height: 1000, numChannels: 4)
        ..clear(img.ColorRgba8(0, 0, 0, 0));
      img.fillRect(
        im,
        x1: 200,
        y1: 200,
        x2: 499,
        y2: 800,
        color: img.ColorRgba8(200, 160, 140, 255),
      );
      final out = img.decodePng(
        applyImageFx({
          'data': Uint8List.fromList(img.encodePng(im)),
          'feather': 30,
          'inner': 0,
          'angle': 0.0,
          'rim': 0,
        }),
      )!;
      // Pixel mit Teil-Transparenz entlang einer Zeile über die Kante zählen.
      var soft = 0;
      for (var x = 470; x < 520; x++) {
        final a = out.getPixel(x, 500).a;
        if (a > 10 && a < 245) soft++;
      }
      expect(soft, greaterThanOrEqualTo(4)); // keine harte Linie mehr
      expect(soft, lessThanOrEqualTo(20)); // aber nicht verwaschen
      expect(out.getPixel(350, 500).a, 255); // Mitte bleibt deckend
    },
  );

  test('Rand verschmelzen erzeugt keinen dunklen Ring', () {
    final im = img.Image(width: 200, height: 200, numChannels: 4)
      ..clear(img.ColorRgba8(0, 0, 0, 0));
    img.fillRect(
      im,
      x1: 50,
      y1: 50,
      x2: 149,
      y2: 149,
      color: img.ColorRgba8(200, 160, 140, 255),
    );
    final out = img.decodePng(
      applyImageFx({
        'data': Uint8List.fromList(img.encodePng(im)),
        'feather': 0,
        'inner': 0,
        'angle': 0.0,
        'rim': 45,
      }),
    )!;
    // Am Umriss höchstens minimal dunkler als innen.
    final edge = out.getPixel(51, 100);
    expect(edge.r, greaterThan(190));
    expect(edge.a, lessThan(255)); // aber weich ausgeblendet
  });

  test('Rötlich-rosa Reste in Haaren werden konsequent entfernt', () {
    // Magenta-Grund, Haare (braun), darin rosa-rötliche Flecken am Rand.
    final im = img.Image(width: 200, height: 200)
      ..clear(img.ColorRgb8(255, 0, 255));
    img.fillRect(
      im,
      x1: 40,
      y1: 40,
      x2: 160,
      y2: 199,
      color: img.ColorRgb8(130, 90, 55), // Haare
    );
    img.fillRect(
      im,
      x1: 70,
      y1: 40,
      x2: 90,
      y2: 50,
      color: img.ColorRgb8(200, 80, 125),
    );
    img.fillRect(
      im,
      x1: 110,
      y1: 40, // reicht bis an den Haarrand (Fleck auf den Locken)
      x2: 125,
      y2: 52,
      color: img.ColorRgb8(170, 70, 95),
    );
    final out = img.decodePng(
      chromaKeyMagenta(Uint8List.fromList(img.encodePng(im))),
    )!;
    var pink = 0;
    for (var y = 38; y < 60; y++) {
      for (var x = 60; x < 135; x++) {
        final p = out.getPixel(x, y);
        if (p.a > 60 && math.min(p.r, p.b) - p.g > 12) pink++;
      }
    }
    expect(pink, 0); // kein sichtbares Rosa mehr
    // Haare tief im Motiv bleiben unverändert braun und deckend.
    final hair = out.getPixel(100, 150);
    expect(hair.a, 255);
    expect(hair.r, closeTo(130, 3));
    expect(hair.g, closeTo(90, 3));
  });
}
