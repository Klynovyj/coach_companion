import 'dart:math' as math;
import 'dart:typed_data';

import 'package:coach_companion/models/compare_design.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  test('CompareDesign: JSON hin und zurück, Hintergrund nur einmal', () {
    final d = CompareDesign(
      left: CompareSide(photo: 'data:a', label: '2013', zoom: 1.5, dx: 0.3),
      right: CompareSide(photo: 'data:b', label: '2026', logo: 'data:l'),
      format: 's',
      frames: false,
      labelSize: 1.4,
      labelLook: {'font': 'anton'},
    );
    d.setBackground('data:bg');
    d.geomOf('f').applyDetected((0.05, 0.2, 0.4, 0.6), (0.5, 0.21, 0.45, 0.6));
    final j = d.toJson();
    expect((j['bgImages'] as List).length, 1);
    final e = CompareDesign.fromJson(j);
    expect(e.left.photo, 'data:a');
    expect(e.left.zoom, 1.5);
    expect(e.left.dx, 0.3);
    expect(e.right.logo, 'data:l');
    expect(e.right.label, '2026');
    expect(e.format, 's');
    expect(e.frames, isFalse);
    expect(e.labelSize, 1.4);
    expect(e.labelLook, {'font': 'anton'});
    expect(e.backgrounds, {'f': 'data:bg', 's': 'data:bg', 'p': 'data:bg'});
    final g = e.geomOf('f');
    expect(g.hasExact, isTrue);
    expect(g.frameLeft(1), 0.5);
    expect(g.widthOf(1), 0.45);
    expect(g.top, 0.2);
    expect(g.height, closeTo(0.61, 1e-9));
  });

  test('Seiten tauschen: Fotos wechseln, Beschriftung bleibt', () {
    final d = CompareDesign(
      left: CompareSide(photo: 'a', label: 'DAMALS'),
      right: CompareSide(photo: 'b', label: 'HEUTE'),
    );
    d.swapSides();
    expect(d.left.photo, 'b');
    expect(d.left.label, 'DAMALS');
    expect(d.right.photo, 'a');
  });

  test('Hintergrund nur fürs aktuelle Format', () {
    final d = CompareDesign()..setBackground('x');
    d.format = 'p';
    d.setBackground('y', allFormats: false);
    expect(d.backgrounds, {'f': 'x', 's': 'x', 'p': 'y'});
    d.setBackground(null, allFormats: false);
    expect(d.backgrounds.containsKey('p'), isFalse);
  });

  test('compareCoverRect füllt den Rahmen und verschiebt im Überstand', () {
    // Querformat-Bild in Hochformat-Rahmen → Höhe passt, Breite steht über.
    final r = compareCoverRect(fw: 100, fh: 200, iw: 400, ih: 200);
    expect(r.$4, 200);
    expect(r.$3, 400);
    expect(r.$1, -150); // mittig
    final l = compareCoverRect(fw: 100, fh: 200, iw: 400, ih: 200, dx: -1);
    expect(l.$1, 0); // linker Bildrand sichtbar
    final z = compareCoverRect(fw: 100, fh: 200, iw: 400, ih: 200, zoom: 2);
    expect(z.$4, 400);
  });

  test('Foto-Felder in einer Vorlage erkennen', () {
    // 1080×1350 (4:5): körniger, dunkler Hintergrund mit zwei schwarzen
    // Feldern und dünnem weißen Rand.
    const w = 1080, h = 1350;
    final im = img.Image(width: w, height: h);
    final rnd = math.Random(3);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final v = 25 + rnd.nextInt(30);
        im.setPixelRgb(x, y, v, v, v);
      }
    }
    void field(int x1, int y1, int x2, int y2) {
      img.fillRect(im, x1: x1 - 3, y1: y1 - 3, x2: x2 + 3, y2: y2 + 3,
          color: img.ColorRgb8(230, 230, 230));
      img.fillRect(im, x1: x1, y1: y1, x2: x2, y2: y2,
          color: img.ColorRgb8(0, 0, 0));
    }
    field(60, 330, 510, 1180);
    field(560, 330, 1020, 1180);
    final r = detectCompareFrames({
      'data': Uint8List.fromList(img.encodePng(im)),
      'aspect': 4 / 5,
    });
    expect(r, isNotNull);
    expect(r![0], closeTo(60 / w, 0.01));
    expect(r[1], closeTo(330 / h, 0.01));
    expect(r[2], closeTo(450 / w, 0.015));
    expect(r[3], closeTo(850 / h, 0.015));
    expect(r[4], closeTo(560 / w, 0.01));
    expect(r[6], closeTo(460 / w, 0.015));
  });

  test('Ohne Felder: nichts erkannt', () {
    final im = img.Image(width: 400, height: 500);
    final rnd = math.Random(5);
    for (var y = 0; y < 500; y++) {
      for (var x = 0; x < 400; x++) {
        final v = rnd.nextInt(80);
        im.setPixelRgb(x, y, v, v, v);
      }
    }
    expect(
      detectCompareFrames({
        'data': Uint8List.fromList(img.encodePng(im)),
        'aspect': 4 / 5,
      }),
      isNull,
    );
  });
}
