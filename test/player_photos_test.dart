import 'dart:convert';

import 'package:coach_companion/services/player_photos.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  test('Dateiendung aus den Bild-Bytes', () {
    final jpg = img.encodeJpg(img.Image(width: 4, height: 4));
    final png = img.encodePng(img.Image(width: 4, height: 4));
    expect(imageExtension(jpg), 'jpg');
    expect(imageExtension(png), 'png');
  });

  test('Kleines Foto bleibt byte-genau im Original', () {
    final jpg = img.encodeJpg(img.Image(width: 300, height: 500));
    final url = encodeOriginalPhoto(jpg);
    expect(url.startsWith('data:image/jpeg;base64,'), isTrue);
    expect(dataUrlBytes(url), jpg);
  });

  test('Sehr großes Foto wird verkleinert, Seitenverhältnis bleibt', () {
    final big = img.encodeJpg(img.Image(width: 3000, height: 4000));
    final out = img.decodeImage(dataUrlBytes(encodeOriginalPhoto(big))!)!;
    expect(out.height, kPlayerPhotoMaxSide);
    expect(out.width, 1920);
  });

  test('Profilbild-Kopie max. 512 px im Hochformat', () {
    final url =
        'data:image/jpeg;base64,'
        '${base64Encode(img.encodeJpg(img.Image(width: 960, height: 1200)))}';
    final thumb = img.decodeImage(dataUrlBytes(profileThumbFromDataUrl(url))!)!;
    expect(thumb.height, 512);
    expect(thumb.width, 410);
  });

  test('Fach-IDs und Schlüssel', () {
    expect(playerPhotoId('p1', 'club'), 'pphoto:p1:club');
    expect(PlayerPhotoSlot.fromKey('action'), PlayerPhotoSlot.action);
    expect(PlayerPhotoSlot.fromKey('x'), isNull);
  });
}
