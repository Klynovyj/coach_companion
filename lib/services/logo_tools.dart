import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Bildwerkzeuge für Vereins-/Sponsor-Logos (reine Funktionen, isolate-tauglich
/// → per `compute` aufrufbar). Alle geben PNG-Bytes zurück.

img.Image? _decode(Uint8List bytes) {
  final im = img.decodeImage(bytes);
  if (im == null) return null;
  return im.numChannels == 4 ? im : im.convert(numChannels: 4);
}

Uint8List _png(img.Image im) => Uint8List.fromList(img.encodePng(im));

/// Beliebiges Bild als PNG (z. B. nach dem Zuschnitt); max. [maxSide] px.
Uint8List normalizeLogoPng(Uint8List bytes, {int maxSide = 800}) {
  final im = _decode(bytes);
  if (im == null) return bytes;
  if (im.width <= maxSide && im.height <= maxSide) return _png(im);
  return _png(
    img.copyResize(
      im,
      width: im.width >= im.height ? maxSide : null,
      height: im.height > im.width ? maxSide : null,
      interpolation: img.Interpolation.average,
    ),
  );
}

/// 90° im Uhrzeigersinn drehen.
Uint8List rotateLogo90(Uint8List bytes) {
  final im = _decode(bytes);
  if (im == null) return bytes;
  return _png(img.copyRotate(im, angle: 90));
}

/// Hintergrund-Pixel: (fast) transparent oder (fast) weiß.
bool _isBlank(img.Pixel p) =>
    p.a < 24 || math.min(p.r, math.min(p.g, p.b)) >= 238;

/// Leere Ränder (transparent oder weiß) abschneiden; [padFraction] lässt
/// etwas Luft um das Logo.
Uint8List trimLogo(Uint8List bytes, {double padFraction = 0.03}) {
  final im = _decode(bytes);
  if (im == null) return bytes;
  var x0 = im.width, y0 = im.height, x1 = -1, y1 = -1;
  for (final p in im) {
    if (_isBlank(p)) continue;
    if (p.x < x0) x0 = p.x;
    if (p.x > x1) x1 = p.x;
    if (p.y < y0) y0 = p.y;
    if (p.y > y1) y1 = p.y;
  }
  if (x1 < 0) return bytes; // leer
  final pad = (math.max(x1 - x0, y1 - y0) * padFraction).round();
  x0 = math.max(0, x0 - pad);
  y0 = math.max(0, y0 - pad);
  x1 = math.min(im.width - 1, x1 + pad);
  y1 = math.min(im.height - 1, y1 + pad);
  if (x0 == 0 && y0 == 0 && x1 == im.width - 1 && y1 == im.height - 1) {
    return _png(im);
  }
  return _png(
    img.copyCrop(im, x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1),
  );
}

/// Weiß → transparent mit weicher Kante (200 deckend … 240 transparent).
/// [everywhere] = false: nur das vom Rand aus zusammenhängende Weiß (Weiß
/// INNEN im Logo, z. B. Schrift, bleibt); true: jedes Weiß.
Uint8List removeWhiteBackground(Uint8List bytes, {bool everywhere = false}) {
  final im = _decode(bytes);
  if (im == null) return bytes;
  final w = im.width, h = im.height;
  double ramp(img.Pixel p) {
    final m = math.min(p.r, math.min(p.g, p.b)).toDouble();
    return ((m - 200) / 40).clamp(0.0, 1.0); // 0 = bleibt, 1 = weg
  }

  void clear(img.Pixel p) {
    final t = ramp(p);
    if (t > 0) p.a = (p.a * (1 - t)).round();
  }

  if (everywhere) {
    for (final p in im) {
      clear(p);
    }
    return _png(im);
  }
  final visited = Uint8List(w * h);
  final stack = <int>[];
  void push(int x, int y) {
    if (x < 0 || y < 0 || x >= w || y >= h) return;
    final i = y * w + x;
    if (visited[i] != 0) return;
    visited[i] = 1;
    stack.add(i);
  }

  for (var x = 0; x < w; x++) {
    push(x, 0);
    push(x, h - 1);
  }
  for (var y = 0; y < h; y++) {
    push(0, y);
    push(w - 1, y);
  }
  while (stack.isNotEmpty) {
    final i = stack.removeLast();
    final x = i % w, y = i ~/ w;
    final p = im.getPixel(x, y);
    // Schon transparent → weiterlaufen; hell genug → ausstanzen + weiter.
    if (p.a >= 24 && ramp(p) <= 0) continue; // Logo-Kante
    clear(p);
    push(x + 1, y);
    push(x - 1, y);
    push(x, y + 1);
    push(x, y - 1);
  }
  return _png(im);
}

final _logoFixCache = <String, ({bool dark, Uint8List bytes})>{};

/// Logo-Kontrast: Ist die „Tinte" eines Logos (alle nicht-weißen, sichtbaren
/// Pixel) auf Weiß schlecht lesbar (Kontrast < 3, z. B. Gold/Gelb/hell), wird
/// `dark: true` geliefert. Hat das Logo einen weißen (undurchsichtigen)
/// Hintergrund, wird der dabei transparent gemacht (weiche Kante), damit es
/// auf dem dunklen Feld sauber steht. Ergebnis wird je Logo zwischengespeichert.
({bool dark, Uint8List bytes}) logoContrastFix(Uint8List bytes) {
  var h = bytes.length;
  final step = math.max(1, bytes.length ~/ 64);
  for (var i = 0; i < bytes.length; i += step) {
    h = (h * 31 + bytes[i]) & 0x3fffffff;
  }
  final key = '${bytes.length}:$h';
  final cached = _logoFixCache[key];
  if (cached != null) return cached;
  var res = (dark: false, bytes: bytes);
  try {
    final im = img.decodeImage(bytes);
    if (im != null) {
      final small = im.width > 96 || im.height > 96
          ? img.copyResize(
              im,
              width: im.width >= im.height ? 96 : null,
              height: im.height > im.width ? 96 : null,
            )
          : im;
      var n = 0, transparent = 0;
      var lum = 0.0;
      double lin(num c) {
        final v = c / 255.0;
        return v <= 0.04045
            ? v / 12.92
            : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
      }

      for (final p in small) {
        final a = p.aNormalized;
        if (a < 0.8) {
          transparent++;
          continue;
        }
        if (math.min(p.r, math.min(p.g, p.b)) >= 225) continue; // weiß
        lum += 0.2126 * lin(p.r) + 0.7152 * lin(p.g) + 0.0722 * lin(p.b);
        n++;
      }
      final total = small.width * small.height;
      if (n > total * 0.01) {
        final contrast = 1.05 / (lum / n + 0.05);
        if (contrast < 3) {
          var out = bytes;
          if (transparent < total * 0.05) {
            // Undurchsichtig mit weißem Grund → Weiß ausstanzen (max. 600 px).
            final big = im.width > 600 || im.height > 600
                ? img.copyResize(
                    im,
                    width: im.width >= im.height ? 600 : null,
                    height: im.height > im.width ? 600 : null,
                  )
                : im.clone();
            final rgba = big.numChannels == 4
                ? big
                : big.convert(numChannels: 4);
            for (final p in rgba) {
              final m = math.min(p.r, math.min(p.g, p.b));
              if (m >= 200) {
                // 200 → deckend … 245+ → transparent.
                final t = ((m - 200) / 45).clamp(0.0, 1.0);
                p.a = (p.a * (1 - t)).round();
              }
            }
            out = Uint8List.fromList(img.encodePng(rgba));
          }
          res = (dark: true, bytes: out);
        }
      }
    }
  } catch (_) {}
  _logoFixCache[key] = res;
  return res;
}
