import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Die vier Fotos eines Spielers im Profil. Jedes Foto wird im ORIGINAL-Format
/// (ohne Zuschnitt) gespeichert und geräteübergreifend synchronisiert; das
/// runde Profilbild (Kader, Listen, Grafiken) ist eine kleine Kopie davon.
enum PlayerPhotoSlot {
  fupa('fupa', 'FuPa', 'Foto von FuPa'),
  own('own', 'FuPa (eigenes)', 'Selbst gemachtes FuPa-Foto'),
  club('club', 'Verein', 'Vereinsfoto'),
  action('action', 'Action', 'Actionfoto');

  const PlayerPhotoSlot(this.key, this.label, this.description);

  final String key;
  final String label;
  final String description;

  static PlayerPhotoSlot? fromKey(String? k) {
    for (final s in values) {
      if (s.key == k) return s;
    }
    return null;
  }
}

/// Zeilen-Art der Spielerfotos in der Design-Tabelle (`announcement_designs`),
/// die als synchronisierter Bildspeicher mitgenutzt wird.
const String kPlayerPhotoKind = 'player_photo';

/// Zeilen-ID eines Spielerfotos ([slot] = Fotofach oder `profile` für die
/// Auswahl des Profilbilds).
String playerPhotoId(String playerId, String slot) =>
    'pphoto:$playerId:$slot';

/// Längste Seite beim Speichern eines gewählten Fotos: groß genug für die
/// Weitergabe in Originalqualität, klein genug für den Cloud-Abgleich.
const int kPlayerPhotoMaxSide = 2560;

/// Bytes einer Data-URL (oder null).
Uint8List? dataUrlBytes(String? dataUrl) {
  if (dataUrl == null || dataUrl.isEmpty) return null;
  final i = dataUrl.indexOf('base64,');
  if (i < 0) return null;
  try {
    return base64Decode(dataUrl.substring(i + 7));
  } catch (_) {
    return null;
  }
}

/// Dateiendung passend zu den Bild-Bytes (jpg/png/webp).
String imageExtension(Uint8List b) {
  if (b.length > 4 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E) {
    return 'png';
  }
  if (b.length > 12 &&
      b[0] == 0x52 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[8] == 0x57 &&
      b[9] == 0x45) {
    return 'webp';
  }
  return 'jpg';
}

/// Gewähltes Foto für die Ablage vorbereiten: Seitenverhältnis bleibt, nur
/// sehr große Fotos werden auf [kPlayerPhotoMaxSide] verkleinert (JPEG 92).
/// Kleine Fotos bleiben byte-genau erhalten. Für `compute`.
String encodeOriginalPhoto(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    return 'data:image/jpeg;base64,${base64Encode(bytes)}';
  }
  final longest = decoded.width > decoded.height
      ? decoded.width
      : decoded.height;
  if (longest <= kPlayerPhotoMaxSide) {
    final ext = imageExtension(bytes);
    final mime = ext == 'jpg' ? 'jpeg' : ext;
    return 'data:image/$mime;base64,${base64Encode(bytes)}';
  }
  final baked = img.bakeOrientation(decoded);
  final resized = baked.width >= baked.height
      ? img.copyResize(baked, width: kPlayerPhotoMaxSide)
      : img.copyResize(baked, height: kPlayerPhotoMaxSide);
  return 'data:image/jpeg;base64,'
      '${base64Encode(img.encodeJpg(resized, quality: 92))}';
}

/// Kleine Kopie (max. 512 px, Seitenverhältnis bleibt) als Profilbild. Das
/// runde Bild schneidet hochkante Fotos von oben aus. Für `compute`.
String? profileThumbFromDataUrl(String dataUrl) {
  final bytes = dataUrlBytes(dataUrl);
  if (bytes == null) return null;
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  final baked = img.bakeOrientation(decoded);
  final small = (baked.width > 512 || baked.height > 512)
      ? (baked.width >= baked.height
            ? img.copyResize(baked, width: 512)
            : img.copyResize(baked, height: 512))
      : baked;
  return 'data:image/jpeg;base64,'
      '${base64Encode(img.encodeJpg(small, quality: 85))}';
}
