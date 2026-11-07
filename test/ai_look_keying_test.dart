import 'dart:typed_data';

import 'package:coach_companion/screens/startelf_graphic_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// Prüft die Freistell-Logik des KI-Looks (ohne KI-Aufruf).
void main() {
  Uint8List png(List<List<int>> rgb) {
    final im = img.Image(width: rgb.length, height: 1);
    for (var x = 0; x < rgb.length; x++) {
      im.setPixelRgb(x, 0, rgb[x][0], rgb[x][1], rgb[x][2]);
    }
    return Uint8List.fromList(img.encodePng(im));
  }

  img.Pixel px(Uint8List bytes, int x) => img.decodePng(bytes)!.getPixel(x, 0);

  test('Leinwand hat Zielformat und Grundfarbe', () {
    final out = lookCanvasPng({'w': 9, 'h': 16, 'magenta': true});
    final im = img.decodePng(out)!;
    expect(im.width, 9);
    expect(im.height, 16);
    final p = im.getPixel(4, 8);
    expect([p.r, p.g, p.b], [255, 0, 255]);
  });

  test('Leuchtend: Schwarz wird transparent, Helles bleibt', () {
    final out = lumaKeyBlack(
      png([
        [0, 0, 0], // Schwarz
        [255, 255, 255], // Weiß
        [128, 0, 0], // dunkles Rot
      ]),
    );
    expect(px(out, 0).a, 0);
    expect(px(out, 1).a, 255);
    final red = px(out, 2);
    expect(red.a, 128); // halb deckend
    expect(red.r, 255); // Farbe entmultipliziert → gleiche Wirkung
  });

  test('Freigestellt: Magenta weg, andere Farben bleiben, Saum entfärbt', () {
    final out = chromaKeyMagenta(
      png([
        [255, 0, 255], // Magenta-Grund
        [0, 255, 0], // Grün (Deko)
        [200, 80, 200], // Kante mit Magenta-Stich
      ]),
    );
    expect(px(out, 0).a, 0);
    final green = px(out, 1);
    expect(green.a, 255);
    expect([green.r, green.g, green.b], [0, 255, 0]);
    final edge = px(out, 2);
    expect(edge.a, inInclusiveRange(1, 254)); // weiche Kante
    expect(edge.r, lessThan(200)); // Magenta-Stich entfernt
    expect(edge.b, lessThan(200));
  });
}
