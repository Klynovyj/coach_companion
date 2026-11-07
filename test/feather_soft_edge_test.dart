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
}
