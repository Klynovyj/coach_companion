/// Designer-Vorlage „Vergleich": zwei Fotos nebeneinander (links → rechts) auf
/// austauschbarem Hintergrund, mit Rahmen, Beschriftung und optionalem Bild
/// (z. B. Logo) über jedem Foto. Wird im Design-JSON unter `compare` gespeichert.
library;

import 'dart:collection';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Formate: 'f' = Hochformat 4:5, 's' = Story 9:16, 'p' = Post 1:1.
const List<String> kCompareFormats = ['f', 's', 'p'];

/// Seitenverhältnis (Breite / Höhe) eines Formats.
double compareAspect(String format) => switch (format) {
  's' => 9 / 16,
  'p' => 1.0,
  _ => 4 / 5,
};

String compareFormatLabel(String format) => switch (format) {
  's' => 'Story 9:16',
  'p' => 'Post 1:1',
  _ => 'Hochformat 4:5',
};

double _d(Object? v, double def) => v is num ? v.toDouble() : def;

/// Eine Seite des Vergleichs.
class CompareSide {
  CompareSide({
    this.photo,
    this.zoom = 1.0,
    this.dx = 0,
    this.dy = 0,
    this.logo,
    this.logoText,
    this.logoZoom = 1.0,
    this.logoDx = 0,
    this.logoDy = 0,
    this.label = '',
  });

  /// Foto als data:-URL (null = noch keins gewählt).
  String? photo;

  /// Ausschnitt: Zoom ≥ 1 und Verschiebung −1 … 1 (Anteil des überstehenden
  /// Bildes; 0 = mittig) – dadurch formatunabhängig.
  double zoom;
  double dx;
  double dy;

  /// Optionales Bild über dem Foto (z. B. Logo), data:-URL.
  String? logo;

  /// Text statt Bild über dem Foto (z. B. „SAISON 13/14"); hat Vorrang.
  String? logoText;

  /// Bild/Text über dem Foto: Zoom (0.3 … 3) und Verschiebung (Anteil der
  /// Feldbreite/-höhe, −0.6 … 0.6).
  double logoZoom;
  double logoDx;
  double logoDy;

  bool get hasTop => logo != null || (logoText?.trim().isNotEmpty ?? false);

  void resetLogoPos() {
    logoZoom = 1.0;
    logoDx = 0;
    logoDy = 0;
  }

  /// Beschriftung unter dem Foto (z. B. „2013").
  String label;

  void resetCrop() {
    zoom = 1.0;
    dx = 0;
    dy = 0;
  }

  Map<String, Object?> toJson() => {
    if (photo != null) 'photo': photo,
    'zoom': zoom,
    'dx': dx,
    'dy': dy,
    if (logo != null) 'logo': logo,
    if (logoText != null) 'logoText': logoText,
    'logoZoom': logoZoom,
    'logoDx': logoDx,
    'logoDy': logoDy,
    'label': label,
  };

  static CompareSide fromJson(Object? v, {String label = ''}) {
    if (v is! Map) return CompareSide(label: label);
    return CompareSide(
      photo: v['photo'] is String ? v['photo'] as String : null,
      zoom: _d(v['zoom'], 1).clamp(1.0, 5.0),
      dx: _d(v['dx'], 0).clamp(-1.0, 1.0),
      dy: _d(v['dy'], 0).clamp(-1.0, 1.0),
      logo: v['logo'] is String ? v['logo'] as String : null,
      logoText: v['logoText'] is String ? v['logoText'] as String : null,
      logoZoom: _d(v['logoZoom'], 1).clamp(0.3, 3.0),
      logoDx: _d(v['logoDx'], 0).clamp(-0.6, 0.6),
      logoDy: _d(v['logoDy'], 0).clamp(-0.6, 0.6),
      label: v['label'] is String ? v['label'] as String : label,
    );
  }
}

/// Lage der beiden Rahmen (symmetrisch), Anteile der Grafik-Breite (W) bzw.
/// -Höhe (H). Je Format getrennt, damit sie zum jeweiligen Hintergrund passt.
class CompareGeom {
  CompareGeom({
    required this.top,
    required this.height,
    required this.margin,
    required this.gap,
    required this.logoHeight,
    required this.labelGap,
    this.lx,
    this.lw,
    this.rx,
    this.rw,
  });

  /// Oberkante der Rahmen (× H).
  double top;

  /// Höhe der Rahmen (× H).
  double height;

  /// Rand links/rechts (× W).
  double margin;

  /// Abstand zwischen den Rahmen (× W).
  double gap;

  /// Höhe des Bildes über dem Foto (× H).
  double logoHeight;

  /// Abstand Beschriftung unter dem Rahmen (× H).
  double labelGap;

  /// Exakte Lage je Seite (× W), z. B. aus der Rahmen-Erkennung im
  /// Hintergrundbild. null = symmetrisch aus [margin]/[gap].
  double? lx, lw, rx, rw;

  bool get hasExact => lx != null && lw != null && rx != null && rw != null;

  /// Zurück zur symmetrischen Lage (z. B. nach Ändern von Rand/Abstand).
  void clearExact() {
    lx = null;
    lw = null;
    rx = null;
    rw = null;
  }

  static CompareGeom defaults(String format) => switch (format) {
    's' => CompareGeom(
      top: 0.22,
      height: 0.58,
      margin: 0.06,
      gap: 0.03,
      logoHeight: 0.15,
      labelGap: 0.018,
    ),
    'p' => CompareGeom(
      top: 0.23,
      height: 0.58,
      margin: 0.08,
      gap: 0.04,
      logoHeight: 0.17,
      labelGap: 0.02,
    ),
    _ => CompareGeom(
      top: 0.245,
      height: 0.585,
      margin: 0.06,
      gap: 0.03,
      logoHeight: 0.185,
      labelGap: 0.018,
    ),
  };

  CompareGeom copy() => CompareGeom(
    top: top,
    height: height,
    margin: margin,
    gap: gap,
    logoHeight: logoHeight,
    labelGap: labelGap,
    lx: lx,
    lw: lw,
    rx: rx,
    rw: rw,
  );

  /// Symmetrische Breite eines Rahmens (× W).
  double get frameWidth => ((1 - 2 * margin - gap) / 2).clamp(0.05, 0.5);

  /// Breite des Rahmens [side] (0 = links, 1 = rechts), × W.
  double widthOf(int side) =>
      hasExact ? (side == 0 ? lw! : rw!) : frameWidth;

  /// Linke Kante des Rahmens [side] (0 = links, 1 = rechts), × W.
  double frameLeft(int side) => hasExact
      ? (side == 0 ? lx! : rx!)
      : (side == 0 ? margin : margin + frameWidth + gap);

  /// Exakte Rahmen übernehmen (relativ, links/oben/Breite/Höhe je Seite).
  void applyDetected(
    (double, double, double, double) l,
    (double, double, double, double) r,
  ) {
    lx = l.$1;
    lw = l.$3;
    rx = r.$1;
    rw = r.$3;
    top = l.$2 < r.$2 ? l.$2 : r.$2;
    final bottom = (l.$2 + l.$4) > (r.$2 + r.$4) ? l.$2 + l.$4 : r.$2 + r.$4;
    height = bottom - top;
    // Regler-Werte passend (ungefähr) mitführen.
    margin = (lx! + (1 - rx! - rw!)) / 2;
    gap = rx! - (lx! + lw!);
  }

  Map<String, Object?> toJson() => {
    'top': top,
    'height': height,
    'margin': margin,
    'gap': gap,
    'logoH': logoHeight,
    'labelGap': labelGap,
    if (hasExact) 'exact': [lx, lw, rx, rw],
  };

  static CompareGeom fromJson(Object? v, String format) {
    final d = defaults(format);
    if (v is! Map) return d;
    final ex = v['exact'];
    final exact = ex is List && ex.length == 4 && ex.every((e) => e is num)
        ? [for (final e in ex) (e as num).toDouble().clamp(0.0, 1.0)]
        : null;
    return CompareGeom(
      lx: exact?[0],
      lw: exact?[1],
      rx: exact?[2],
      rw: exact?[3],
      top: _d(v['top'], d.top).clamp(0.0, 0.9),
      height: _d(v['height'], d.height).clamp(0.1, 1.0),
      margin: _d(v['margin'], d.margin).clamp(0.0, 0.3),
      gap: _d(v['gap'], d.gap).clamp(0.0, 0.3),
      logoHeight: _d(v['logoH'], d.logoHeight).clamp(0.0, 0.4),
      labelGap: _d(v['labelGap'], d.labelGap).clamp(0.0, 0.2),
    );
  }
}

/// Gesamtes Vergleichs-Design.
class CompareDesign {
  CompareDesign({
    CompareSide? left,
    CompareSide? right,
    Map<String, String>? backgrounds,
    Map<String, CompareGeom>? geom,
    this.format = 'f',
    this.frames = true,
    this.frameColor = '#FFFFFF',
    this.frameWidth = 1.2,
    this.labels = true,
    this.labelSize = 1.0,
    this.labelLook,
    this.topLook,
  }) : left = left ?? CompareSide(label: 'DAMALS'),
       right = right ?? CompareSide(label: 'HEUTE'),
       backgrounds = backgrounds ?? {},
       geom = geom ?? {};

  CompareSide left;
  CompareSide right;

  /// Eigener Hintergrund je Format (data:-URL); fehlt er, gilt der
  /// Standard-Hintergrund in Vereinsfarben.
  final Map<String, String> backgrounds;
  final Map<String, CompareGeom> geom;

  /// Aktives Format ('f' | 's' | 'p').
  String format;

  /// Rahmen um die Fotos zeichnen (aus, wenn sie im Hintergrund stecken).
  bool frames;
  String frameColor;

  /// Rahmenstärke in logischen Punkten (Grafikbreite 360).
  double frameWidth;

  /// Beschriftung unter den Fotos zeigen.
  bool labels;

  /// Faktor für die Schriftgröße der Beschriftung.
  double labelSize;

  /// Gestaltung der Beschriftung (TextLook als JSON).
  Map<String, dynamic>? labelLook;

  /// Gestaltung der Texte über den Fotos (TextLook als JSON).
  Map<String, dynamic>? topLook;

  CompareSide side(int i) => i == 0 ? left : right;

  CompareGeom geomOf(String f) =>
      geom.putIfAbsent(f, () => CompareGeom.defaults(f));

  CompareGeom get current => geomOf(format);

  void swapSides() {
    final l = left;
    left = right;
    right = l;
    // Beschriftungen bleiben an ihrem Platz (damals links, heute rechts).
    final ll = left.label;
    left.label = right.label;
    right.label = ll;
  }

  /// Hintergrund für alle Formate setzen, die noch keinen eigenen haben
  /// (bzw. denselben wie das aktuelle Format) – oder nur fürs aktuelle.
  void setBackground(String? url, {bool allFormats = true}) {
    final old = backgrounds[format];
    if (allFormats) {
      for (final f in kCompareFormats) {
        final b = backgrounds[f];
        if (f == format || b == null || b == old) {
          if (url == null) {
            backgrounds.remove(f);
          } else {
            backgrounds[f] = url;
          }
        }
      }
    } else if (url == null) {
      backgrounds.remove(format);
    } else {
      backgrounds[format] = url;
    }
  }

  Map<String, Object?> toJson() {
    // Gleiche Hintergründe nur einmal speichern (Bilder sind groß).
    final images = <String>[];
    final bgIdx = <String, int>{};
    for (final e in backgrounds.entries) {
      var i = images.indexOf(e.value);
      if (i < 0) {
        images.add(e.value);
        i = images.length - 1;
      }
      bgIdx[e.key] = i;
    }
    return {
      'left': left.toJson(),
      'right': right.toJson(),
      'bgImages': images,
      'bgOf': bgIdx,
      'geom': {for (final e in geom.entries) e.key: e.value.toJson()},
      'format': format,
      'frames': frames,
      'frameColor': frameColor,
      'frameWidth': frameWidth,
      'labels': labels,
      'labelSize': labelSize,
      if (labelLook != null) 'labelLook': labelLook,
      if (topLook != null) 'topLook': topLook,
    };
  }

  static CompareDesign fromJson(Object? v) {
    if (v is! Map) return CompareDesign();
    final images = v['bgImages'] is List
        ? (v['bgImages'] as List).whereType<String>().toList()
        : const <String>[];
    final bgs = <String, String>{};
    if (v['bgOf'] is Map) {
      for (final e in (v['bgOf'] as Map).entries) {
        final i = e.value;
        if (i is int && i >= 0 && i < images.length) {
          bgs[e.key.toString()] = images[i];
        }
      }
    }
    final geom = <String, CompareGeom>{};
    if (v['geom'] is Map) {
      for (final e in (v['geom'] as Map).entries) {
        final f = e.key.toString();
        if (kCompareFormats.contains(f)) {
          geom[f] = CompareGeom.fromJson(e.value, f);
        }
      }
    }
    final fmt = v['format'];
    return CompareDesign(
      left: CompareSide.fromJson(v['left'], label: 'DAMALS'),
      right: CompareSide.fromJson(v['right'], label: 'HEUTE'),
      backgrounds: bgs,
      geom: geom,
      format: fmt is String && kCompareFormats.contains(fmt) ? fmt : 'f',
      frames: v['frames'] != false,
      frameColor: v['frameColor'] is String
          ? v['frameColor'] as String
          : '#FFFFFF',
      frameWidth: _d(v['frameWidth'], 1.2).clamp(0.3, 6.0),
      labels: v['labels'] != false,
      labelSize: _d(v['labelSize'], 1.0).clamp(0.3, 2.5),
      labelLook: v['labelLook'] is Map
          ? Map<String, dynamic>.from(v['labelLook'] as Map)
          : null,
      topLook: v['topLook'] is Map
          ? Map<String, dynamic>.from(v['topLook'] as Map)
          : null,
    );
  }
}

/// Lage des Fotos im Rahmen ([fw]×[fh]) bei Bildgröße [iw]×[ih]: füllend
/// („cover"), mal [zoom], verschoben um [dx]/[dy] (−1 … 1 des Überstands).
/// Liefert (links, oben, Breite, Höhe) relativ zum Rahmen.
(double, double, double, double) compareCoverRect({
  required double fw,
  required double fh,
  required double iw,
  required double ih,
  double zoom = 1,
  double dx = 0,
  double dy = 0,
}) {
  if (iw <= 0 || ih <= 0 || fw <= 0 || fh <= 0) return (0, 0, fw, fh);
  final s = (fw / iw > fh / ih ? fw / iw : fh / ih) * zoom;
  final w = iw * s;
  final h = ih * s;
  final ox = (w - fw) / 2;
  final oy = (h - fh) / 2;
  return (-ox - dx * ox, -oy - dy * oy, w, h);
}

/// Erkennt zwei Foto-Felder (links/rechts) in einem Hintergrundbild, z. B. die
/// schwarzen Rahmen einer Vergleichs-Vorlage: große, einfarbige, rechteckige
/// Flächen je Bildhälfte. Das Bild wird vorher wie in der Grafik („cover") auf
/// [aspect] zugeschnitten. Läuft per `compute` im Isolate.
/// Ergebnis: [lx, ly, lw, lh, rx, ry, rw, rh] relativ (0 … 1) oder null.
List<double>? detectCompareFrames(Map<String, Object> a) {
  final src = img.decodeImage(a['data'] as Uint8List);
  if (src == null) return null;
  final aspect = a['aspect'] as double;
  final ia = src.width / src.height;
  int cx = 0, cy = 0, cw = src.width, ch = src.height;
  if (ia > aspect) {
    cw = (src.height * aspect).round();
    cx = (src.width - cw) ~/ 2;
  } else {
    ch = (src.width / aspect).round();
    cy = (src.height - ch) ~/ 2;
  }
  const w = 240;
  final h = (w / aspect).round();
  final im = img.copyResize(
    img.copyCrop(src, x: cx, y: cy, width: cw, height: ch),
    width: w,
    height: h,
    interpolation: img.Interpolation.average,
  );
  final n = w * h;
  final rr = Int32List(n), gg = Int32List(n), bb = Int32List(n);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final p = im.getPixel(x, y);
      final i = y * w + x;
      rr[i] = p.r.toInt();
      gg[i] = p.g.toInt();
      bb[i] = p.b.toInt();
    }
  }
  int diff(int i, int j) =>
      (rr[i] - rr[j]).abs() + (gg[i] - gg[j]).abs() + (bb[i] - bb[j]).abs();
  // „Flach" = Pixel gleicht allen vier Nachbarn (keine Textur/Kante).
  final flat = List<bool>.filled(n, false);
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      final i = y * w + x;
      flat[i] =
          diff(i, i - 1) <= 9 &&
          diff(i, i + 1) <= 9 &&
          diff(i, i - w) <= 9 &&
          diff(i, i + w) <= 9;
    }
  }
  final seen = List<bool>.filled(n, false);
  final cands = <(int, int, int, int, int)>[]; // count, minX, minY, maxX, maxY
  for (var s = 0; s < n; s++) {
    if (!flat[s] || seen[s]) continue;
    var count = 0, minX = w, minY = h, maxX = 0, maxY = 0;
    final q = Queue<int>()..add(s);
    seen[s] = true;
    while (q.isNotEmpty) {
      final i = q.removeFirst();
      count++;
      final x = i % w, y = i ~/ w;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
      for (final j in [i - 1, i + 1, i - w, i + w]) {
        if (j < 0 || j >= n || seen[j] || !flat[j]) continue;
        if ((j - i).abs() == 1 && j ~/ w != y) continue;
        if (diff(j, s) > 18) continue;
        seen[j] = true;
        q.add(j);
      }
    }
    final bw = maxX - minX + 1, bh = maxY - minY + 1;
    if (count < 0.02 * n) continue;
    if (bw > 0.6 * w || bh < 0.2 * h || bw < 0.1 * w) continue;
    if (count / (bw * bh) < 0.9) continue;
    cands.add((count, minX, minY, maxX, maxY));
  }
  (int, int, int, int, int)? best(bool left) {
    (int, int, int, int, int)? b;
    for (final c in cands) {
      final mid = (c.$2 + c.$4) / 2;
      if (left != (mid < w / 2)) continue;
      if (b == null || c.$1 > b.$1) b = c;
    }
    return b;
  }

  final l = best(true), r = best(false);
  if (l == null || r == null) return null;
  // Rand: gemischte Kantenpixel zählen nicht als flach → leicht aufweiten.
  const pad = 0.7;
  List<double> rect((int, int, int, int, int) c) => [
    ((c.$2 - pad) / w).clamp(0.0, 1.0),
    ((c.$3 - pad) / h).clamp(0.0, 1.0),
    (c.$4 - c.$2 + 1 + 2 * pad) / w,
    (c.$5 - c.$3 + 1 + 2 * pad) / h,
  ];
  return [...rect(l), ...rect(r)];
}
