import 'dart:typed_data';

import 'package:coach_companion/screens/startelf_graphic_screen.dart';
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
}
