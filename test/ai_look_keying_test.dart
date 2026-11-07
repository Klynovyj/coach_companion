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
        [210, 110, 190], // Kante (Haut + Magenta gemischt)
      ]),
    );
    expect(px(out, 0).a, 0);
    final green = px(out, 1);
    expect(green.a, 255);
    expect([green.r, green.g, green.b], [0, 255, 0]);
    final edge = px(out, 2);
    expect(edge.a, inInclusiveRange(1, 254)); // weiche Kante
    expect(edge.r, lessThan(210)); // Magenta-Stich entfernt
    expect(edge.b, lessThan(190));
  });

  test('Freigestellt: auch dunkles/schattiges Magenta (z. B. zwischen den '
      'Armen) wird entfernt, Haut/Trikot bleiben', () {
    final out = chromaKeyMagenta(
      png([
        [180, 30, 140], // Magenta im Schatten
        [120, 10, 100], // sehr dunkles Magenta
        [230, 60, 190], // helles, leicht verschobenes Pink
        [225, 180, 160], // Haut
        [200, 30, 40], // rotes Trikot
        [20, 20, 25], // schwarzes Shirt
        [60, 40, 120], // dunkles Lila/Blau
      ]),
    );
    expect(px(out, 0).a, 0);
    expect(px(out, 1).a, 0);
    expect(px(out, 2).a, 0);
    for (final x in [3, 4, 5, 6]) {
      expect(px(out, x).a, 255, reason: 'Pixel $x muss bleiben');
    }
  });

  test('Freistellen-Rückfall: KI liefert braunen statt Magenta-Grund → '
      'Randfarbe weg, auch eingeschlossen; Motiv bleibt', () {
    // 40×40 braun, schwarzes „Trikot" 20×24 mit brauner Lücke (Arm/Körper)
    // und einem Hautfleck.
    final im = img.Image(width: 40, height: 40)
      ..clear(img.ColorRgb8(95, 55, 55));
    img.fillRect(
      im,
      x1: 10,
      y1: 8,
      x2: 30,
      y2: 32,
      color: img.ColorRgb8(20, 20, 25),
    );
    img.fillRect(
      im,
      x1: 18,
      y1: 20,
      x2: 21,
      y2: 26,
      color: img.ColorRgb8(96, 56, 54),
    );
    img.fillRect(
      im,
      x1: 14,
      y1: 10,
      x2: 16,
      y2: 12,
      color: img.ColorRgb8(225, 180, 160),
    );
    final out = img.decodePng(
      cutoutFinish(Uint8List.fromList(img.encodePng(im))),
    )!;
    expect(out.getPixel(2, 2).a, 0); // Grund außen
    expect(out.getPixel(19, 23).a, 0); // eingeschlossene Lücke
    expect(out.getPixel(12, 28).a, 255); // Trikot
    expect(out.getPixel(15, 11).a, 255); // Haut
  });

  test('Erfolgsprüfung: unverändertes Foto hat ~0 % Durchsicht', () {
    // „KI hat nichts gemacht": Himmel oben, Straße unten, Person in der Mitte.
    final im = img.Image(width: 40, height: 40)
      ..clear(img.ColorRgb8(120, 170, 230));
    img.fillRect(
      im,
      x1: 0,
      y1: 26,
      x2: 39,
      y2: 39,
      color: img.ColorRgb8(130, 130, 125),
    );
    img.fillRect(
      im,
      x1: 14,
      y1: 6,
      x2: 26,
      y2: 39,
      color: img.ColorRgb8(20, 20, 25),
    );
    final out = cutoutFinish(Uint8List.fromList(img.encodePng(im)));
    expect(cutoutLooksDone(out), isFalse);
  });

  test('Erfolgsprüfung: sauber freigestellt → deutlich durchsichtig', () {
    final im = img.Image(width: 40, height: 40)
      ..clear(img.ColorRgb8(255, 0, 255));
    img.fillRect(
      im,
      x1: 14,
      y1: 6,
      x2: 26,
      y2: 39,
      color: img.ColorRgb8(20, 20, 25),
    );
    final out = cutoutFinish(Uint8List.fromList(img.encodePng(im)));
    expect(transparentFraction(out), greaterThan(0.5));
    expect(cutoutLooksDone(out), isTrue);
  });

  test('Freistellen: sauberer Magenta-Grund bleibt beim reinen Key', () {
    final im = img.Image(width: 20, height: 20)
      ..clear(img.ColorRgb8(255, 0, 255));
    img.fillRect(
      im,
      x1: 5,
      y1: 5,
      x2: 15,
      y2: 15,
      color: img.ColorRgb8(95, 55, 55), // braunes Motiv (z. B. Haare)
    );
    final out = img.decodePng(
      cutoutFinish(Uint8List.fromList(img.encodePng(im))),
    )!;
    expect(out.getPixel(1, 1).a, 0);
    expect(out.getPixel(10, 10).a, 255); // Motiv NICHT als Grund entfernt
  });
}
