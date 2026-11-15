import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_svg/flutter_svg.dart';

/// Sieht [bytes] nach SVG aus (Text, beginnt mit `<svg` bzw. `<?xml`)?
bool looksLikeSvg(Uint8List bytes) {
  final n = math.min(bytes.length, 512);
  final head = String.fromCharCodes(bytes.sublist(0, n)).toLowerCase();
  return head.contains('<svg');
}

/// Rendert ein SVG scharf in ein PNG (längste Kante [maxSize] px, Transparenz
/// bleibt erhalten). Gibt null zurück, wenn das SVG nicht lesbar ist.
Future<Uint8List?> svgToPng(Uint8List svg, {double maxSize = 1200}) async {
  try {
    final info = await vg.loadPicture(SvgBytesLoader(svg), null);
    var w = info.size.width;
    var h = info.size.height;
    if (w <= 0 || h <= 0) {
      w = 512;
      h = 512;
    }
    final scale = maxSize / math.max(w, h);
    final rec = ui.PictureRecorder();
    ui.Canvas(rec)
      ..scale(scale)
      ..drawPicture(info.picture);
    final pic = rec.endRecording();
    final im = await pic.toImage(
      math.max(1, (w * scale).round()),
      math.max(1, (h * scale).round()),
    );
    info.picture.dispose();
    pic.dispose();
    final data = await im.toByteData(format: ui.ImageByteFormat.png);
    im.dispose();
    return data?.buffer.asUint8List();
  } catch (_) {
    return null;
  }
}
