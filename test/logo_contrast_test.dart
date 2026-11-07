import 'dart:typed_data';

import 'package:coach_companion/services/logo_tools.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// Helle/goldene Logos bekommen ein dunkles Feld (weißer Grund wird
/// transparent); dunkle Logos bleiben auf Weiß.
void main() {
  Uint8List logo(int r, int g, int b) {
    final im = img.Image(width: 80, height: 80)
      ..clear(img.ColorRgb8(255, 255, 255));
    img.fillCircle(im, x: 40, y: 40, radius: 25, color: img.ColorRgb8(r, g, b));
    return Uint8List.fromList(img.encodePng(im));
  }

  test('Gold auf Weiß → dunkles Feld, Weiß ausgestanzt', () {
    final fix = logoContrastFix(logo(212, 175, 55));
    expect(fix.dark, isTrue);
    final out = img.decodePng(fix.bytes)!;
    expect(out.getPixel(2, 2).a, 0); // Ecke (weiß) → transparent
    expect(out.getPixel(40, 40).a, 255); // Logo bleibt deckend
  });

  test('Dunkelgrün auf Weiß → bleibt weißes Feld', () {
    final fix = logoContrastFix(logo(20, 90, 60));
    expect(fix.dark, isFalse);
  });

  // Ring (dunkel) mit weißem Inneren auf weißem Grund, 120×80.
  Uint8List ring() {
    final im = img.Image(width: 120, height: 80)
      ..clear(img.ColorRgb8(255, 255, 255));
    img.fillCircle(im, x: 60, y: 40, radius: 20, color: img.ColorRgb8(0, 0, 0));
    img.fillCircle(
      im,
      x: 60,
      y: 40,
      radius: 10,
      color: img.ColorRgb8(255, 255, 255),
    );
    return Uint8List.fromList(img.encodePng(im));
  }

  test('Ränder entfernen schneidet auf das Logo zu', () {
    final out = img.decodePng(trimLogo(ring(), padFraction: 0))!;
    expect(out.width, inInclusiveRange(39, 43));
    expect(out.height, inInclusiveRange(39, 43));
  });

  test('Weiß am Rand: Hintergrund weg, Weiß innen bleibt', () {
    final out = img.decodePng(removeWhiteBackground(ring()))!;
    expect(out.getPixel(2, 2).a, 0); // Hintergrund
    expect(out.getPixel(60, 40).a, 255); // weißes Inneres bleibt
    expect(out.getPixel(60, 25).a, 255); // Ring bleibt
  });

  test('Alles Weiß: auch das Innere wird durchsichtig', () {
    final out = img.decodePng(removeWhiteBackground(ring(), everywhere: true))!;
    expect(out.getPixel(60, 40).a, 0);
    expect(out.getPixel(60, 25).a, 255);
  });

  test('Drehen tauscht Breite und Höhe', () {
    final out = img.decodePng(rotateLogo90(ring()))!;
    expect(out.width, 80);
    expect(out.height, 120);
  });
}
