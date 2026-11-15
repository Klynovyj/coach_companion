import 'dart:convert';
import 'dart:typed_data';

import 'package:coach_companion/services/svg_png.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  testWidgets('SVG wird scharf in PNG umgewandelt', (tester) async {
    const svg =
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 50">'
        '<rect x="0" y="0" width="50" height="50" fill="#ff0000"/></svg>';
    final bytes = Uint8List.fromList(utf8.encode(svg));
    expect(looksLikeSvg(bytes), isTrue);
    expect(looksLikeSvg(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47])), isFalse);
    final png = await tester.runAsync(() => svgToPng(bytes, maxSize: 400));
    expect(png, isNotNull);
    final im = img.decodePng(png!)!;
    expect(im.width, 400);
    expect(im.height, 200);
    final left = im.getPixel(100, 100);
    expect(left.r, greaterThan(200));
    expect(im.getPixel(300, 100).a, 0); // rechts transparent
  });
}
