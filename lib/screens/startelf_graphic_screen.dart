import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, Platform;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:open_filex/open_filex.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../models/designer_data.dart';
import '../models/editor_helpers.dart';
import '../models/graphic_anim.dart';
import '../models/graphic_preset.dart';
import '../models/graphic_settings.dart';
import '../models/sponsor.dart';
import '../services/cloud_service.dart';
import '../services/share_service.dart';
import '../services/player_photos.dart';
import '../services/video_export.dart';
import '../state/app_state.dart';
import '../widgets/bg_pattern.dart';
import '../widgets/player_picker_page.dart';
import '../widgets/logo_chip.dart';
import '../widgets/team_logo.dart';
import '../widgets/text_look.dart';
import '../widgets/ai_look.dart';
import 'photo_editor_screen.dart';

/// Globale Bildkorrektur („Profi-Finish") über der fertigen Grafik: wirkt nur
/// auf das Gesamtbild (Ton/Tiefe), verändert KEINE Elemente/Positionen/Inhalte.
/// Regler −100..100 (Farbton −180..180°), Vignette/Fade/Körnung 0..100,
/// Vignetten-Größe/-Weichheit 0..100 (50 = Standard).
class _Grade {
  bool on = false;
  // Basis
  double brightness = 0;
  double contrast = 0;
  double saturation = 0;
  double warmth = 0;
  // Licht
  double exposure = 0;
  double highlights = 0;
  double shadows = 0;
  // Farbe
  double tint = 0;
  double hue = 0;
  double red = 0;
  double green = 0;
  double blue = 0;
  // Effekte
  double fade = 0;
  double grain = 0;
  double vignette = 0;
  double vigSize = 50;
  double vigSoft = 50;
  // Spieler: warmes Licht hinter dem Hauptmotiv (Halo + Leuchtkante) und
  // Farb-/Lichtangleichung des Spielers an den Hintergrund (0..100).
  double glow = 0;
  double match = 0;
  double shade = 0; // Licht & Schatten (Modellierung) 0..100
  double warm = 0; // Wärme/Farbe nur auf dem Spieler (Hautton) 0..100
  double lightDir = -135; // Licht kommt aus dieser Richtung (Grad, -90 = oben)

  /// Alle Regler auf neutral (An/Aus bleibt).
  void resetValues() => applyValues(const {});

  /// Werte setzen; nicht genannte Regler werden neutral.
  void applyValues(Map<String, double> v) {
    brightness = v['brightness'] ?? 0;
    contrast = v['contrast'] ?? 0;
    saturation = v['saturation'] ?? 0;
    warmth = v['warmth'] ?? 0;
    exposure = v['exposure'] ?? 0;
    highlights = v['highlights'] ?? 0;
    shadows = v['shadows'] ?? 0;
    tint = v['tint'] ?? 0;
    hue = v['hue'] ?? 0;
    red = v['red'] ?? 0;
    green = v['green'] ?? 0;
    blue = v['blue'] ?? 0;
    fade = v['fade'] ?? 0;
    grain = v['grain'] ?? 0;
    vignette = v['vignette'] ?? 0;
    vigSize = v['vigSize'] ?? 50;
    vigSoft = v['vigSoft'] ?? 50;
    // Spieler-Anpassung gehört zum Spieler: andere Looks lassen sie stehen.
    glow = v['glow'] ?? glow;
    match = v['match'] ?? match;
    shade = v['shade'] ?? shade;
    warm = v['warm'] ?? warm;
    lightDir = v['lightDir'] ?? lightDir;
  }

  /// Eine Farb-Matrix für alle linearen Regler (live + Export).
  List<double> matrix() => buildGradeMatrix(
    brightness: brightness,
    contrast: contrast,
    saturation: saturation,
    warmth: warmth,
    exposure: exposure,
    highlights: highlights,
    shadows: shadows,
    tint: tint,
    hue: hue,
    red: red,
    green: green,
    blue: blue,
    fade: fade,
  );

  Map<String, Object> toJson() => {
    'on': on,
    'b': brightness,
    'c': contrast,
    's': saturation,
    'w': warmth,
    'vig': vignette,
    'exp': exposure,
    'hl': highlights,
    'sh': shadows,
    'tint': tint,
    'hue': hue,
    'r': red,
    'g': green,
    'bl': blue,
    'fade': fade,
    'grain': grain,
    'vigSize': vigSize,
    'vigSoft': vigSoft,
    'glow': glow,
    'match': match,
    'shade': shade,
    'warm': warm,
    'lightDir': lightDir,
  };

  static _Grade fromJson(Map v) {
    double d(String k, [double def = 0]) => (v[k] as num?)?.toDouble() ?? def;
    return _Grade()
      ..on = v['on'] == true
      ..brightness = d('b')
      ..contrast = d('c')
      ..saturation = d('s')
      ..warmth = d('w')
      ..vignette = d('vig')
      ..exposure = d('exp')
      ..highlights = d('hl')
      ..shadows = d('sh')
      ..tint = d('tint')
      ..hue = d('hue')
      ..red = d('r')
      ..green = d('g')
      ..blue = d('bl')
      ..fade = d('fade')
      ..grain = d('grain')
      ..vigSize = d('vigSize', 50)
      ..vigSoft = d('vigSoft', 50)
      ..glow = d('glow')
      ..match = d('match')
      ..shade = d('shade')
      ..warm = d('warm')
      ..lightDir = d('lightDir', -135);
  }
}

const String kFupaStyleName = 'FuPa-Style';

/// Farbmatrix, die ein Motiv an das Umgebungslicht [light] angleicht: ein Teil
/// [k] (0..1) der Farbe wird durch „Helligkeit × Lichtfarbe" ersetzt → der
/// Spieler bekommt den Farbstich der Szene (wirkt wie im selben Licht
/// fotografiert). Die Lichtfarbe wird auf Luminanz 1 normiert und gedämpft.
List<double> lightMatchMatrix(Color light, double k) {
  const lr = 0.2126, lg = 0.7152, lb = 0.0722;
  final r = light.r, g = light.g, b = light.b;
  final lum = math.max(0.04, lr * r + lg * g + lb * b);
  double norm(double c) => (1 + (c / lum - 1) * 0.45).clamp(0.4, 1.6);
  final cr = norm(r), cg = norm(g), cb = norm(b);
  final kk = k.clamp(0.0, 1.0);
  // Belichtung: Richtung Szenenhelligkeit (dunkel 0.8 … hell 1.15).
  final ex = 1 + kk * ((0.8 + 0.35 * lum.clamp(0.0, 1.0)) - 1);
  List<double> row(double c, int self) => [
    ex * ((self == 0 ? 1 - kk : 0) + kk * c * lr),
    ex * ((self == 1 ? 1 - kk : 0) + kk * c * lg),
    ex * ((self == 2 ? 1 - kk : 0) + kk * c * lb),
    0,
    0,
  ];
  return [...row(cr, 0), ...row(cg, 1), ...row(cb, 2), 0, 0, 0, 1, 0];
}

/// Look-Vorlagen fürs Profi-Finish (Name → Regler; fehlende = neutral).
const List<(String, Map<String, double>)> kGradePresets = [
  // Natürlicher, warmer Studio-Look, Spieler betont: weiches Licht auf der
  // Wand hinter dem Spieler, Spieler leicht ans Licht der Szene angeglichen,
  // warmes Führungslicht + warmer Hautton, dezente Vignette.
  // Für jeden Spieler gleich anwendbar.
  (
    kFupaStyleName,
    {
      'warmth': 4,
      'contrast': 12,
      'saturation': 8,
      'highlights': -4,
      'vignette': 35,
      'vigSize': 55,
      'vigSoft': 75,
      'glow': 60,
      'match': 25,
      'shade': 40,
      'warm': 50,
    },
  ),
  (
    'Matchday kräftig',
    {
      'contrast': 25,
      'saturation': 20,
      'highlights': -12,
      'shadows': -8,
      'vignette': 35,
    },
  ),
  (
    'Kühl & modern',
    {
      'warmth': -28,
      'tint': 6,
      'contrast': 15,
      'saturation': -8,
      'vignette': 25,
    },
  ),
  ('Warm', {'warmth': 30, 'saturation': 10, 'contrast': 8, 'vignette': 20}),
  (
    'Schwarz-Weiß',
    {'saturation': -100, 'contrast': 30, 'vignette': 30, 'grain': 20},
  ),
  (
    'Film-Look',
    {
      'fade': 35,
      'grain': 35,
      'saturation': -15,
      'warmth': 10,
      'contrast': -8,
      'vignette': 25,
    },
  ),
];

/// Alle linearen Profi-Finish-Regler als EINE 4×5-Farbmatrix (für
/// `ColorFilter.matrix`). Reihenfolge: Belichtung → Tiefen/Lichter/Fade →
/// Kontrast/Helligkeit/Wärme/Tönung/RGB → Farbton → Sättigung.
List<double> buildGradeMatrix({
  double brightness = 0,
  double contrast = 0,
  double saturation = 0,
  double warmth = 0,
  double exposure = 0,
  double highlights = 0,
  double shadows = 0,
  double tint = 0,
  double hue = 0,
  double red = 0,
  double green = 0,
  double blue = 0,
  double fade = 0,
}) {
  // a ∘ b (erst b, dann a) für 4×5-Matrizen (Zeile r: a[r*5 .. r*5+4]).
  List<double> mul(List<double> a, List<double> b) {
    final out = List<double>.filled(20, 0);
    for (var r = 0; r < 4; r++) {
      for (var c = 0; c < 5; c++) {
        var v = 0.0;
        for (var k = 0; k < 4; k++) {
          v += a[r * 5 + k] * b[k * 5 + c];
        }
        out[r * 5 + c] = v + (c == 4 ? a[r * 5 + 4] : 0);
      }
    }
    return out;
  }

  // Gleiche Skalierung + Versatz auf R/G/B (Alpha unverändert).
  List<double> lin(
    double s,
    double o, [
    double oR = 0,
    double oB = 0,
    double oG = 0,
  ]) => [
    s,
    0,
    0,
    0,
    o + oR,
    0,
    s,
    0,
    0,
    o + oG,
    0,
    0,
    s,
    0,
    o + oB,
    0,
    0,
    0,
    1,
    0,
  ];

  // 1) Belichtung: ±1 Blende.
  var m = lin(math.pow(2, exposure / 100).toDouble(), 0);
  // 2) Tiefen: + hebt Schwarz an, − vertieft (Weiß bleibt).
  final s = shadows / 100 * 0.22;
  m = mul(
    s >= 0 ? lin(1 - s, 255 * s) : lin(1 / (1 + s), 255 * s / (1 + s)),
    m,
  );
  //    Lichter: + hellt helle Bereiche auf, − dämpft sie (Schwarz bleibt).
  final h = highlights / 100 * 0.22;
  m = mul(lin(h >= 0 ? 1 / (1 - h) : 1 + h, 0), m);
  //    Fade: matter Film-Look (Schwarz angehoben, Weiß leicht gedämpft).
  final f = fade / 100;
  m = mul(lin(1 - 0.24 * f, 255 * 0.18 * f), m);
  // 3) Kontrast/Helligkeit (um Mittelgrau) + Wärme, Tönung, RGB-Balance.
  final c = 1 + (contrast / 100) * 0.9;
  final t = 128 * (1 - c) + (brightness / 100) * 70;
  final w = (warmth / 100) * 22;
  final ti = tint / 100;
  m = mul(
    lin(
      c,
      t,
      w + ti * 10 + red / 100 * 28,
      -w + ti * 10 + blue / 100 * 28,
      -ti * 20 + green / 100 * 28,
    ),
    m,
  );
  // 4) Farbton-Drehung (luminanzerhaltend, wie SVG hueRotate).
  if (hue != 0) {
    final a = hue * math.pi / 180;
    final co = math.cos(a), si = math.sin(a);
    m = mul([
      0.213 + co * 0.787 - si * 0.213,
      0.715 - co * 0.715 - si * 0.715,
      0.072 - co * 0.072 + si * 0.928,
      0,
      0,
      0.213 - co * 0.213 + si * 0.143,
      0.715 + co * 0.285 + si * 0.140,
      0.072 - co * 0.072 - si * 0.283,
      0,
      0,
      0.213 - co * 0.213 - si * 0.787,
      0.715 - co * 0.715 + si * 0.715,
      0.072 + co * 0.928 + si * 0.072,
      0,
      0,
      0,
      0,
      0,
      1,
      0,
    ], m);
  }
  // 5) Sättigung (luminanzbasiert); Fade nimmt etwas Farbe raus.
  final sat = ((1 + (saturation / 100) * 0.9) * (1 - 0.25 * f)).clamp(0.0, 2.0);
  const lr = 0.2126, lg = 0.7152, lb = 0.0722;
  final sr = (1 - sat) * lr, sg = (1 - sat) * lg, sb = (1 - sat) * lb;
  m = mul([
    sr + sat,
    sg,
    sb,
    0,
    0,
    sr,
    sg + sat,
    sb,
    0,
    0,
    sr,
    sg,
    sb + sat,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ], m);
  return m;
}

/// Kachelbares Filmkorn (RGBA-PNG): helle/dunkle Körner mit geringer Deckkraft
/// – wirkt per normalem Überlagern (ohne Mischmodus, überall gleich).
final Uint8List kGrainTile = () {
  final rnd = math.Random(7);
  final im = img.Image(width: 192, height: 192, numChannels: 4);
  for (final p in im) {
    final light = rnd.nextBool();
    final v = light ? 255 : 0;
    p
      ..r = v
      ..g = v
      ..b = v
      ..a = rnd.nextInt(70);
  }
  return Uint8List.fromList(img.encodePng(im));
}();

/// Ein Spieler in der Startelf-Grafik (Nummer + Anzeigename, optional eine
/// Positionsangabe – z.B. „Torwart").
class StartelfPlayer {
  final int? number;
  final String name;
  final String? position;
  const StartelfPlayer(this.number, this.name, {this.position});
}

/// Daten für die Ergebnis-Grafik (Spielstand + Torschützen + Karten je Seite).
/// Wird [StartelfGraphicScreen] optional mitgegeben – dann rendert die Grafik
/// das Ergebnis statt der Startelf. kind der Karte: 'gelb' | 'gelbrot' | 'rot'.
class ResultData {
  final int ownScore;
  final int oppScore;
  final List<({int minute, String name, String? photo})> ownGoals;
  final List<({int minute, String name, String? photo})> oppGoals;
  final List<({int minute, String name, String kind, String? photo})> ownCards;
  final List<({int minute, String name, String kind, String? photo})> oppCards;
  const ResultData({
    required this.ownScore,
    required this.oppScore,
    this.ownGoals = const [],
    this.oppGoals = const [],
    this.ownCards = const [],
    this.oppCards = const [],
  });
}

/// Daten für die Spielankündigungs-Grafik (Überschrift „SPIELTAG"). Teams/Logos/
/// Datum/Heim-Auswärts kommen aus den bestehenden Screen-Feldern.
class AnnouncementData {
  final String? matchday;
  final String? competition;
  final String? venue; // Spielstätte (z.B. „Sportplatz Tiefenbroich")
  final String? address; // Adresse (z.B. „Sohlstättenstr., 40880 Ratingen")
  const AnnouncementData({
    this.matchday,
    this.competition,
    this.venue,
    this.address,
  });

  bool get isCup => (competition ?? '').toLowerCase().contains('pokal');
}

/// Platzierung eines hinzugefügten Fotos in der Grafik.
/// posterMain = großes Spielerbild, posterBadge = rundes Zweit-Foto (nur im
/// Spieler-Poster der Spielankündigung).
enum _PhotoPlace { background, band, posterMain, posterBadge }

/// Stil der Spielankündigung: zentriert (bisher) oder Spieler-Poster.

/// Höhenanteil des großen Spielerbilds im Poster (unterer, randabfallender Teil).
/// Steuert zugleich das Zuschnitt-Seitenverhältnis (WYSIWYG).
const double _kPosterMainHeightFactor = 0.68;

/// Standard-Positionen (normiert 0..1) der frei verschiebbaren Poster-Elemente.
const Map<String, Offset> _kPosterItemDefaults = {
  'player': Offset(0.5, 0.72),
  'sponsor': Offset(0.76, 0.08),
  'sponsortext': Offset(0.3, 0.085),
  'logos': Offset(0.5, 0.18),
  'headline': Offset(0.5, 0.30),
  'info': Offset(0.5, 0.38),
  'sponsorbar': Offset(0.5, 0.93),
};

/// Default-Positionen für das „Zentriert"-Preset (mittig gestapelt, kein großes
/// Spielerbild im Fokus).
const Map<String, Offset> _kCenteredItemDefaults = {
  'player': Offset(0.5, 0.80),
  'sponsor': Offset(0.76, 0.18),
  'sponsortext': Offset(0.3, 0.185),
  'headline': Offset(0.5, 0.40),
  'logos': Offset(0.5, 0.56),
  'info': Offset(0.5, 0.72),
  'sponsorbar': Offset(0.5, 0.90),
};

/// Default-Positionen, wenn das Spielerfoto weich eingeblendet ist: Foto
/// unten randlos, Texte oben über dem auslaufenden Fotorand – das Gesicht
/// bleibt frei (Align-Semantik: 0 = oben bündig, 1 = unten bündig).
const Map<String, Offset> _kBlendItemDefaults = {
  'sponsor': Offset(0.76, 0.03),
  'sponsortext': Offset(0.3, 0.04),
  'logos': Offset(0.5, 0.11),
  'headline': Offset(0.5, 0.255),
  'info': Offset(0.5, 0.345),
  'sponsorbar': Offset(0.5, 0.98),
};

/// Grundposition der Spielankündigung je Format ('s' = Story, 'p' = Post):
/// Mittelpunkt (normiert 0..1, Mittelpunkt-Semantik) + Größe. Vom Trainer so
/// gestaltet und als Standard für jede neue Ankündigung übernommen.
const Map<String, Map<String, ({Offset pos, double scale})>>
_kAnnouncementLayout = {
  's': {
    'sponsortext': (pos: Offset(0.437, 0.040), scale: 1.0),
    'sponsor': (pos: Offset(0.655, 0.040), scale: 1.0),
    'headline': (pos: Offset(0.504, 0.122), scale: 1.0),
    'info': (pos: Offset(0.514, 0.185), scale: 0.79),
    'logos': (pos: Offset(0.527, 0.246), scale: 0.888),
  },
  'p': {
    'sponsortext': (pos: Offset(0.459, 0.047), scale: 1.0),
    'sponsor': (pos: Offset(0.642, 0.053), scale: 1.0),
    'logos': (pos: Offset(0.747, 0.187), scale: 0.841),
    'headline': (pos: Offset(0.732, 0.312), scale: 0.632),
    'info': (pos: Offset(0.733, 0.369), scale: 0.531),
  },
};

/// Grundgröße der Startelf-Kästen je Format (vom Trainer festgelegt,
/// Vorbild: Startelf gegen DSC 99 Düsseldorf, 15.11.2026).
const Map<String, Map<String, Size>> _kStartelfBoxDefaults = {
  'p': {'std_lineup': Size(342.7, 148.8)},
};

/// Grundposition (Verschiebung in Grafik-Punkten) der festen Startelf-Teile je
/// Format – vom Trainer gestaltet (Startelf gegen DSC 99, 15.11.2026) und als
/// Standard für jede neue bzw. zurückgesetzte Startelf übernommen.
const Map<String, Map<String, Offset>> _kStartelfOffDefaults = {
  'p': {
    'std_info': Offset(-1.4, 27.7),
    'std_lineup': Offset(-0.7, 5.1),
    'std_title': Offset(-1.4, 30.4),
    'std_vs': Offset(-1.4, 31.7),
  },
  's': {
    'std_info': Offset(2.9, 14.9),
    'std_logo': Offset(-4.8, -1.2),
    'std_sponsor': Offset(4.4, -0.1),
    'std_title': Offset(-1.3, 21.9),
    'std_vs': Offset(-2.7, 17.4),
  },
};

/// Startwerte nach dem Freistellen: weiche Kante + „Rand verschmelzen".
const double _kCutoutFeather = 30;
const double _kCutoutRim = 45;

/// ID der team-weiten Hintergrund-Vorlage für FuPa-Fotos.
const String _kFupaBgId = 'fupa-background';

/// Zweiter FuPa-Hintergrund: Verlauf in den Vereinsfarben (ohne Bild).
const String _kFupaBgClubId = 'fupa-background-club';

/// Hintergrund einer Vorlage auf Grafik-Einstellungen legen (nur Look).
GraphicSettings _withPreset(GraphicSettings s, GraphicPreset p) => s.copyWith(
  bgImage: p.bgImage,
  clearBgImage: p.bgImage == null,
  gradTop: p.gradTop,
  gradBottom: p.gradBottom,
  overlayOpacity: p.overlayOpacity,
  bgOpacity: p.bgOpacity,
  bgBlend: p.bgBlend,
  accent: p.accent,
  clearAccent: p.accent == null,
);

/// „Präsentiert von"-Texte als eigene, editierbare Objekte.
const List<String> _kSponsorTextIds = [
  'sponsortext',
  'std_sponsor_text',
  'std_ft_sponsor_text',
];

/// Feste Texte mit vollem Text-Menü (Schrift/Farbe/Schatten/Ausrichtung):
/// Poster-Titel, Überschrift Startelf/Ergebnis, ENDSTAND-Titel, Datumszeile.
const List<String> _kStyledFixedTextIds = [
  'headline',
  'std_title',
  'std_ft_title',
  'std_info',
];

/// Textfarben für eigene Textfelder (key → Anzeigename).
const Map<String, String> _kTextColors = {
  'white': 'Weiß',
  'accent': 'Akzent',
  'black': 'Schwarz',
};

/// Auswählbare Schriftarten für die Poster-Texte (key → Anzeigename).
const Map<String, String> _kPosterFonts = {
  'standard': 'Standard',
  'anton': 'Anton',
  'antonio': 'Antonio',
  'staat': 'Staatliches',
  'fjalla': 'Fjalla One',
  'oswald': 'Oswald',
  'barlow': 'Barlow Condensed',
  'archivo': 'Archivo',
  'bebas': 'Bebas Neue',
  'teko': 'Teko',
  'russo': 'Russo One',
};

/// Entfernt einen einfarbigen Hintergrund (Studio/Einfarb) per Flood-Fill von
/// den Bildrändern: Pixel, die der Eckfarbe ähneln, werden transparent. Läuft in
/// einem Isolate (`compute`), damit die UI nicht hängt. Gibt PNG mit Alpha zurück.
/// Normalisiert gewählte Bild-Bytes (im Isolate): dekodieren, auf [maxSize] px
/// längste Kante verkleinern und als PNG (mit Alpha) bzw. JPEG neu kodieren.
/// Nötig, weil manche Quellen (Google Fotos / sehr große Originale) Formate oder
/// Auflösungen liefern, die der Zuschnitt-Editor nicht direkt rendert (→ schwarz).
/// Scheitert die Dekodierung (z.B. HEIC), bleiben die Bytes unverändert.
/// [args] = {data: Uint8List, keepAlpha: bool, maxSize: int}.
Uint8List normalizeImageBytes(Map<String, dynamic> args) {
  final data = args['data'] as Uint8List;
  final keepAlpha = args['keepAlpha'] as bool? ?? false;
  final maxSize = args['maxSize'] as int? ?? 2000;
  final im = img.decodeImage(data);
  if (im == null) return data;
  var out = im;
  final longer = im.width >= im.height ? im.width : im.height;
  if (longer > maxSize) {
    out = im.width >= im.height
        ? img.copyResize(im, width: maxSize)
        : img.copyResize(im, height: maxSize);
  }
  // PNG nur, wenn wirklich transparente Pixel da sind (Freisteller). Ein
  // deckendes Foto als PNG ist ein Vielfaches größer als JPEG – das machte
  // gespeicherte Designs riesig.
  final alpha = keepAlpha && out.hasAlpha && hasTransparentPixels(out);
  return Uint8List.fromList(
    alpha ? img.encodePng(out) : img.encodeJpg(out, quality: 90),
  );
}

/// Bild für die KI vorbereiten (Isolate): längste Seite ≤ 1280 px, Transparenz
/// auf Weiß gelegt, als JPEG – klein und schnell zu übertragen.
Uint8List downscaleForAi(Uint8List input) => _downscaleJpeg(input, 1280, 90);

/// Fürs Freistellen kleiner (1024 px, Q85): schnellerer Upload und kürzere
/// KI-Laufzeit → weniger Abbrüche unterwegs; die Qualität reicht für FuPa.
Uint8List downscaleForCutout(Uint8List input) =>
    _downscaleJpeg(input, 1024, 85);

/// KI-Hintergrund kompakt speichern (Isolate): JPEG, längste Seite 1600 px.
Uint8List _aiBgJpeg(Uint8List input) => _downscaleJpeg(input, 1600, 85);

Uint8List _downscaleJpeg(Uint8List input, int maxSide, int quality) {
  final src = img.decodeImage(input);
  if (src == null) return input;
  final longer = math.max(src.width, src.height);
  final im = longer > maxSide
      ? (src.width >= src.height
            ? img.copyResize(src, width: maxSide)
            : img.copyResize(src, height: maxSide))
      : src;
  final flat = img.Image(width: im.width, height: im.height)
    ..clear(img.ColorRgb8(255, 255, 255));
  img.compositeImage(flat, im);
  return Uint8List.fromList(img.encodeJpg(flat, quality: quality));
}

/// Hat das Bild mindestens einen (fast) durchsichtigen Pixel?
bool hasTransparentPixels(img.Image im) {
  if (!im.hasAlpha) return false;
  for (final p in im) {
    if (p.a < 250) return true;
  }
  return false;
}

/// Bildeffekte für ein (freigestelltes) Bild, im Isolate:
/// - weiche Kanten (Alpha schrumpfen + weichzeichnen, [feather] 0..100)
/// - gerichteter innerer Schatten ([inner] 0..100, Richtung [angle] im Bogenmaß).
/// - Rand verschmelzen ([rim] 0..100): rundum weich ausblenden + leicht
///   abdunkeln → das Motiv wirkt wie IM Hintergrund statt aufgeklebt.
/// [args] = {data: Uint8List, feather, inner, angle, rim}.
Uint8List applyImageFx(Map<String, dynamic> args) {
  final input = args['data'] as Uint8List;
  final feather = (args['feather'] as num).toDouble();
  final inner = (args['inner'] as num).toDouble();
  final angle = (args['angle'] as num).toDouble();
  final rim = ((args['rim'] as num?) ?? 0).toDouble();
  if (feather <= 0 && inner <= 0 && rim <= 0) return input;
  final src = img.decodeImage(input);
  if (src == null) return input;
  final im = src.convert(numChannels: 4);
  final w = im.width, h = im.height;
  if (w < 2 || h < 2) return input;
  // Arbeits-Alpha als 1-Kanal-Bild.
  final aImg = img.Image(width: w, height: h, numChannels: 1);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      aImg.setPixelR(x, y, im.getPixel(x, y).a);
    }
  }
  // 1) Weiche Kanten: Alpha weichzeichnen + nach innen ziehen.
  if (feather > 0) {
    // Radius mit der Bildgröße skalieren (~1000 px: 30 → ~7 px, 100 → ~18 px),
    // sonst wirkt die Kante bei großen Fotos hart wie ausgeschnitten.
    final scale = math.max(w, h) / 1000;
    final f = feather / 100;
    final radius = math.max(1, ((2.5 + f * 16) * scale).round());
    final blurred = img.gaussianBlur(aImg, radius: radius);
    // Leicht nach innen (helle Reste des alten Hintergrunds verschwinden) und
    // ein BREITER, weicher Übergang statt einer scharfen Linie.
    final lo = 0.12 + f * 0.18;
    final hi = math.min(0.98, lo + 0.5 + f * 0.2);
    // Bildrand-Ring NICHT ausblenden – sonst würde der Rechteck-Rand (bzw. ein
    // am Rand anliegender Spieler) weich statt nur der echte, freigestellte Umriss.
    final border = radius + 1;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final p = im.getPixel(x, y);
        final origA = p.a.toInt();
        int na;
        if (x < border || y < border || x >= w - border || y >= h - border) {
          na = origA;
        } else {
          final bn = blurred.getPixel(x, y).r / 255.0;
          var t = (bn - lo) / (hi - lo);
          if (t < 0) {
            t = 0;
          } else if (t > 1) {
            t = 1;
          }
          t = t * t * (3 - 2 * t); // natürlicher Verlauf (smoothstep)
          na = (t * 255).round();
        }
        im.setPixelRgba(x, y, p.r.toInt(), p.g.toInt(), p.b.toInt(), na);
        aImg.setPixelR(x, y, na);
      }
    }
  }
  // 2) Gerichteter innerer Schatten: Kantenband auf einer Seite abdunkeln.
  if (inner > 0) {
    final d = (4 + inner / 100 * 34).round();
    final dx = (math.cos(angle) * d).round();
    final dy = (math.sin(angle) * d).round();
    final bandImg = img.Image(width: w, height: h, numChannels: 1);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final a0 = aImg.getPixel(x, y).r.toInt();
        final sx = x + dx, sy = y + dy;
        // Außerhalb des Bildes = wie der eigene Alpha-Wert (Replikat) → KEIN
        // künstliches Band am Rechteck-Rand, nur echte (interne) Umriss-Kanten.
        final a1 = (sx < 0 || sy < 0 || sx >= w || sy >= h)
            ? a0
            : aImg.getPixel(sx, sy).r.toInt();
        final b = a0 - a1;
        bandImg.setPixelR(x, y, b < 0 ? 0 : b);
      }
    }
    final blurBand = img.gaussianBlur(
      bandImg,
      radius: (d / 2).round().clamp(1, 30),
    );
    final strength = 0.15 + inner / 100 * 0.75;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        if (aImg.getPixel(x, y).r.toInt() == 0) continue;
        final bn = blurBand.getPixel(x, y).r / 255.0;
        final f = 1 - bn * strength;
        final p = im.getPixel(x, y);
        im.setPixelRgba(
          x,
          y,
          (p.r.toInt() * f).round().clamp(0, 255),
          (p.g.toInt() * f).round().clamp(0, 255),
          (p.b.toInt() * f).round().clamp(0, 255),
          p.a.toInt(),
        );
      }
    }
  }
  // 3) Rand verschmelzen: rundum (ohne Richtung) – je näher am Umriss, desto
  //    durchsichtiger und dunkler. Der Bildrand (z. B. unten abgeschnittener
  //    Körper) zählt nicht als Umriss.
  if (rim > 0) {
    final radius = (3 + rim / 100 * 22).round();
    // Außen am Bildrand „deckend" annehmen → kein Effekt am Rechteck-Rand.
    final pad = radius * 2;
    final ext = img.Image(
      width: w + 2 * pad,
      height: h + 2 * pad,
      numChannels: 1,
    );
    for (var y = 0; y < ext.height; y++) {
      for (var x = 0; x < ext.width; x++) {
        final sx = (x - pad).clamp(0, w - 1), sy = (y - pad).clamp(0, h - 1);
        ext.setPixelR(x, y, aImg.getPixel(sx, sy).r);
      }
    }
    final bl = img.gaussianBlur(ext, radius: radius);
    final fade = 0.15 + rim / 100 * 0.55; // Durchsicht am Umriss
    // Kaum abdunkeln – sonst entsteht ein schwarzer Ring um den Spieler; das
    // Verschmelzen kommt aus dem weichen Ausblenden.
    final dark = rim / 100 * 0.06;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final p = im.getPixel(x, y);
        final a = p.a.toInt();
        if (a == 0) continue;
        final b = bl.getPixel(x + pad, y + pad).r / 255.0;
        // 0 tief im Motiv … 1 direkt am Umriss.
        var e = (1 - b) * 2;
        if (e <= 0) continue;
        if (e > 1) e = 1;
        e = e * e * (3 - 2 * e); // weicher Verlauf
        final f = 1 - dark * e;
        im.setPixelRgba(
          x,
          y,
          (p.r.toInt() * f).round().clamp(0, 255),
          (p.g.toInt() * f).round().clamp(0, 255),
          (p.b.toInt() * f).round().clamp(0, 255),
          (a * (1 - fade * e)).round().clamp(0, 255),
        );
      }
    }
  }
  return Uint8List.fromList(img.encodePng(im));
}

final _photoInfoCache = <String, ({double aspect, bool opaque})>{};

/// Seitenverhältnis (Breite/Höhe) eines Fotos und ob es undurchsichtig ist
/// (JPEG oder PNG ohne transparente Pixel → „rechteckiges Foto", das weich ins
/// Bild eingeblendet werden kann). Zwischengespeichert je Bild.
({double aspect, bool opaque}) photoInfo(Uint8List bytes) {
  var h = bytes.length;
  final step = math.max(1, bytes.length ~/ 64);
  for (var i = 0; i < bytes.length; i += step) {
    h = (h * 31 + bytes[i]) & 0x3fffffff;
  }
  final key = '${bytes.length}:$h';
  final c = _photoInfoCache[key];
  if (c != null) return c;
  var res = (aspect: 0.75, opaque: false);
  try {
    final isJpeg = bytes.length > 2 && bytes[0] == 0xFF && bytes[1] == 0xD8;
    if (isJpeg) {
      final info = img.findDecoderForData(bytes)?.startDecode(bytes);
      if (info != null && info.width > 0 && info.height > 0) {
        res = (aspect: info.width / info.height, opaque: true);
      }
    } else {
      final im = img.decodeImage(bytes);
      if (im != null && im.width > 0 && im.height > 0) {
        res = (aspect: im.width / im.height, opaque: !hasTransparentPixels(im));
      }
    }
  } catch (_) {}
  _photoInfoCache[key] = res;
  return res;
}

/// Eintrag im Tore-Zeitstrahl (Position + Beschriftungs-Etage).
typedef _TlEntry = ({
  int minute,
  String name,
  String? photo,
  double cx,
  double left,
  double lw,
  int level,
});

/// ENDSTAND-Grafik: Kurzname eines Torschützen – „#7 Ben Kania" → „B. KANIA".
/// Unbekannte Torschützen („Gegner", leer) → '' (es werden nur Minuten gezeigt).
String scorerShortName(String raw) {
  final n = raw.trim().replaceFirst(RegExp(r'^#\d+\s*'), '').trim();
  final low = n.toLowerCase();
  // „Gegner" / „Tor" (eigenes Tor ohne Schützen) / leer → unbekannt.
  if (n.isEmpty || low == 'gegner' || low == 'unbekannt' || low == 'tor') {
    return '';
  }
  final parts = n.split(RegExp(r'\s+'));
  if (parts.length == 1) return parts.first.toUpperCase();
  final last = parts.sublist(1).join(' ').toUpperCase();
  return '${parts.first.substring(0, 1).toUpperCase()}. $last';
}

/// ENDSTAND-Grafik: Tore je Spieler zusammenfassen (Reihenfolge = erstes Tor),
/// Minuten aufsteigend – z. B. („B. KANIA", [35, 40, 54, 60]).
List<({String label, List<int> minutes})> groupScorers(
  List<({int minute, String name, String? photo})> goals,
) {
  final order = <String>[];
  final byLabel = <String, List<int>>{};
  for (final g in goals) {
    final label = scorerShortName(g.name);
    byLabel
        .putIfAbsent(label, () {
          order.add(label);
          return <int>[];
        })
        .add(g.minute);
  }
  return [for (final l in order) (label: l, minutes: byLabel[l]!..sort())];
}

/// KI-Look: leere, einfarbige Leinwand im Zielformat (Gemini übernimmt das
/// Format eines mitgeschickten Bildes). [a] = {'w', 'h', 'magenta'}.
Uint8List lookCanvasPng(Map<String, Object> a) {
  final im = img.Image(width: a['w'] as int, height: a['h'] as int);
  final magenta = a['magenta'] == true;
  im.clear(magenta ? img.ColorRgb8(255, 0, 255) : img.ColorRgb8(0, 0, 0));
  return Uint8List.fromList(img.encodePng(im));
}

/// KI-Look „Leuchtend": schwarzer Grund → transparent (Luma-Key). Helle Deko
/// bleibt deckend, dunkle wird durchscheinend – wirkt wie eine Screen-Mischung,
/// ist aber ein echtes PNG mit Alpha (funktioniert über allen Ebenen/Export).
Uint8List lumaKeyBlack(Uint8List input) {
  final src = img.decodeImage(input);
  if (src == null) return input;
  final im = src.convert(numChannels: 4);
  for (final p in im) {
    final r = p.r.toDouble(), g = p.g.toDouble(), b = p.b.toDouble();
    final m = math.max(r, math.max(g, b));
    if (m <= 12) {
      // Fast-Schwarz (inkl. Kompressionsrauschen) komplett weg.
      p.a = 0;
      continue;
    }
    // Deckkraft = Helligkeit; Farbe „entmultipliziert" → gleiche Wirkung.
    final alpha = m / 255.0;
    p
      ..r = (r / alpha).clamp(0, 255)
      ..g = (g / alpha).clamp(0, 255)
      ..b = (b / alpha).clamp(0, 255)
      ..a = m;
  }
  return Uint8List.fromList(img.encodePng(im));
}

/// KI-Look „Freigestellt": Magenta-Grund (#FF00FF) → transparent. Globaler
/// Farbabstand mit weicher Kante + Entfärben des Magenta-Saums (Despill).
/// Anders als [removeUniformBackground] auch für eingeschlossene Flächen.
Uint8List chromaKeyMagenta(Uint8List input) {
  final src = img.decodeImage(input);
  if (src == null) return input;
  final im = src.convert(numChannels: 4);
  final preTaint = Float32List(im.width * im.height);
  const inner = 70.0; // bis hier: komplett transparent
  const outer = 150.0; // ab hier: voll deckend
  for (final p in im) {
    if (p.a == 0) continue;
    final r = p.r.toDouble(), g = p.g.toDouble(), b = p.b.toDouble();
    // 1) Abstand zu reinem Magenta (helle Flächen).
    final dr = 255 - r, db = 255 - b;
    final dist = math.sqrt(dr * dr + g * g + db * db);
    var keep = ((dist - inner) / (outer - inner)).clamp(0.0, 1.0);
    // 2) Farbton (auch abgedunkeltes/schattiges Magenta, z. B. zwischen Arm
    //    und Körper): Rot UND Blau deutlich über Grün, beide ähnlich stark.
    final hi = math.max(r, b), lo = math.min(r, b);
    if (hi > 40 && lo / hi > 0.5) {
      final m = (lo - g) / hi; // 1 = reines Magenta, ≤0 = kein Magenta
      // ≥0.55 → weg, ≤0.30 → bleibt, dazwischen weich.
      final hueKeep = ((0.55 - m) / 0.25).clamp(0.0, 1.0);
      keep = math.min(keep, hueKeep);
    }
    if (keep <= 0) {
      p.a = 0;
      continue;
    }
    // Kante: teiltransparent + Magenta-Stich abziehen. Wie stark der Pixel
    // verunreinigt war, merken: [_despillMagentaEdges] gibt ihm danach die
    // ECHTE Umgebungsfarbe (bloßes Abziehen ließ einen dunkelroten Saum).
    if (keep < 1) {
      final spill = lo - g;
      if (spill > 0) {
        preTaint[p.y * im.width + p.x] = _magentaTaint(r, g, b);
        p
          ..r = (r - spill).clamp(0, 255)
          ..b = (b - spill).clamp(0, 255);
      }
      p.a = (p.a * keep).round();
    }
  }
  _removeSmallIslands(im);
  _despillMagentaEdges(im, preTaint: preTaint);
  return Uint8List.fromList(img.encodePng(im));
}

/// Wie stark ist eine Farbe mit Magenta verunreinigt (0..1)? Haare/Haut haben
/// Blau ≤ Grün → 0; Mischungen mit Magenta-Grund dagegen > 0.
double _magentaTaint(double r, double g, double b) {
  final hi = math.max(r, b);
  if (hi <= 0) return 0;
  final sp = math.min(r, b) - g;
  return sp <= 0 ? 0 : (sp / (0.22 * hi)).clamp(0.0, 1.0);
}

/// Kleine, abgetrennte Reste außerhalb des Motivs (z. B. ein rosa Fleck in
/// der Ecke) entfernen: zusammenhängende sichtbare Flächen, die kleiner als
/// 2 % der größten Fläche sind, werden durchsichtig.
void _removeSmallIslands(img.Image im) {
  final w = im.width, h = im.height;
  final label = Int32List(w * h);
  final sizes = <int>[0];
  final stack = <int>[];
  for (var start = 0; start < w * h; start++) {
    if (label[start] != 0) continue;
    if (im.getPixel(start % w, start ~/ w).a < 128) continue;
    final id = sizes.length;
    var count = 0;
    label[start] = id;
    stack.add(start);
    while (stack.isNotEmpty) {
      final i = stack.removeLast();
      count++;
      final x = i % w, y = i ~/ w;
      void visit(int nx, int ny) {
        if (nx < 0 || ny < 0 || nx >= w || ny >= h) return;
        final j = ny * w + nx;
        if (label[j] != 0) return;
        if (im.getPixel(nx, ny).a < 128) return;
        label[j] = id;
        stack.add(j);
      }

      visit(x + 1, y);
      visit(x - 1, y);
      visit(x, y + 1);
      visit(x, y - 1);
    }
    sizes.add(count);
  }
  if (sizes.length <= 2) return; // höchstens eine Fläche
  final biggest = sizes.reduce(math.max);
  final minKeep = biggest * 0.02;
  for (final p in im) {
    if (p.a == 0) continue;
    final l = label[p.y * w + p.x];
    if (l != 0 && sizes[l] < minKeep) p.a = 0;
  }
}

/// Rosa Saum an der Freistell-Kante entfernen (v. a. Haare): Alle sichtbaren
/// Pixel bis [radius] px von einer durchsichtigen Stelle entfernt verlieren
/// ihren Magenta-Stich (Rot/Blau über Grün → auf Grün-Niveau). Direkt an der
/// Kante werden stark magentafarbene Pixel zusätzlich ausgedünnt. Pixel tief
/// im Motiv (z. B. ein pinkes Trikot-Detail) bleiben unverändert.
void _despillMagentaEdges(img.Image im, {int? radius, Float32List? preTaint}) {
  final w = im.width, h = im.height;
  if (w < 3 || h < 3) return;
  // Radius mit der Bildgröße skalieren (~1024 px → 26 px): lockige Haare
  // sind eine BREITE Kante mit vielen Magenta-Lücken.
  final r = radius ?? math.max(6, (math.max(w, h) / 40).round());
  final dist = Uint8List(w * h)..fillRange(0, w * h, 255);
  final rr0 = math.min(r, 250);
  final queue = <int>[];
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (im.getPixel(x, y).a < 128) {
        final i = y * w + x;
        dist[i] = 0;
        queue.add(i);
      }
    }
  }
  if (queue.isEmpty) return;
  // Breitensuche bis [r] (4er-Nachbarschaft).
  var head = 0;
  while (head < queue.length) {
    final i = queue[head++];
    final d = dist[i];
    if (d >= rr0) continue;
    final x = i % w, y = i ~/ w;
    void visit(int nx, int ny) {
      if (nx < 0 || ny < 0 || nx >= w || ny >= h) return;
      final j = ny * w + nx;
      if (dist[j] <= d + 1) return;
      dist[j] = d + 1;
      queue.add(j);
    }

    visit(x + 1, y);
    visit(x - 1, y);
    visit(x, y + 1);
    visit(x, y - 1);
  }
  // Verunreinigung (0..1) eines Pixels mit Magenta.
  double taint(img.Pixel p) => math.max(
    _magentaTaint(p.r.toDouble(), p.g.toDouble(), p.b.toDouble()),
    preTaint == null ? 0.0 : preTaint[p.y * w + p.x].toDouble(),
  );

  // Rosa, das ZUSAMMENHÄNGEND mit dem freigestellten Hintergrund verbunden ist
  // (Flecken/Strähnen in Locken), egal wie tief – ein rosa Detail mitten im
  // Trikot ist nicht verbunden und bleibt.
  final linked = Uint8List(w * h);
  final q2 = <int>[];
  for (var i = 0; i < w * h; i++) {
    if (dist[i] == 0) q2.add(i);
  }
  var h2 = 0;
  while (h2 < q2.length) {
    final i = q2[h2++];
    final x = i % w, y = i ~/ w;
    void visit(int nx, int ny) {
      if (nx < 0 || ny < 0 || nx >= w || ny >= h) return;
      final j = ny * w + nx;
      if (linked[j] != 0 || dist[j] == 0) return;
      if (taint(im.getPixel(nx, ny)) < 0.3) return;
      linked[j] = 1;
      q2.add(j);
    }

    visit(x + 1, y);
    visit(x - 1, y);
    visit(x, y + 1);
    visit(x, y - 1);
  }

  // „Saubere" Nachbarfarbe (Haare/Haut ohne Magenta-Stich) je Pixel: Summen
  // über ein Fenster per Integralbild → verunreinigte Pixel bekommen die
  // Farbe ihrer Umgebung statt eines rötlichen Rests.
  final k = math.max(4, r ~/ 3);
  final w1 = w + 1;
  final sR = Int32List(w1 * (h + 1)), sG = Int32List(w1 * (h + 1));
  final sB = Int32List(w1 * (h + 1)), sN = Int32List(w1 * (h + 1));
  for (var y = 0; y < h; y++) {
    var rowR = 0, rowG = 0, rowB = 0, rowN = 0;
    for (var x = 0; x < w; x++) {
      final p = im.getPixel(x, y);
      final pr = p.r.toInt(), pg = p.g.toInt(), pb = p.b.toInt();
      if (p.a >= 200 && math.min(pr, pb) - pg <= 4) {
        rowR += pr;
        rowG += pg;
        rowB += pb;
        rowN++;
      }
      final i = (y + 1) * w1 + x + 1, up = y * w1 + x + 1;
      sR[i] = sR[up] + rowR;
      sG[i] = sG[up] + rowG;
      sB[i] = sB[up] + rowB;
      sN[i] = sN[up] + rowN;
    }
  }
  int boxSum(Int32List s, int x0, int y0, int x1, int y1) =>
      s[y1 * w1 + x1] - s[y0 * w1 + x1] - s[y1 * w1 + x0] + s[y0 * w1 + x0];

  for (final p in im) {
    if (p.a == 0) continue;
    final idx = p.y * w + p.x;
    // d = 0: halbdurchsichtiger Randpixel (Haarspitzen) – gerade die zeigen
    // sonst den rötlichen Saum, also mitbehandeln.
    final d = dist[idx];
    // Wie stark ist der Pixel mit Magenta verunreinigt (0..1)? Haare/Haut
    // haben Blau ≤ Grün → kein Spill; Rosa-Reste in Locken dagegen schon.
    final t = taint(p);
    // Mit dem Hintergrund verbundenes Rosa → behandeln, egal wie tief; sonst
    // nur der Randstreifen (Lippen/rote Trikot-Details innen bleiben).
    final isLinked = linked[idx] != 0;
    if (d > rr0 && !isLinked) continue;
    final rr = p.r.toDouble(), g = p.g.toDouble(), b = p.b.toDouble();
    final lo = math.min(rr, b), hi = math.max(rr, b);
    final spill = lo - g;
    if (spill <= 0 && t <= 0) continue;
    // Entfärben: Rot/Blau um den Magenta-Anteil senken (Richtung neutral) …
    var nr = rr, ng = g, nb = b;
    if (spill > 0) {
      nr -= spill;
      nb -= spill;
    }
    // … und je nach Verunreinigung zur sauberen Umgebungsfarbe ziehen.
    final x0 = math.max(0, p.x - k), y0 = math.max(0, p.y - k);
    final x1 = math.min(w, p.x + k + 1), y1 = math.min(h, p.y + k + 1);
    final n = boxSum(sN, x0, y0, x1, y1);
    final a0 = p.a.toInt();
    if (n > 0) {
      final cr = boxSum(sR, x0, y0, x1, y1) / n;
      final cg = boxSum(sG, x0, y0, x1, y1) / n;
      final cb = boxSum(sB, x0, y0, x1, y1) / n;
      nr += (cr - nr) * t;
      ng += (cg - ng) * t;
      nb += (cb - nb) * t;
    }
    p
      ..r = nr.clamp(0, 255)
      ..g = ng.clamp(0, 255)
      ..b = nb.clamp(0, 255);
    // Stark rosa und mit dem Hintergrund verbunden (Fleck auf/über den
    // Haaren) → ausblenden.
    // (Nur deckende Flecken – halbdurchsichtige Haarspitzen behalten ihre
    // Deckkraft, sie haben jetzt die richtige Haarfarbe.)
    if (t > 0.5 && a0 > 200 && (isLinked || d <= rr0 ~/ 2)) {
      p.a = (p.a * (1 - (t - 0.5) * 1.8)).round().clamp(0, 255);
    } else if (n == 0 && d <= 2 && hi > 0 && spill > 0 && spill / hi > 0.2) {
      // Direkt an der Kante + deutlich magenta → leicht ausdünnen (Saum weg).
      p.a = (p.a * (d == 1 ? 0.35 : 0.7)).round();
    }
  }
}

/// Anteil (fast) durchsichtiger Pixel (0..1) – prüft, ob das Freistellen
/// wirklich Hintergrund entfernt hat.
double transparentFraction(Uint8List png) {
  final im = img.decodeImage(png);
  if (im == null || !im.hasAlpha) return 0;
  final small = im.width > 200 ? img.copyResize(im, width: 200) : im;
  var t = 0;
  for (final p in small) {
    if (p.a < 128) t++;
  }
  return t / (small.width * small.height);
}

/// Sieht das Freistellen gelungen aus? Ein echter Freisteller hat einen
/// überwiegend durchsichtigen Bildrand (nur wo der Spieler den Rand berührt,
/// z. B. unten, bleibt er deckend) und insgesamt genug Durchsicht.
bool cutoutLooksDone(Uint8List png) {
  final im = img.decodeImage(png);
  if (im == null || !im.hasAlpha) return false;
  var n = 0, clear = 0;
  void count(int x, int y) {
    n++;
    if (im.getPixel(x, y).a < 128) clear++;
  }

  for (var x = 0; x < im.width; x++) {
    count(x, 0);
    count(x, im.height - 1);
  }
  for (var y = 1; y < im.height - 1; y++) {
    count(0, y);
    count(im.width - 1, y);
  }
  return n > 0 && clear / n >= 0.65 && transparentFraction(png) >= 0.08;
}

/// Nach dem KI-Freistellen: erst Magenta keyen; hat die KI einen ANDEREN
/// Hintergrund geliefert (Rand danach noch überwiegend deckend), zusätzlich
/// die Randfarbe entfernen ([keyBorderBackground]).
Uint8List cutoutFinish(Uint8List input) {
  final keyed = chromaKeyMagenta(input);
  final im = img.decodePng(keyed);
  if (im == null) return keyed;
  var n = 0, opaque = 0;
  void count(int x, int y) {
    n++;
    if (im.getPixel(x, y).a > 200) opaque++;
  }

  for (var x = 0; x < im.width; x++) {
    count(x, 0);
    count(x, im.height - 1);
  }
  for (var y = 0; y < im.height; y++) {
    count(0, y);
    count(im.width - 1, y);
  }
  if (n == 0 || opaque / n < 0.3) return keyed;
  // Nur bei wirklich EINFARBIGEM Rand (z. B. brauner Studio-Grund) die
  // Randfarbe entfernen – bei echten Fotos (Himmel/Wiese/Straße) würde das
  // nur Teile wegschneiden.
  if (!_borderIsUniform(im)) return keyed;
  return keyBorderBackground(keyed);
}

/// Sind ≥ 75 % der deckenden Randpixel nahe ihrer Median-Farbe?
bool _borderIsUniform(img.Image im) {
  final rs = <int>[], gs = <int>[], bs = <int>[];
  void add(int x, int y) {
    final p = im.getPixel(x, y);
    if (p.a < 128) return;
    rs.add(p.r.toInt());
    gs.add(p.g.toInt());
    bs.add(p.b.toInt());
  }

  for (var x = 0; x < im.width; x++) {
    add(x, 0);
    add(x, im.height - 1);
  }
  for (var y = 1; y < im.height - 1; y++) {
    add(0, y);
    add(im.width - 1, y);
  }
  if (rs.isEmpty) return false;
  int med(List<int> v) => (List<int>.from(v)..sort())[v.length ~/ 2];
  final mr = med(rs), mg = med(gs), mb = med(bs);
  var near = 0;
  for (var i = 0; i < rs.length; i++) {
    final dr = rs[i] - mr, dg = gs[i] - mg, db = bs[i] - mb;
    if (dr * dr + dg * dg + db * db <= 40 * 40) near++;
  }
  return near / rs.length >= 0.75;
}

/// Einfarbigen (auch leicht verlaufenden) Hintergrund entfernen: Referenz =
/// Median der deckenden Randpixel. Vom Rand aus zusammenhängend mit weicher
/// Kante, eingeschlossene Flächen derselben Farbe (z. B. zwischen Arm und
/// Körper) streng global.
Uint8List keyBorderBackground(Uint8List input) {
  final src = img.decodeImage(input);
  if (src == null) return input;
  final im = src.convert(numChannels: 4);
  final w = im.width, h = im.height;
  if (w < 3 || h < 3) return input;
  final rs = <int>[], gs = <int>[], bs = <int>[];
  void sample(int x, int y) {
    final p = im.getPixel(x, y);
    if (p.a < 128) return;
    rs.add(p.r.toInt());
    gs.add(p.g.toInt());
    bs.add(p.b.toInt());
  }

  for (var x = 0; x < w; x++) {
    sample(x, 0);
    sample(x, h - 1);
  }
  for (var y = 0; y < h; y++) {
    sample(0, y);
    sample(w - 1, y);
  }
  if (rs.isEmpty) return input;
  int median(List<int> v) => (v..sort())[v.length ~/ 2];
  final br = median(rs), bgc = median(gs), bb = median(bs);
  double dist(img.Pixel p) {
    final dr = p.r - br, dg = p.g - bgc, db = p.b - bb;
    return math.sqrt(dr * dr + dg * dg + db * db).toDouble();
  }

  const inner = 30.0, outer = 62.0, strict = 16.0;
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
    final p = im.getPixel(i % w, i ~/ w);
    if (p.a > 0) {
      final d = dist(p);
      if (d >= outer) continue; // Motiv-Kante → nicht weiter
      final keep = ((d - inner) / (outer - inner)).clamp(0.0, 1.0);
      p.a = (p.a * keep).round();
    }
    final x = i % w, y = i ~/ w;
    push(x + 1, y);
    push(x - 1, y);
    push(x, y + 1);
    push(x, y - 1);
  }
  // Eingeschlossene Reste exakt dieser Farbe.
  for (final p in im) {
    if (p.a > 0 && dist(p) <= strict) p.a = 0;
  }
  return Uint8List.fromList(img.encodePng(im));
}

Uint8List removeUniformBackground(Uint8List input) {
  final src = img.decodeImage(input);
  if (src == null) return input;
  final im = src.convert(numChannels: 4);
  final w = im.width, h = im.height;
  if (w < 2 || h < 2) return input;
  // Referenzfarbe = Mittel der vier Ecken.
  final corners = [
    im.getPixel(0, 0),
    im.getPixel(w - 1, 0),
    im.getPixel(0, h - 1),
    im.getPixel(w - 1, h - 1),
  ];
  var rr = 0, gg = 0, bb = 0;
  for (final p in corners) {
    rr += p.r.toInt();
    gg += p.g.toInt();
    bb += p.b.toInt();
  }
  rr ~/= 4;
  gg ~/= 4;
  bb ~/= 4;
  const tol = 42; // Toleranz je Kanal
  const tol2 = tol * tol * 3;
  final visited = Uint8List(w * h);
  final stack = <int>[];
  void push(int x, int y) {
    if (x < 0 || y < 0 || x >= w || y >= h) return;
    final idx = y * w + x;
    if (visited[idx] != 0) return;
    visited[idx] = 1;
    stack.add(idx);
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
    final idx = stack.removeLast();
    final x = idx % w, y = idx ~/ w;
    final p = im.getPixel(x, y);
    final dr = p.r.toInt() - rr, dg = p.g.toInt() - gg, db = p.b.toInt() - bb;
    if (dr * dr + dg * dg + db * db > tol2) {
      continue; // Kante → nicht überqueren
    }
    im.setPixelRgba(x, y, p.r.toInt(), p.g.toInt(), p.b.toInt(), 0);
    push(x + 1, y);
    push(x - 1, y);
    push(x, y + 1);
    push(x, y - 1);
  }
  return Uint8List.fromList(img.encodePng(im));
}

/// Wendet die gewählte Schriftart auf einen TextStyle an (null = Standard).
TextStyle posterFontStyle(String font, TextStyle base) {
  switch (font) {
    case 'anton':
      return GoogleFonts.anton(textStyle: base);
    case 'antonio':
      return GoogleFonts.antonio(textStyle: base);
    case 'staat':
      return GoogleFonts.staatliches(textStyle: base);
    case 'fjalla':
      return GoogleFonts.fjallaOne(textStyle: base);
    case 'oswald':
      return GoogleFonts.oswald(textStyle: base);
    case 'barlow':
      return GoogleFonts.barlowCondensed(textStyle: base);
    case 'archivo':
      return GoogleFonts.archivoBlack(textStyle: base);
    case 'bebas':
      return GoogleFonts.bebasNeue(textStyle: base);
    case 'teko':
      return GoogleFonts.teko(textStyle: base);
    case 'russo':
      return GoogleFonts.russoOne(textStyle: base);
    default:
      return base;
  }
}

/// Ein zur Grafik hinzugefügtes Foto (Data-URL) mit seiner Platzierung.
/// Transient (nicht gespeichert), gilt für alle Grafiktypen.
class _GraphicPhoto {
  _GraphicPhoto(this.dataUrl, this.place);
  String dataUrl;
  _PhotoPlace place;
}

/// Erzeugt die teilbare Startelf-Grafik im Instagram-Format (Story 9:16 oder
/// Post 1:1). Titel, Logo und Hintergrund sind über ein „Grafik anpassen"-Panel
/// einstellbar (teamweit, cloud-synchron). Sponsoren kommen aus der
/// Sponsoring-Verwaltung. Mit [result] bzw. [announcement] rendert sie statt der
/// Startelf das Ergebnis bzw. die Spielankündigung.
class StartelfGraphicScreen extends StatefulWidget {
  const StartelfGraphicScreen({
    super.key,
    required this.teamName,
    required this.teamLogo,
    required this.starters,
    required this.benchNames,
    this.matchDate,
    this.isHome = true,
    this.opponentName = '',
    this.opponentLogo,
    this.result,
    this.announcement,
    this.teamId,
    this.matchId,
    this.designer,
  });

  /// Gesetzt → Grafik aus dem zentralen Designer (Tor, Spieler des Spiels,
  /// Anlass, frei). Läuft im freien Poster-Editor; gespeichert unter
  /// [DesignerData.id] (auch ohne Spiel).
  final DesignerData? designer;

  /// Default-Titel (offizieller Teamname) und Default-Logo – werden genutzt,
  /// solange in den Grafik-Einstellungen nichts Eigenes hinterlegt ist.
  final String teamName;
  final String? teamLogo;
  final List<StartelfPlayer> starters;
  final List<String> benchNames;

  /// Spielinfos fürs Banner.
  final DateTime? matchDate;
  final bool isHome;
  final String opponentName;
  final String? opponentLogo;

  /// Gesetzt → Ergebnis-Grafik statt Startelf-Grafik.
  final ResultData? result;

  /// Gesetzt → Spielankündigungs-Grafik („SPIELTAG").
  final AnnouncementData? announcement;

  /// Eigene Mannschaft – für die Kader-Auswahl des Spielerbilds im Poster.
  /// null → nur Upload/Kamera als Bildquelle.
  final String? teamId;

  /// Spiel-ID → Spielankündigungs-Design wird je Spiel gespeichert/geladen.
  /// null → kein Speichern (z.B. Startelf/Ergebnis-Grafik).
  final String? matchId;

  bool get isResult => result != null;
  bool get isAnnouncement => announcement != null;

  @override
  State<StartelfGraphicScreen> createState() => _StartelfGraphicScreenState();
}

class _StartelfGraphicScreenState extends State<StartelfGraphicScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  final GlobalKey _boundaryKey = GlobalKey();
  final GlobalKey _bgBoundaryKey = GlobalKey(); // nur die Hintergrund-Ebene
  // Format: 's' = Story 9:16, 'p' = Post 1:1, 'f' = FuPa-Spielerfoto 4:5.
  String _format = 's';
  bool get _story => _format == 's';
  double get _cw =>
      _format == 's' ? _storyW : (_format == 'f' ? _fupaW : _postW);
  double get _ch =>
      _format == 's' ? _storyH : (_format == 'f' ? _fupaH : _postH);
  String get _aiAspect =>
      _format == 's' ? '9:16' : (_format == 'f' ? '4:5' : '1:1');

  /// Designer-Vorlage „FuPa-Foto" (960×1200, nur freigestellter Spieler).
  bool get _isFupa => widget.designer?.template == 'fupa';
  // Spielankündigung: Überschrift-Modus & -Text. Transient je Grafik (kein Sync).
  String _annHeadMode = 'spieltag'; // 'spieltag' | 'auto' | 'custom'
  String _annHeadText = 'SPIELTAG';
  bool _posterLogoDisc = true; // heller Kreis hinter den Logos (Sichtbarkeit)
  bool _posterShadow = false; // Schlagschatten beim freigestellten Spieler
  // Spielerfoto (rechteckig) weich ins Bild einblenden statt als Kasten.
  bool _posterBlend = true;
  double _posterShadowStrength = 45; // 0..100
  double _posterShadowAngle = 45; // Richtung in Grad (0=rechts, 90=unten)
  // Pro Format (Story/Post) ein EIGENES Layout: Spielerbild, Overlays, Texte und
  // Position/Größe/Reihenfolge getrennt (Key `_designKey`). Lazy via putIfAbsent.
  String get _designKey => _format;
  final Map<String, Map<String, Offset>> _posterPosF = {};
  // Element-IDs, deren Position die MITTE angibt (1:1 verschiebbar). Ältere
  // Positionen (Align-Semantik) werden beim ersten Auswählen ohne Sprung
  // umgerechnet.
  final Map<String, Set<String>> _posCenteredF = {};
  // Ergebnis/Startelf: feste Teile (std_*) bleiben an ihrer natürlichen Stelle im
  // Layout und bekommen nur eine Verschiebung (logische px) obendrauf → das
  // Startbild bleibt unverändert. Größe/Drehung liegen in _posterScale/_posterRot.
  final Map<String, Map<String, Offset>> _stdOffF = {};
  final Map<String, Set<String>> _stdHiddenF = {};
  // Kontexte der festen Teile (innen = mit Transform → Treffer-Test; außen =
  // natürliche Lage → Dreh-Griff). Werden beim Bauen der Grafik gefüllt.
  final Map<String, BuildContext> _stdCtx = {};
  final Map<String, BuildContext> _stdNatCtx = {};
  String? _gTarget; // Element der laufenden Zieh-/Pinch-Geste
  Size? _rzStart; // Kasten-Ziehen: Größe beim Packen des Griffs
  Offset _rzAcc =
      Offset.zero; // Kasten-Ziehen: aufsummiertes Delta (Kasten-Achsen)
  final Map<String, Map<String, double>> _posterScaleF = {};
  final Map<String, Map<String, double>> _posterRotF =
      {}; // Drehung (rad) je Elem.
  final Map<String, List<String>> _posterOrderF = {};
  final Map<String, String?> _posterMainF = {};
  final Map<String, List<({String id, String dataUrl})>> _posterOverlaysF = {};
  // KI-Look (Deko-Overlay über der ganzen Grafik) je Format.
  final Map<String, _AiLook> _lookF = {};
  _AiLook? get _look => _lookF[_designKey];
  bool _lookBusy = false; // KI erzeugt gerade einen Look
  // Ziehbare Kästen: feste Größe (logische px) je Element, je Format. Fehlt ein
  // Eintrag, hat der Kasten seine natürliche Größe.
  final Map<String, Map<String, Size>> _boxSizeF = {};
  Map<String, Size> get _boxSize {
    final m = _boxSizeF.putIfAbsent(_designKey, () => <String, Size>{});
    // Startelf ohne eigene Kastengröße (neu oder leer gespeichert): Kader-
    // Kasten in der vom Trainer festgelegten Größe (Post: höher, füllt den
    // unteren Teil). Story nutzt das Grundlayout.
    if (m.isEmpty && _kind == 'Startelf') {
      m.addAll(_kStartelfBoxDefaults[_designKey] ?? const {});
    }
    return m;
  }

  // Ergebnis-Grafik: 'std' (Standard) | 'photo' (ENDSTAND mit Foto oben).
  String _resultLayout = 'std';
  bool get _ftLayout => widget.isResult && _resultLayout == 'photo';
  // ENDSTAND: Foto oben je Format + Ausschnitt (Zoom/Position als 4×4-Matrix).
  final Map<String, String> _ftPhotoF = {};
  final Map<String, List<double>> _ftMatrixF = {};
  final TransformationController _ftCtrl = TransformationController();
  // ENDSTAND: Anteil des Fotos an der Höhe (Trennlinie, im Editor ziehbar).
  final Map<String, double> _ftSplitF = {};
  double get _ftSplit => _ftSplitF[_designKey] ?? (_story ? 0.56 : 0.46);

  /// Foto-Größe (ENDSTAND) setzen – um die Mitte des Foto-Bereichs skalieren,
  /// der bisherige Ausschnitt bleibt sonst erhalten.
  void _setFtScale(double target) {
    final m = _ftCtrl.value;
    final cur = m.getMaxScaleOnAxis();
    if (cur <= 0) return;
    final f = target / cur;
    final w = _cw;
    final areaH = _ch * _ftSplit;
    final cx = w / 2, cy = areaH / 2;
    _ftCtrl.value = Matrix4.translationValues(cx, cy, 0)
        .multiplied(Matrix4.diagonal3Values(f, f, 1))
        .multiplied(Matrix4.translationValues(-cx, -cy, 0))
        .multiplied(m);
    _ftMatrixF[_designKey] = _ftCtrl.value.storage.toList();
  }

  /// Ausschnitt des ENDSTAND-Fotos für das aktuelle Format in den Controller
  /// laden (nach Laden des Designs bzw. Formatwechsel – nie während build).
  void _syncFtCtrl() {
    final m = _ftMatrixF[_designKey];
    _ftCtrl.value = (m != null && m.length == 16)
        ? Matrix4.fromList(m)
        : Matrix4.identity();
  }

  final Map<String, List<String>> _textIdsF = {};
  final Map<String, Map<String, String>> _textContentF = {};
  final Map<String, Map<String, String>> _textFontF = {};
  final Map<String, Map<String, String>> _textColorF = {};
  // Schatten je Text: none | soft | strong | outline | glow.
  final Map<String, Map<String, String>> _textShadowF = {};
  // Ausrichtung der Zeilen je Text: left | center | right.
  final Map<String, Map<String, String>> _textAlignF = {};
  int _posterOverlaySeq = 0; // eindeutige Overlay-IDs (global)
  int _textSeq = 0; // eindeutige Text-IDs (global)
  int _editorSeq = 0; // erzwingt Editor-Neuaufbau (z.B. „Datum auf Auto")
  String? _posterSel; // aktuell ausgewähltes Element (für Größe-Regler)
  Map<String, Offset> get _posterPos {
    _seedAnnouncementLayout();
    return _posterPosF.putIfAbsent(_designKey, () => {});
  }

  Set<String> get _posCentered {
    _seedAnnouncementLayout();
    return _posCenteredF.putIfAbsent(_designKey, () => <String>{});
  }

  /// Neue (oder zurückgesetzte) Spielankündigung: Grundposition der Elemente
  /// wie vom Trainer festgelegt (Story: Sponsor oben, SPIELTAG, Datum, Logos;
  /// Post: Logos + SPIELTAG rechts). Bereits gestaltete Formate bleiben.
  void _seedAnnouncementLayout([String? key]) {
    if (!widget.isAnnouncement || widget.designer != null || _isFupa) return;
    final k = key ?? _designKey;
    final layout = _kAnnouncementLayout[k];
    // Leer gespeichert ({}) = nie verschoben → ebenfalls Grundposition.
    if (layout == null || (_posterPosF[k]?.isNotEmpty ?? false)) return;
    _posterPosF[k] = {for (final e in layout.entries) e.key: e.value.pos};
    _posCenteredF[k] = layout.keys.toSet();
    _posterScaleF[k] = {
      ...?_posterScaleF[k],
      for (final e in layout.entries) e.key: e.value.scale,
    };
  }

  Map<String, Offset> get _stdOff {
    final m = _stdOffF.putIfAbsent(_designKey, () => {});
    // Startelf noch nie verschoben (neu, leer gespeichert oder zurückgesetzt):
    // Grundposition wie vom Trainer festgelegt.
    if (m.isEmpty && _kind == 'Startelf') {
      m.addAll(_kStartelfOffDefaults[_designKey] ?? const {});
    }
    return m;
  }

  Set<String> get _stdHidden =>
      _stdHiddenF.putIfAbsent(_designKey, () => <String>{});

  /// Element [id] um Faktor [f] größer/kleiner (Mausrad, −/+ Knöpfe).
  void _scalePoster(String id, double f) {
    setState(() {
      _posterSel = id;
      _posterScale[id] = ((_posterScale[id] ?? 1.0) * f)
          .clamp(0.2, 6.0)
          .toDouble();
    });
  }

  Map<String, double> get _posterScale =>
      _posterScaleF.putIfAbsent(_designKey, () => {});
  Map<String, double> get _posterRot =>
      _posterRotF.putIfAbsent(_designKey, () => {});
  // Basiswerte beim Start einer Pinch-/Dreh-Geste (kumulativ zum Start rechnen).
  double _gScale0 = 1.0;
  double _gRot0 = 0.0;
  // Ankündigung: strukturelle Standard-Elemente vorbelegt. Ergebnis/Startelf:
  // leer → nur selbst hinzugefügte Elemente liegen über dem festen Layout.
  List<String> get _posterOrder => _posterOrderF.putIfAbsent(
    _designKey,
    () => widget.isAnnouncement
        ? List<String>.from(_kPosterBaseOrder)
        : <String>[],
  );
  List<({String id, String dataUrl})> get _posterOverlays =>
      _posterOverlaysF.putIfAbsent(_designKey, () => []);
  List<String> get _textIds => _textIdsF.putIfAbsent(_designKey, () => []);
  Map<String, String> get _textContent =>
      _textContentF.putIfAbsent(_designKey, () => {});
  Map<String, String> get _textFont =>
      _textFontF.putIfAbsent(_designKey, () => {});
  Map<String, String> get _textColor =>
      _textColorF.putIfAbsent(_designKey, () => {});
  Map<String, String> get _textShadow =>
      _textShadowF.putIfAbsent(_designKey, () => {});
  Map<String, String> get _textAlign =>
      _textAlignF.putIfAbsent(_designKey, () => {});
  // Weiche Kanten je Bild-Element: Original-Bild + Stärke (0..100), je Layout.
  final Map<String, Map<String, String>> _imgOrigF = {};
  final Map<String, Map<String, double>> _imgFeatherF = {};
  // „Rand verschmelzen" je Bild-Element (0..100), je Layout.
  final Map<String, Map<String, double>> _imgRimF = {};
  final Map<String, Map<String, double>> _imgInnerF = {};
  Map<String, String> get _imgOrig =>
      _imgOrigF.putIfAbsent(_designKey, () => {});
  Map<String, double> get _imgFeather =>
      _imgFeatherF.putIfAbsent(_designKey, () => {});
  Map<String, double> get _imgInner =>
      _imgInnerF.putIfAbsent(_designKey, () => {});
  Map<String, double> get _imgRim => _imgRimF.putIfAbsent(_designKey, () => {});
  bool _featherBusy = false;
  String? _fxPending; // während einer Bildeffekt-Berechnung angefragter Re-Run
  // Profi-Finish (globale Bildkorrektur) je Design; wirkt nur aufs Gesamtbild.
  final Map<String, _Grade> _gradeF = {};
  _Grade get _grade => _gradeF.putIfAbsent(_designKey, () => _Grade());
  bool _gradeBusy = false; // KI-Analyse läuft
  // Zoom/Verschiebung des Canvas im Editor (nur Ansicht, nie im Export).
  final _editZoom = TransformationController();
  bool _editZoomed = false;
  // Freier Editor für ALLE Grafiktypen (Ankündigung/Ergebnis/Startelf); im
  // reinen Branding-Design-Modus deaktiviert (eigenes Layout).
  // „Eigenes Branding“ (designMode) gibt es nicht mehr – immer der Editor.
  bool get _editable => true;
  // Speicher-ID je Spiel UND Grafiktyp (sonst würden sich Ankündigung/Ergebnis/
  // Startelf desselben Spiels überschreiben). match_id-Spalte bleibt die Spiel-ID.
  String get _designStorageId =>
      widget.designer?.id ?? '${widget.matchId}:$_kind';
  // Hat dieses Design einen Speicherplatz? (Spiel-Grafik oder Designer)
  bool get _hasStorage => widget.designer != null || widget.matchId != null;
  // Designer: anzeigbarer Titel (umbenennbar) + kleines Vorschaubild.
  late String _designerTitle = widget.designer?.title ?? '';
  String? _thumb;
  DateTime _thumbAt = DateTime(2000);
  // Speichern des Ankündigungs-Designs je Spiel (lokal + Cloud).
  Timer? _saveTimer; // debounced Autosave
  bool _designLoaded =
      false; // erst nach dem Laden speichern (nichts überschr.)
  // Zuletzt gespeicherter/geladener Stand – nur ECHTE Änderungen speichern
  // (bloßes Öffnen darf nie eine neuere Cloud-Version überschreiben).
  String? _lastSavedJson;
  // FuPa: eigener Hintergrund JE DESIGN (Kopie der Team-Vorlage beim Anlegen).
  // Spätere Änderungen der Team-Vorlage verändern fertige Designs nicht.
  Map<String, Object?>? _fupaBgSnap;
  // FuPa: welcher der zwei Team-Hintergründe gilt für DIESES Design –
  // 'image' (Bild wie bisher) oder 'club' (Verlauf in Vereinsfarben).
  String _fupaBgVar = 'image';
  // Grafik-Einstellungen des Teams (Vereinsfarben für den Verlauf).
  GraphicSettings? _teamSettings;
  AppState? _appStateRef; // für Speichern in dispose (ohne context)
  final GlobalKey _posterCanvasKey = GlobalKey(); // Koord. für den Dreh-Griff
  bool _showMainSponsor = true; // Hauptsponsor anzeigen (je Grafik)
  String _mainSponsorMode =
      'logo'; // 'logo' | 'text' – Hauptsponsor-Darstellung
  bool _showOtherSponsors = true; // weitere Sponsoren anzeigen (je Grafik)
  String _posterFont = 'standard'; // Schriftart der Poster-Texte
  List<Sponsor> _sponsors = [];
  GraphicSettings _settings = const GraphicSettings(id: 'local');
  bool _loading = true;
  bool _sharing = false;
  bool _aiBusy = false;
  String _aiBusyLabel = 'KI arbeitet …';
  bool _bgBusy = false; // clientseitiges Hintergrund-Entfernen läuft

  /// Text der Fortschrittsanzeige (null = nichts läuft).
  String? get _busyText => _lookBusy
      ? 'KI gestaltet den Look …'
      : _aiBusy
      ? _aiBusyLabel
      : _bgBusy
      ? 'Bild wird bearbeitet …'
      : null;
  // Hinzugefügte Fotos (für alle Grafiktypen), transient. Hintergrund ODER
  // Foto-Bereich oben; mehrere möglich.
  final List<_GraphicPhoto> _photos = [];

  // KI-Hintergründe: Verlauf der letzten [_kMaxAiBgs] (neuester zuerst) und
  // je Format die Auswahl (Index; null/fehlend = aus).
  final List<String> _aiBgs = [];
  final Map<String, int?> _aiBgSelF = {};
  static const int _kMaxAiBgs = 5;

  int? get _aiBgSel {
    final i = _aiBgSelF[_designKey];
    return i != null && i >= 0 && i < _aiBgs.length ? i : null;
  }

  // Einzelnes Band-Foto: verschieben & zoomen (Pinch/Drag).
  final TransformationController _photoCtrl = TransformationController();

  /// Wirksames Hintergrund-Foto: eingeschalteter KI-Hintergrund, sonst das
  /// erste Foto mit Platzierung „Hintergrund".
  String? get _photoBg {
    final ai = _aiBgSel;
    if (ai != null) return _aiBgs[ai];
    for (final p in _photos) {
      if (p.place == _PhotoPlace.background) return p.dataUrl;
    }
    return null;
  }

  /// Fotos im Foto-Bereich oben (in Reihenfolge).
  List<String> get _bandPhotos => [
    for (final p in _photos)
      if (p.place == _PhotoPlace.band) p.dataUrl,
  ];

  /// Großes Spielerbild, je Layout (Format×Stil) getrennt.
  String? get _posterMain => _posterMainF[_designKey];

  /// Rundes Zweit-Foto (Badge) im Poster (erstes mit Platzierung „posterBadge").
  String? get _posterBadge {
    for (final p in _photos) {
      if (p.place == _PhotoPlace.posterBadge) return p.dataUrl;
    }
    return null;
  }

  /// Standard-Überschrift je Grafiktyp.
  String get _defaultHeadline => widget.designer != null
      ? widget.designer!.headline
      : widget.isAnnouncement
      ? 'SPIELTAG'
      : (widget.isResult
            ? (_resultLayout == 'photo' ? 'ENDSTAND' : 'ERGEBNIS')
            : 'STARTELF');

  /// Aktuelle Überschrift aus Modus + Text (alle Grafiktypen).
  String get _posterHeadline {
    switch (_annHeadMode) {
      case 'auto':
        return widget.isHome ? 'HEIMSPIEL' : 'AUSWÄRTSSPIEL';
      case 'custom':
        final t = _annHeadText.trim();
        return t.isEmpty ? _defaultHeadline : t.toUpperCase();
      default:
        return _defaultHeadline;
    }
  }

  /// Automatische Datumszeile der Startelf/Ergebnis-Grafik.
  String get _autoStdInfoLine {
    final parts = <String>[widget.isHome ? 'HEIMSPIEL' : 'AUSWÄRTSSPIEL'];
    final d = widget.matchDate;
    if (d != null) {
      final local = d.toLocal();
      parts.add(DateFormat('EEE, dd.MM.yyyy', 'de_DE').format(local));
      if (local.hour != 0 || local.minute != 0) {
        parts.add('${DateFormat('HH:mm', 'de_DE').format(local)} Uhr');
      }
    }
    return parts.join('   ·   ');
  }

  /// Automatische Datum/Ort-Zeile (Vorbelegung für den editierbaren Datum-Text).
  String get _autoInfoLine {
    if (widget.designer != null) return widget.designer!.infoLine;
    final a = widget.announcement;
    final parts = <String>[];
    final d = widget.matchDate;
    if (d != null) {
      final local = d.toLocal();
      parts.add(DateFormat('EEE', 'de_DE').format(local));
      parts.add(DateFormat('dd. MMM', 'de_DE').format(local));
      if (local.hour != 0 || local.minute != 0) {
        parts.add(DateFormat('HH:mm', 'de_DE').format(local));
      }
    }
    final venue = (a?.venue ?? '').trim();
    final address = (a?.address ?? '').trim();
    if (venue.isNotEmpty) parts.add(venue.toUpperCase());
    if (address.isNotEmpty && address.toLowerCase() != venue.toLowerCase()) {
      parts.add(address.toUpperCase());
    }
    return parts.join(' | ');
  }

  // Ist der wirksame Hintergrund dunkel? → steuert die Auto-Logo-Variante.
  bool _bgDark = false;
  String? _bgDarkFor; // Für welchen Hintergrund zuletzt berechnet.
  // Mittlere Farbe des Hintergrundbilds (null = Verlauf) → Licht-Angleichung.
  Color? _bgAvg;

  /// Umgebungslicht für den Spieler: mittlere Hintergrundfarbe.
  Color get _playerLight =>
      _bgAvg ??
      Color.lerp(_hex(_settings.gradTop), _hex(_settings.gradBottom), 0.5)!;

  /// Hintergrundhelligkeit bestimmen (einmal je Hintergrund). Dunkel → helles/
  /// SW-Logo, hell → farbiges Logo.
  Future<void> _refreshBgDark() async {
    final src = _photoBg ?? _settings.bgImage;
    if (src == _bgDarkFor) return;
    _bgDarkFor = src;
    bool dark = true; // Default-Verlauf (dunkelgrün) → eher dunkel.
    Color? avg;
    final bytes = TeamLogo.decode(src);
    if (bytes != null) {
      try {
        final im = img.decodeImage(bytes);
        if (im != null) {
          final small = img.copyResize(im, width: 16);
          var tot = 0.0;
          var sr = 0.0, sg = 0.0, sb = 0.0;
          var n = 0;
          var m = 0;
          for (final p in small) {
            tot += 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
            m++;
            // Lichtfarbe aus dem Bereich HINTER dem Spieler (Mitte, ohne
            // Ränder/Himmel ganz oben) – folgt jedem neuen Hintergrund.
            final fx = p.x / small.width, fy = p.y / small.height;
            if (fx < 0.2 || fx > 0.8 || fy < 0.15 || fy > 0.9) continue;
            sr += p.r;
            sg += p.g;
            sb += p.b;
            n++;
          }
          dark = m > 0 && (tot / m) < 115;
          if (n > 0) {
            avg = Color.fromARGB(
              255,
              (sr / n).round().clamp(0, 255),
              (sg / n).round().clamp(0, 255),
              (sb / n).round().clamp(0, 255),
            );
          }
        }
      } catch (_) {}
    }
    if (mounted && (dark != _bgDark || avg != _bgAvg)) {
      setState(() {
        _bgDark = dark;
        _bgAvg = avg;
      });
    }
  }

  /// Effektives Vereinslogo: auf dunklem Hintergrund das dunkel-Logo (sonst
  /// Standard). Fällt auf das Team-Logo zurück.
  String? get _effectiveLogo => _bgDark
      ? (_settings.logoDark ?? _settings.logo ?? widget.teamLogo)
      : (_settings.logo ?? widget.teamLogo);

  // Logische Zeichengrößen (× pixelRatio 3 = 1080×1920 bzw. 1080×1080).
  static const double _storyW = 360, _storyH = 640;
  static const double _postW = 360, _postH = 360;
  // FuPa-Spielerfoto: 4:5 (Export 960×1200 wie bei FuPa).
  static const double _fupaW = 360, _fupaH = 450;

  /// Standard-Ebenenreihenfolge (hinten → vorne).
  static const List<String> _kPosterBaseOrder = [
    'player',
    'sponsor',
    'sponsortext',
    'logos',
    'headline',
    'info',
    'sponsorbar',
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _annHeadText = _defaultHeadline; // Vorbelegung „Eigener" je Grafiktyp
    // FuPa-Foto sofort im 4:5-Hochformat mit nur dem Spieler – nicht erst,
    // wenn der (evtl. langsame) Cloud-Abgleich fertig ist.
    if (_isFupa) {
      _format = 'f';
      _posterOrderF['f'] = ['player'];
    }
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _appStateRef = context.read<AppState>();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // App geht in den Hintergrund → den letzten Stand sichern.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _flushSave();
    }
  }

  @override
  void dispose() {
    _editZoom.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _saveTimer?.cancel();
    _flushSave(); // letzten Stand beim Verlassen sichern
    _photoCtrl.dispose();
    _ftCtrl.dispose();
    _animTicker?.dispose();
    super.dispose();
  }

  /// Autosave anstoßen (debounced) – wird bei jeder Änderung aus build() gerufen.
  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), _flushSave);
  }

  /// Aktuelles Design sofort speichern (lokal + Cloud). No-op ohne matchId oder
  /// bevor das Laden fertig ist (sonst würde leer gespeichert).
  void _flushSave() {
    _saveTimer?.cancel();
    if (!_hasStorage || !_editable || !_designLoaded) return;
    final d = widget.designer;
    final String data;
    try {
      data = jsonEncode(_designToJson());
    } catch (_) {
      return;
    }
    if (data == _lastSavedJson) return; // nichts geändert → nicht speichern
    _lastSavedJson = data;
    try {
      _appStateRef?.saveAnnouncementDesign(
        _designStorageId,
        widget.matchId ?? d?.matchId,
        data,
        title: d == null ? null : _designerTitle,
        kind: d?.template,
        thumb: d == null ? null : _thumb,
      );
    } catch (_) {
      // Speichern fehlgeschlagen – nächste Änderung versucht es erneut.
    }
    // Designer: Vorschaubild für „Meine Designs" höchstens alle 5 s auffrischen.
    if (d != null &&
        mounted &&
        DateTime.now().difference(_thumbAt) > const Duration(seconds: 5)) {
      _thumbAt = DateTime.now();
      unawaited(_refreshThumb());
    }
  }

  /// Designer: Titel des Designs ändern (für „Meine Designs").
  Future<void> _renameDesign() async {
    final ctrl = TextEditingController(text: _designerTitle);
    final t = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Design umbenennen'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(border: OutlineInputBorder()),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
    if (t == null || t.trim().isEmpty || !mounted) return;
    setState(() => _designerTitle = t.trim());
    _flushSave();
  }

  /// Kleines Vorschaubild (JPEG ~220 px) der aktuellen Grafik für die Liste
  /// „Meine Designs" – direkt aus der RepaintBoundary, ohne die Auswahl zu
  /// verändern. Danach erneut speichern (nur wenn sich etwas geändert hat).
  Future<void> _refreshThumb() async {
    try {
      final boundary =
          _boundaryKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) return;
      final logicalWidth = _cw;
      final image = await boundary.toImage(pixelRatio: 220 / logicalWidth);
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return;
      final url = await compute(_rgbaToJpegDataUrl, <String, Object>{
        'w': image.width,
        'h': image.height,
        'px': data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      });
      if (!mounted || url == _thumb) return;
      _thumb = url;
      _appStateRef?.saveAnnouncementDesign(
        _designStorageId,
        widget.matchId ?? widget.designer?.matchId,
        jsonEncode(_designToJson()),
        title: _designerTitle,
        kind: widget.designer?.template,
        thumb: url,
      );
    } catch (_) {
      // Vorschau ist optional – Design ist ohnehin gespeichert.
    }
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    final sponsors = await state.sponsors();
    final settings = await state.graphicSettings();
    if (!mounted) return;
    setState(() {
      // Deaktivierte Sponsoren erscheinen auf keiner Grafik.
      _sponsors = sponsors.where((s) => s.enabled).toList();
      _settings = settings;
      _teamSettings = settings;
      _loading = false;
    });
    // Früheres „Eigenes Branding“ (alter Modus) teamweit ausschalten – sonst
    // hingen andere Geräte/Grafiken noch im alten Modus.
    if (settings.designMode) {
      final fixed = settings.copyWith(designMode: false);
      _settings = _settings.copyWith(designMode: false);
      _teamSettings = fixed;
      unawaited(
        state
            .saveGraphicSettings(fixed)
            .then((_) => state.pushGraphicSettingsToCloud()),
      );
    }
    // FuPa: eigener, team-weiter Hintergrund (Vorlage „fupa-background").
    if (_isFupa) {
      final presets = await state.graphicPresets();
      if (!mounted) return;
      for (final p in presets) {
        if (p.id == _kFupaBgId) {
          setState(() => _settings = _withPreset(_settings, p));
          break;
        }
      }
    }
    _refreshBgDark();
    // Lokale Einstellung (evtl. vor Existenz der Cloud-Tabelle angelegt) in die
    // Cloud nachschieben, damit sie auf anderen Geräten erscheint.
    state.pushGraphicSettingsToCloud();
    // Gespeichertes Ankündigungs-Design dieses Spiels laden (erst Cloud→lokal
    // frisch ziehen, dann lokal lesen). Danach ist Autosave scharf.
    if (_editable && _hasStorage) {
      final sid = _designStorageId;
      final designer = widget.designer;
      // Designer: lokalen Stand SOFORT zeigen, Cloud-Abgleich danach im
      // Hintergrund (sonst wartet man bei schlechtem Netz lange auf das Bild).
      // Andere Grafiken: wie bisher erst abgleichen.
      if (designer == null) {
        try {
          await state.refreshAnnouncementDesign(sid);
        } catch (_) {}
      }
      final json = await state.loadAnnouncementDesign(sid);
      if (!mounted) return;
      if (designer != null) {
        // Designer: gezielt geöffnetes Design → ohne Rückfrage weitermachen;
        // neu angelegt → Startfoto (z. B. Kader-Foto) als Spielerbild.
        if (json != null && json.isNotEmpty) {
          try {
            _applyDesignJson(jsonDecode(json) as Map<String, dynamic>);
          } catch (_) {}
        } else if (_isFupa) {
          // Neues FuPa-Foto: Hochformat, NUR der Spieler (kein Logo/Text).
          _format = 'f';
          _posterOrderF['f'] = ['player'];
        } else if (designer.playerPhoto != null) {
          for (final k in const ['s', 'p']) {
            _posterMainF[k] = designer.playerPhoto;
            _imgOrigF.putIfAbsent(k, () => {})['player'] =
                designer.playerPhoto!;
          }
        }
        _fupaAfterLoad(isNew: json == null || json.isEmpty);
        if (mounted) setState(() {});
        _refreshBgDark();
        _designLoaded = true;
        _lastSavedJson = jsonEncode(_designToJson());
        unawaited(_refreshDesignInBackground(sid, json));
        return;
      } else if (json != null && json.isNotEmpty) {
        // Es gibt ein gespeichertes Design → fragen: weiterbearbeiten oder neu.
        final keep = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title: const Text('Gespeichertes Design'),
            content: const Text(
              'Für dieses Spiel gibt es bereits ein Design. Möchtest du es '
              'weiterbearbeiten oder neu beginnen?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Neu beginnen'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Weiterbearbeiten'),
              ),
            ],
          ),
        );
        if (!mounted) return;
        if (keep == true) {
          try {
            _applyDesignJson(jsonDecode(json) as Map<String, dynamic>);
            _fillMissingFormatPhoto();
            setState(() {});
          } catch (_) {
            // Beschädigtes/altes JSON → ignorieren, mit leerem Design starten.
          }
        }
        // „Neu beginnen" → nichts anwenden; mit dem Standard-Layout starten.
      }
    }
    if (_hasStorage) _lastSavedJson = jsonEncode(_designToJson());
    _designLoaded = true;
  }

  /// Story bzw. Post ohne eigenes Spielerfoto, die noch nie gestaltet wurden
  /// (keine verschobenen Elemente) → Foto des anderen Formats übernehmen.
  /// Sonst fehlte z. B. in der Story der Spieler, obwohl er im Post gesetzt ist.
  void _fillMissingFormatPhoto() {
    for (final (k, o) in const [('s', 'p'), ('p', 's')]) {
      if (_posterMainF[k] != null) continue;
      final other = _posterMainF[o];
      if (other == null) continue;
      if (_posterPosF[k]?.isNotEmpty ?? false) continue; // bewusst gestaltet
      _posterMainF[k] = other;
      final orig = _imgOrigF[o]?['player'];
      if (orig != null) _imgOrigF.putIfAbsent(k, () => {})['player'] = orig;
      final order = _posterOrderF[k];
      if (order != null && !order.contains('player')) order.insert(0, 'player');
    }
  }

  /// FuPa-Absicherungen nach dem Laden: immer 4:5 mit nur dem Spieler; Foto
  /// aus einem anderen Format übernehmen; Hintergrund je Design festhalten.
  void _fupaAfterLoad({required bool isNew}) {
    if (!_isFupa) return;
    _format = 'f';
    _posterOrderF.putIfAbsent('f', () => ['player']);
    if (_posterMainF['f'] == null) {
      final alt = _posterMainF['s'] ?? _posterMainF['p'];
      if (alt != null) {
        _posterMainF['f'] = alt;
        _imgOrigF.putIfAbsent('f', () => {})['player'] = alt;
      }
    }
    // Neues Design: aktuelle Team-Vorlage als EIGENEN Hintergrund kopieren.
    if (isNew && _fupaBgSnap == null) _fupaBgSnap = _currentFupaBg().toMap();
  }

  /// FuPa: zwischen den zwei Team-Hintergründen wechseln. Der gewählte wird
  /// (wie beim Anlegen) als eigener Hintergrund DIESES Designs festgehalten.
  /// Fehlt die Vorlage „Vereinsverlauf" noch, entsteht sie aus den
  /// Vereinsfarben der Grafik-Einstellungen.
  Future<void> _switchFupaBg(String variant) async {
    if (variant == _fupaBgVar) return;
    final state = context.read<AppState>();
    final presets = await state.graphicPresets();
    if (!mounted) return;
    final id = variant == 'club' ? _kFupaBgClubId : _kFupaBgId;
    GraphicPreset? preset;
    for (final p in presets) {
      if (p.id == id) preset = p;
    }
    final team = _teamSettings ?? _settings;
    preset ??= variant == 'club'
        ? GraphicPreset(
            id: _kFupaBgClubId,
            name: 'FuPa-Hintergrund (Vereinsverlauf)',
            gradTop: team.gradTop,
            gradBottom: team.gradBottom,
            overlayOpacity: 0,
            bgOpacity: 100,
            bgBlend: 'normal',
            accent: team.accent,
            createdAt: DateTime.now().toIso8601String(),
          )
        : null;
    setState(() {
      _fupaBgVar = variant;
      if (preset != null) _settings = _withPreset(_settings, preset);
      _fupaBgSnap = _currentFupaBg().toMap();
    });
    _refreshBgDark();
  }

  /// Aktueller FuPa-Hintergrund (aus den angezeigten Einstellungen).
  GraphicPreset _currentFupaBg() => GraphicPreset(
    id: _fupaBgVar == 'club' ? _kFupaBgClubId : _kFupaBgId,
    name: _fupaBgVar == 'club'
        ? 'FuPa-Hintergrund (Vereinsverlauf)'
        : 'FuPa-Hintergrund',
    bgImage: _settings.bgImage,
    gradTop: _settings.gradTop,
    gradBottom: _settings.gradBottom,
    overlayOpacity: _settings.overlayOpacity,
    bgOpacity: _settings.bgOpacity,
    bgBlend: _settings.bgBlend,
    accent: _settings.accent,
    createdAt: DateTime.now().toIso8601String(),
  );

  /// Cloud-Abgleich im Hintergrund (Designer). Kam eine NEUERE Version und
  /// wurde noch nichts geändert → nachladen.
  Future<void> _refreshDesignInBackground(String sid, String? loaded) async {
    final state = _appStateRef;
    if (state == null) return;
    try {
      await state.refreshAnnouncementDesign(sid);
    } catch (_) {
      return; // offline → lokaler Stand bleibt, nichts speichern
    }
    if (!mounted) return;
    final json = await state.loadAnnouncementDesign(sid);
    if (!mounted) return;
    final untouched = jsonEncode(_designToJson()) == _lastSavedJson;
    if (untouched && json != null && json.isNotEmpty && json != loaded) {
      try {
        _applyDesignJson(jsonDecode(json) as Map<String, dynamic>);
        _fupaAfterLoad(isNew: false);
        setState(() {});
        _refreshBgDark();
        _lastSavedJson = jsonEncode(_designToJson());
      } catch (_) {}
    }
  }

  /// Aktuell angezeigtes Bild eines Bild-Elements ([id] = 'player' oder
  /// Overlay-ID) im Format [designKey] – für den Original-Abgleich beim Speichern.
  String? _currentImageOf(String designKey, String id) {
    if (id == 'player') return _posterMainF[designKey];
    for (final o in _posterOverlaysF[designKey] ?? const []) {
      if (o.id == id) return o.dataUrl;
    }
    return null;
  }

  /// Gesamten Editor-Zustand der Ankündigung als JSON (für Speichern je Spiel).
  Map<String, dynamic> _designToJson() {
    Map<String, dynamic> offMap(Map<String, Map<String, Offset>> m) => {
      for (final e in m.entries)
        e.key: {
          for (final o in e.value.entries) o.key: [o.value.dx, o.value.dy],
        },
    };
    Map<String, dynamic> dblMap(Map<String, Map<String, double>> m) => {
      for (final e in m.entries) e.key: Map<String, double>.from(e.value),
    };
    Map<String, dynamic> strMap(Map<String, Map<String, String>> m) => {
      for (final e in m.entries) e.key: Map<String, String>.from(e.value),
    };
    return {
      'v': 1,
      'pos': offMap(_posterPosF),
      'posC': {for (final e in _posCenteredF.entries) e.key: e.value.toList()},
      'look': {for (final e in _lookF.entries) e.key: e.value.toJson()},
      'boxSize': {
        for (final e in _boxSizeF.entries)
          e.key: {
            for (final b in e.value.entries)
              b.key: [b.value.width, b.value.height],
          },
      },
      'resLayout': _resultLayout,
      'ftPhoto': Map<String, String>.from(_ftPhotoF),
      'ftMatrix': {for (final e in _ftMatrixF.entries) e.key: e.value},
      'ftSplit': Map<String, double>.from(_ftSplitF),
      'stdOff': offMap(_stdOffF),
      // Startelf-Layout v2 (zentriert, Kader-Kasten) – ältere Verschiebungen
      // passen nicht mehr und werden beim Laden verworfen.
      'stdV': 3,
      'stdHidden': {
        for (final e in _stdHiddenF.entries) e.key: e.value.toList(),
      },
      'scale': dblMap(_posterScaleF),
      'rot': dblMap(_posterRotF),
      'order': {for (final e in _posterOrderF.entries) e.key: e.value},
      'main': {for (final e in _posterMainF.entries) e.key: e.value},
      'overlays': {
        for (final e in _posterOverlaysF.entries)
          e.key: [
            for (final o in e.value) {'id': o.id, 'dataUrl': o.dataUrl},
          ],
      },
      'textIds': {for (final e in _textIdsF.entries) e.key: e.value},
      'textContent': strMap(_textContentF),
      'textFont': strMap(_textFontF),
      'textColor': strMap(_textColorF),
      'textShadow': strMap(_textShadowF),
      'textAlign': strMap(_textAlignF),
      'aiBgs': _aiBgs,
      'aiBgSel': {
        for (final e in _aiBgSelF.entries)
          if (e.value != null) e.key: e.value,
      },
      // Original-Bilder NUR speichern, wenn sie sich vom angezeigten Bild
      // unterscheiden (nach Weiche Kanten/Schatten). Sonst wäre jedes Bild
      // doppelt drin – das machte Designs 8 MB groß und der Cloud-Upload
      // scheiterte. Beim Laden wird das fehlende Original wieder ergänzt.
      'imgOrig': {
        for (final e in _imgOrigF.entries)
          e.key: {
            for (final i in e.value.entries)
              if (i.value != _currentImageOf(e.key, i.key)) i.key: i.value,
          },
      },
      // Fotos (Hintergrund / Foto-Bereich / Poster-Badge) mitspeichern.
      'photos': [
        for (final p in _photos) {'url': p.dataUrl, 'place': p.place.name},
      ],
      'imgFeather': dblMap(_imgFeatherF),
      'imgInner': dblMap(_imgInnerF),
      'imgRim': dblMap(_imgRimF),
      'grade': {for (final e in _gradeF.entries) e.key: e.value.toJson()},
      'anim': {
        for (final e in _animF.entries)
          if (e.value.isActive) e.key: e.value.toJson(),
      },
      'aiVideo': Map<String, String>.from(_aiVideoF),
      'headMode': _annHeadMode,
      'headText': _annHeadText,
      'logoDisc': _posterLogoDisc,
      'shadow': _posterShadow,
      'blend': _posterBlend,
      'shadowStrength': _posterShadowStrength,
      'shadowAngle': _posterShadowAngle,
      'font': _posterFont,
      'showMain': _showMainSponsor,
      'mainMode': _mainSponsorMode,
      'showOthers': _showOtherSponsors,
      'story': _story,
      'format': _format,
      'ovSeq': _posterOverlaySeq,
      // Designer: Vorlage/Titel/Vorgaben zum Wiederöffnen.
      if (widget.designer != null)
        'designer': widget.designer!.copyWith(title: _designerTitle).toJson(),
      'txtSeq': _textSeq,
      'fupaBg': ?_fupaBgSnap,
      if (_isFupa) 'fupaBgVar': _fupaBgVar,
    };
  }

  /// Gespeichertes Design in die transienten Maps zurückschreiben.
  void _applyDesignJson(Map<String, dynamic> m) {
    void fillOff(Map<String, Map<String, Offset>> t, dynamic src) {
      t.clear();
      if (src is Map) {
        src.forEach((k, v) {
          final inner = <String, Offset>{};
          if (v is Map) {
            v.forEach((ik, iv) {
              if (iv is List && iv.length == 2) {
                inner[ik.toString()] = Offset(
                  (iv[0] as num).toDouble(),
                  (iv[1] as num).toDouble(),
                );
              }
            });
          }
          t[k.toString()] = inner;
        });
      }
    }

    void fillDbl(Map<String, Map<String, double>> t, dynamic src) {
      t.clear();
      if (src is Map) {
        src.forEach((k, v) {
          final inner = <String, double>{};
          if (v is Map) {
            v.forEach((ik, iv) {
              if (iv is num) inner[ik.toString()] = iv.toDouble();
            });
          }
          t[k.toString()] = inner;
        });
      }
    }

    void fillStr(Map<String, Map<String, String>> t, dynamic src) {
      t.clear();
      if (src is Map) {
        src.forEach((k, v) {
          final inner = <String, String>{};
          if (v is Map) {
            v.forEach((ik, iv) {
              if (iv != null) inner[ik.toString()] = iv.toString();
            });
          }
          t[k.toString()] = inner;
        });
      }
    }

    fillOff(_posterPosF, m['pos']);
    _posCenteredF.clear();
    if (m['posC'] is Map) {
      (m['posC'] as Map).forEach((k, v) {
        if (v is List) {
          _posCenteredF[k.toString()] = v.map((e) => e.toString()).toSet();
        }
      });
    }
    _animF.clear();
    if (m['anim'] is Map) {
      (m['anim'] as Map).forEach((k, v) {
        _animF[k.toString()] = GraphicAnim.fromJson(v);
      });
    }
    _aiVideoF.clear();
    if (m['aiVideo'] is Map) {
      (m['aiVideo'] as Map).forEach((k, v) {
        if (v is String) _aiVideoF[k.toString()] = v;
      });
    }
    _lookF.clear();
    if (m['look'] is Map) {
      (m['look'] as Map).forEach((k, v) {
        final l = _AiLook.fromJson(v);
        if (l != null) _lookF[k.toString()] = l;
      });
    }
    _boxSizeF.clear();
    if (m['boxSize'] is Map) {
      (m['boxSize'] as Map).forEach((k, v) {
        final inner = <String, Size>{};
        if (v is Map) {
          v.forEach((id, s) {
            if (s is List && s.length == 2 && s[0] is num && s[1] is num) {
              inner[id.toString()] = Size(
                (s[0] as num).toDouble(),
                (s[1] as num).toDouble(),
              );
            }
          });
        }
        _boxSizeF[k.toString()] = inner;
      });
    }
    if (m['resLayout'] is String) _resultLayout = m['resLayout'];
    _ftPhotoF.clear();
    if (m['ftPhoto'] is Map) {
      (m['ftPhoto'] as Map).forEach((k, v) {
        if (v is String && v.isNotEmpty) _ftPhotoF[k.toString()] = v;
      });
    }
    _ftSplitF.clear();
    if (m['ftSplit'] is Map) {
      (m['ftSplit'] as Map).forEach((k, v) {
        if (v is num) _ftSplitF[k.toString()] = v.toDouble().clamp(0.2, 0.85);
      });
    }
    _ftMatrixF.clear();
    if (m['ftMatrix'] is Map) {
      (m['ftMatrix'] as Map).forEach((k, v) {
        if (v is List && v.length == 16) {
          _ftMatrixF[k.toString()] = [
            for (final x in v) (x is num) ? x.toDouble() : 0.0,
          ];
        }
      });
    }
    fillOff(_stdOffF, m['stdOff']);
    // Startelf vor Layout v2: alte Verschiebungen/Größen der festen Teile
    // gehören zum alten Aufbau → verwerfen, damit alles wie vorgesehen sitzt.
    // Ergebnis ab v3 neu aufgebaut (ohne Logo oben, Leuchtlinie, Tore-Kasten).
    final stdV = (m['stdV'] as num?)?.toInt() ?? 0;
    final oldStartelf =
        widget.announcement == null && (widget.isResult ? stdV < 3 : stdV < 2);
    _stdHiddenF.clear();
    if (m['stdHidden'] is Map) {
      (m['stdHidden'] as Map).forEach((k, v) {
        if (v is List) {
          _stdHiddenF[k.toString()] = v.map((e) => e.toString()).toSet();
        }
      });
    }
    fillDbl(_posterScaleF, m['scale']);
    fillDbl(_posterRotF, m['rot']);
    if (oldStartelf) {
      _stdOffF.clear();
      for (final mm in [..._posterScaleF.values, ..._posterRotF.values]) {
        mm.removeWhere((k, _) => k.startsWith('std_'));
      }
      for (final mm in _boxSizeF.values) {
        mm.removeWhere((k, _) => k.startsWith('std_'));
      }
    }
    _posterOrderF.clear();
    if (m['order'] is Map) {
      (m['order'] as Map).forEach((k, v) {
        if (v is List) {
          final list = v.map((e) => e.toString()).toList();
          // Ältere Designs: „Präsentiert von" war Teil des Sponsors → als
          // eigenes Element direkt dahinter einblenden.
          final si = list.indexOf('sponsor');
          if (si >= 0 && !list.contains('sponsortext')) {
            list.insert(si + 1, 'sponsortext');
            // War der Sponsor verschoben, startet der Text einmalig links
            // neben dem Logo (danach unabhängig).
            final pos = _posterPosF[k.toString()];
            final sp = pos?['sponsor'];
            if (pos != null && sp != null) {
              pos['sponsortext'] = Offset(
                (sp.dx - 0.32).clamp(0.02, 0.98),
                sp.dy,
              );
              final c = _posCenteredF[k.toString()];
              if (c != null && c.contains('sponsor')) c.add('sponsortext');
            }
          }
          _posterOrderF[k.toString()] = list;
        }
      });
    }
    _posterMainF.clear();
    if (m['main'] is Map) {
      (m['main'] as Map).forEach((k, v) {
        _posterMainF[k.toString()] = v as String?;
      });
    }
    _posterOverlaysF.clear();
    if (m['overlays'] is Map) {
      (m['overlays'] as Map).forEach((k, v) {
        final list = <({String id, String dataUrl})>[];
        if (v is List) {
          for (final o in v) {
            if (o is Map && o['id'] != null && o['dataUrl'] != null) {
              list.add((
                id: o['id'].toString(),
                dataUrl: o['dataUrl'].toString(),
              ));
            }
          }
        }
        _posterOverlaysF[k.toString()] = list;
      });
    }
    _textIdsF.clear();
    if (m['textIds'] is Map) {
      (m['textIds'] as Map).forEach((k, v) {
        if (v is List) {
          _textIdsF[k.toString()] = v.map((e) => e.toString()).toList();
        }
      });
    }
    fillStr(_textContentF, m['textContent']);
    fillStr(_textFontF, m['textFont']);
    fillStr(_textColorF, m['textColor']);
    fillStr(_textShadowF, m['textShadow']);
    fillStr(_textAlignF, m['textAlign']);
    fillStr(_imgOrigF, m['imgOrig']);
    // Nicht mitgespeicherte Originale (= unverändertes Bild) wieder ergänzen,
    // damit Weiche Kanten/Schatten weiterhin vom Original aus rechnen.
    for (final k in {..._posterMainF.keys, ..._posterOverlaysF.keys}) {
      final orig = _imgOrigF.putIfAbsent(k, () => <String, String>{});
      final main = _posterMainF[k];
      if (main != null) orig.putIfAbsent('player', () => main);
      for (final o in _posterOverlaysF[k] ?? const []) {
        orig.putIfAbsent(o.id, () => o.dataUrl);
      }
    }
    // Gespeicherte Fotos (Hintergrund / Foto-Bereich / Badge).
    if (m['photos'] is List) {
      _photos.clear();
      for (final p in m['photos'] as List) {
        if (p is! Map) continue;
        final url = p['url'];
        if (url is! String || url.isEmpty) continue;
        final place = _PhotoPlace.values.firstWhere(
          (e) => e.name == p['place'],
          orElse: () => _PhotoPlace.background,
        );
        _photos.add(_GraphicPhoto(url, place));
      }
    }
    _aiBgs.clear();
    _aiBgSelF.clear();
    if (m['aiBgs'] is List) {
      _aiBgs.addAll((m['aiBgs'] as List).whereType<String>().take(_kMaxAiBgs));
    }
    if (m['aiBgSel'] is Map) {
      (m['aiBgSel'] as Map).forEach((k, v) {
        if (v is int && v >= 0 && v < _aiBgs.length) {
          _aiBgSelF[k.toString()] = v;
        }
      });
    }
    // Ältere Designs: KI-Hintergrund lag als PNG-Hintergrundfoto in _photos
    // → in den Verlauf übernehmen (eingeschaltet wie bisher, alle Formate).
    if (m['aiBgs'] == null) {
      for (final ph in List<_GraphicPhoto>.from(_photos)) {
        if (ph.place == _PhotoPlace.background &&
            ph.dataUrl.startsWith('data:image/png')) {
          _photos.remove(ph);
          _aiBgs.insert(0, ph.dataUrl);
          for (final k in const ['s', 'p']) {
            _aiBgSelF[k] = 0;
          }
          break;
        }
      }
    }
    fillDbl(_imgFeatherF, m['imgFeather']);
    fillDbl(_imgInnerF, m['imgInner']);
    fillDbl(_imgRimF, m['imgRim']);
    _gradeF.clear();
    if (m['grade'] is Map) {
      (m['grade'] as Map).forEach((k, v) {
        if (v is Map) _gradeF[k.toString()] = _Grade.fromJson(v);
      });
    }
    if (m['headMode'] is String) _annHeadMode = m['headMode'];
    if (m['headText'] is String) _annHeadText = m['headText'];
    // Ältere Ergebnis/Startelf-Designs speicherten die Ankündigungs-Vorbelegung.
    if (!widget.isAnnouncement &&
        _annHeadMode != 'custom' &&
        _annHeadText == 'SPIELTAG') {
      _annHeadText = _defaultHeadline;
    }
    if (m['logoDisc'] is bool) _posterLogoDisc = m['logoDisc'];
    if (m['shadow'] is bool) _posterShadow = m['shadow'];
    if (m['blend'] is bool) _posterBlend = m['blend'];
    if (m['shadowStrength'] is num) {
      _posterShadowStrength = (m['shadowStrength'] as num).toDouble();
    }
    if (m['shadowAngle'] is num) {
      _posterShadowAngle = (m['shadowAngle'] as num).toDouble();
    }
    if (m['font'] is String) _posterFont = m['font'];
    if (m['showMain'] is bool) _showMainSponsor = m['showMain'];
    if (m['mainMode'] is String) _mainSponsorMode = m['mainMode'];
    if (m['showOthers'] is bool) _showOtherSponsors = m['showOthers'];
    if (m['story'] is bool) _format = m['story'] ? 's' : 'p';
    if (m['format'] is String && const ['s', 'p', 'f'].contains(m['format'])) {
      _format = m['format'];
    }
    if (m['ovSeq'] is num) _posterOverlaySeq = (m['ovSeq'] as num).toInt();
    if (m['txtSeq'] is num) _textSeq = (m['txtSeq'] as num).toInt();
    // FuPa: der im Design gespeicherte Hintergrund gilt (nicht die aktuelle
    // Team-Vorlage).
    if (_isFupa) {
      _fupaBgVar = m['fupaBgVar'] == 'club' ? 'club' : 'image';
    }
    if (_isFupa && m['fupaBg'] is Map) {
      try {
        final snap = Map<String, Object?>.from(m['fupaBg'] as Map);
        _settings = _withPreset(_settings, GraphicPreset.fromMap(snap));
        _fupaBgSnap = snap;
      } catch (_) {}
    }
    _syncFtCtrl(); // gespeicherten Foto-Ausschnitt (ENDSTAND) übernehmen
    // Designer-Titel kommt aus der Liste (widget.designer) – nur wenn dort
    // keiner ist, den im Design gespeicherten nehmen.
    final dj = DesignerData.fromJson(m['designer']);
    if (_designerTitle.isEmpty && dj != null && dj.title.isNotEmpty) {
      _designerTitle = dj.title;
    }
  }

  // Effektive Anzeige-Werte (Einstellung überschreibt die Defaults).
  String get _title =>
      (_settings.title != null && _settings.title!.trim().isNotEmpty)
      ? _settings.title!.trim()
      : widget.teamName;

  Sponsor? get _mainSponsor {
    for (final s in _sponsors) {
      if (s.isMain) return s;
    }
    return null;
  }

  List<Sponsor> get _barSponsors =>
      _sponsors.where((s) => !s.isMain && s.logo != null).toList();

  /// Seitenverhältnis des finalen Fotobereichs (für WYSIWYG-Zuschnitt): Band =
  /// volle Breite × 46 % Höhe; Hintergrund = volle Grafik. Nach aktuellem Format.
  double _photoAspect(_PhotoPlace place) {
    final w = _cw;
    final h = _ch;
    switch (place) {
      case _PhotoPlace.band:
        return w / (h * 0.46);
      case _PhotoPlace.posterMain:
        // FuPa: Spieler füllt fast das ganze Hochformat.
        if (_isFupa) return w / (h * 0.95);
        return w /
            (h * _kPosterMainHeightFactor); // Hochformat, unterer Bereich
      case _PhotoPlace.posterBadge:
        return 1.0; // quadratisch → Kreis
      default:
        return w / h;
    }
  }

  Future<String?> _pickImage({
    required bool asBackground,
    ImageSource source = ImageSource.gallery,
    bool edit = false,
    double? aspectRatio,
    bool keepAlpha = false,
    int maxSize = 1600,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      // keepAlpha: ohne maxWidth/-Height/Quality laden, sonst re-encodiert der
      // Picker nach JPEG → Transparenz ginge verloren.
      final file = await ImagePicker().pickImage(
        source: source,
        maxWidth: keepAlpha ? null : (asBackground ? 1600 : 600),
        maxHeight: keepAlpha ? null : (asBackground ? 2400 : 600),
        imageQuality: keepAlpha ? null : (asBackground ? 85 : 90),
      );
      if (file == null) return null;
      var bytes = await file.readAsBytes();
      // keepAlpha-Pfad liefert das ungedrosselte Original (z.B. aus Google Fotos,
      // volle Auflösung) → der Zuschnitt-Editor zeigt sonst Schwarz. Normalisieren
      // (verkleinern + als PNG/JPEG neu kodieren), damit es sicher rendert.
      if (keepAlpha) {
        try {
          bytes = await compute(normalizeImageBytes, {
            'data': bytes,
            'keepAlpha': keepAlpha,
            'maxSize': maxSize,
          });
        } catch (_) {
          // Normalisierung fehlgeschlagen – Originalbytes weiterverwenden.
        }
      }
      // Vor dem Übernehmen bearbeiten (zuschneiden/drehen/Helligkeit/Kontrast).
      if (edit && mounted) {
        final edited = await Navigator.push<Uint8List?>(
          context,
          MaterialPageRoute(
            builder: (_) => PhotoEditorScreen(
              imageBytes: bytes,
              aspectRatio: aspectRatio,
              keepAlpha: keepAlpha,
              maxSize: maxSize,
            ),
          ),
        );
        if (edited == null) return null; // Abbruch im Editor
        bytes = edited;
      }
      // Hintergrund ohne Transparenz kompakt als JPEG (der Editor liefert PNG
      // – das machte Designs mehrere MB groß und auf dem Handy unlesbar).
      if (asBackground && !keepAlpha) {
        try {
          bytes = await compute(normalizeImageBytes, {
            'data': bytes,
            'keepAlpha': false,
            'maxSize': maxSize,
          });
        } catch (_) {}
      }
      final mime = keepAlpha
          ? 'image/png'
          : (asBackground ? 'image/jpeg' : 'image/png');
      return 'data:$mime;base64,${base64Encode(bytes)}';
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Bild konnte nicht geladen werden: $e')),
      );
      return null;
    }
  }

  /// Fotos verwalten (für alle Grafiktypen): hinzufügen (Kamera/Galerie),
  /// Platzierung (Hintergrund/Bereich), bearbeiten, entfernen. Mehrere möglich.
  Future<void> _managePhotos() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Fotos / Bilder',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.photo_camera),
                title: const Text('Foto aufnehmen'),
                onTap: () async {
                  await _addPhoto(ImageSource.camera);
                  setSheet(() {});
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_library),
                title: const Text('Aus Galerie'),
                onTap: () async {
                  await _addPhoto(ImageSource.gallery);
                  setSheet(() {});
                },
              ),
              if (_photos.isNotEmpty) const Divider(),
              for (final p in List<_GraphicPhoto>.from(_photos))
                ListTile(
                  leading: _photoThumb(p.dataUrl),
                  title: Text(
                    p.place == _PhotoPlace.background
                        ? 'Hintergrund'
                        : 'Foto-Bereich',
                  ),
                  subtitle: const Text('Platzierung tippen zum Wechseln'),
                  onTap: () => setSheet(() {
                    p.place = p.place == _PhotoPlace.background
                        ? _PhotoPlace.band
                        : _PhotoPlace.background;
                    setState(() {});
                  }),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Bearbeiten',
                        icon: const Icon(Icons.tune),
                        onPressed: () async {
                          await _editPhoto(p);
                          setSheet(() {});
                        },
                      ),
                      IconButton(
                        tooltip: 'Entfernen',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => setSheet(() {
                          _photos.remove(p);
                          setState(() {});
                        }),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _photoThumb(String dataUrl) {
    final bytes = TeamLogo.decode(dataUrl);
    return SizedBox(
      width: 40,
      height: 40,
      child: bytes == null
          ? const Icon(Icons.image)
          : ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.memory(bytes, fit: BoxFit.cover),
            ),
    );
  }

  /// Neues Foto wählen (mit Editor) und Platzierung abfragen.
  Future<void> _addPhoto(ImageSource source) async {
    final place = await _askPlacement();
    if (place == null || !mounted) return;
    // Hintergrund = fester Grafik-Zuschnitt (WYSIWYG). Foto-Bereich oben =
    // FREIER Zuschnitt (null) → das ganze Bild bleibt erhalten, Anzeige
    // „contain" schneidet nichts ab (Kopf etc. bleibt dran).
    final url = await _pickImage(
      asBackground: true, // Fotos immer hochauflösend laden
      source: source,
      edit: true,
      aspectRatio: place == _PhotoPlace.band ? null : _photoAspect(place),
    );
    if (url == null || !mounted) return;
    setState(() {
      _photos.add(_GraphicPhoto(url, place));
      _photoCtrl.value = Matrix4.identity();
    });
  }

  /// Großes Spielerbild bzw. rundes Badge im Poster setzen. Quelle wählbar:
  /// Kader-Profilfoto (wenn [widget.teamId] vorhanden) oder Upload/Kamera.
  /// Großes Spielerbild für das AKTUELLE Format setzen/entfernen.
  Future<void> _addPosterMain() async {
    final src0 = await _askPosterSource(hasExisting: _posterMain != null);
    if (src0 == null || !mounted) return;
    if (src0 == 'remove') {
      setState(() {
        _posterMainF[_designKey] = null;
        _imgOrig.remove('player');
        _imgFeather.remove('player');
        _imgInner.remove('player');
        _imgRim.remove('player');
      });
      return;
    }
    final src = await _resolveGoogleSource(src0);
    if (src == null || !mounted) return;
    const place = _PhotoPlace.posterMain;
    final aspect = _photoAspect(place);
    final String? url = src == 'kader'
        ? await _pickKaderPhoto(aspect)
        : await _pickImage(
            asBackground: true,
            source: src == 'camera' ? ImageSource.camera : ImageSource.gallery,
            edit: true,
            aspectRatio: aspect,
            keepAlpha: true, // transparente Freisteller-PNGs erhalten
            maxSize: 1600, // höhere Auflösung fürs große Spielerbild
          );
    if (url == null || !mounted) return;
    setState(() {
      _posterMainF[_designKey] = url;
      _imgOrig['player'] = url;
      _imgFeather['player'] = 0;
      _imgInner['player'] = 0;
      _imgRim['player'] = 0;
    });
  }

  /// Quelle für ein Poster-Foto abfragen: Kader / Galerie / Kamera (oder, wenn
  /// schon eins gesetzt ist, Entfernen).
  Future<String?> _askPosterSource({
    bool hasExisting = false,
    bool allowKader = true,
  }) => showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Bildquelle',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ),
          ),
          if (widget.teamId != null && allowKader)
            ListTile(
              leading: const Icon(Icons.groups),
              title: const Text('Kader-Spieler wählen'),
              subtitle: const Text('Nimmt das gespeicherte Profilfoto'),
              onTap: () => Navigator.pop(ctx, 'kader'),
            ),
          ListTile(
            leading: const Icon(Icons.photo_library),
            title: const Text('Aus Galerie'),
            onTap: () => Navigator.pop(ctx, 'gallery'),
          ),
          ListTile(
            leading: const Icon(Icons.photo),
            title: const Text('Google Fotos'),
            subtitle: Text(
              Platform.isAndroid
                  ? 'Im Foto-Picker auf Google Fotos wechseln'
                  : 'Oeffnet Google Fotos im Browser zum Herunterladen',
            ),
            onTap: () => Navigator.pop(ctx, 'google'),
          ),
          ListTile(
            leading: const Icon(Icons.photo_camera),
            title: const Text('Foto aufnehmen'),
            onTap: () => Navigator.pop(ctx, 'camera'),
          ),
          if (hasExisting) ...[
            const Divider(),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text(
                'Entfernen',
                style: TextStyle(color: Colors.red),
              ),
              onTap: () => Navigator.pop(ctx, 'remove'),
            ),
          ],
          const SizedBox(height: 8),
        ],
      ),
    ),
  );

  /// Behandelt die Quelle 'google'. Auf Android identisch zu 'gallery' – der
  /// System-Foto-Picker zeigt Google Fotos als Cloud-Quelle. Auf Desktop gibt
  /// es keinen System-Zugriff → Google Fotos im Browser öffnen, Hinweis zeigen
  /// und null liefern (Nutzer lädt herunter und wählt dann „Aus Galerie").
  /// Alle anderen Quellen werden unverändert durchgereicht.
  Future<String?> _resolveGoogleSource(String src) async {
    if (src != 'google') return src;
    if (Platform.isAndroid) return 'gallery';
    final messenger = ScaffoldMessenger.of(context);
    await launchUrl(
      Uri.parse('https://photos.google.com'),
      mode: LaunchMode.externalApplication,
    );
    messenger.showSnackBar(
      const SnackBar(
        content: Text(
          'Bild in Google Fotos herunterladen, dann über „Aus Galerie" wählen.',
        ),
        duration: Duration(seconds: 4),
      ),
    );
    return null;
  }

  /// Kader-Spieler auswählen und dessen Profilfoto (zugeschnitten) liefern.
  Future<String?> _pickKaderPhoto(double aspect) async {
    final teamId = widget.teamId;
    if (teamId == null) return null;
    final messenger = ScaffoldMessenger.of(context);
    final players = await context.read<AppState>().playersOf(teamId);
    if (!mounted) return null;
    if (players.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Kein Kader vorhanden.')),
      );
      return null;
    }
    // FuPa-Foto: direkt der verknüpfte Spieler (keine erneute Auswahl).
    final linked = _isFupa ? widget.designer?.playerId : null;
    final id = linked != null && players.any((p) => p.id == linked)
        ? linked
        : await Navigator.push<String?>(
            context,
            MaterialPageRoute(
              builder: (_) => PlayerPickerPage(
                players: players,
                allowNone: false,
                title: 'Spieler für das Bild',
              ),
            ),
          );
    if (id == null || id == kPlayerPickNone || !mounted) return null;
    final player = players.firstWhere(
      (p) => p.id == id,
      orElse: () => players.first,
    );
    final bytes = TeamLogo.decode(player.photoPath);
    if (bytes == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Dieser Spieler hat kein Profilfoto.')),
      );
      return null;
    }
    // Im Editor auf das Zielformat zuschneiden (WYSIWYG), Transparenz erhalten.
    final edited = await Navigator.push<Uint8List?>(
      context,
      MaterialPageRoute(
        builder: (_) => PhotoEditorScreen(
          imageBytes: bytes,
          aspectRatio: aspect,
          keepAlpha: true,
          maxSize: 1600,
        ),
      ),
    );
    if (edited == null) return null;
    return 'data:image/png;base64,${base64Encode(edited)}';
  }

  /// Platzierung für ein Foto abfragen (Hintergrund / Foto-Bereich).
  Future<_PhotoPlace?> _askPlacement() => showModalBottomSheet<_PhotoPlace>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Wohin mit dem Foto?',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.wallpaper),
            title: const Text('Als Hintergrund'),
            subtitle: const Text('Füllt die ganze Grafik hinter Logos/Texten'),
            onTap: () => Navigator.pop(ctx, _PhotoPlace.background),
          ),
          ListTile(
            leading: const Icon(Icons.photo_size_select_large),
            title: const Text('Als Foto-Bereich oben'),
            subtitle: const Text('Eigener Foto-Streifen (mehrere = Collage)'),
            onTap: () => Navigator.pop(ctx, _PhotoPlace.band),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );

  /// Ein vorhandenes Foto nachträglich im Editor bearbeiten.
  Future<void> _editPhoto(_GraphicPhoto p) async {
    final bytes = TeamLogo.decode(p.dataUrl);
    if (bytes == null) return;
    final edited = await Navigator.push<Uint8List?>(
      context,
      MaterialPageRoute(
        builder: (_) => PhotoEditorScreen(
          imageBytes: bytes,
          aspectRatio: _photoAspect(p.place),
        ),
      ),
    );
    if (edited == null || !mounted) return;
    setState(() {
      p.dataUrl = 'data:image/jpeg;base64,${base64Encode(edited)}';
      _photoCtrl.value = Matrix4.identity();
    });
  }

  Future<void> _openCustomize([String section = 'bg']) async {
    final titleCtrl = TextEditingController(text: _settings.title ?? '');
    final state = context.read<AppState>();
    var presets = await state.graphicPresets();
    if (!mounted) return;
    final club = section == 'club';
    _openPanel(
      club ? 'tool:club' : 'tool:bg',
      club
          ? 'Vereinsdaten – gilt für alle Grafiken'
          : (_isFupa ? 'FuPa-Hintergrund' : 'Hintergrund'),
      (ctx, setSheet) {
        void apply(GraphicSettings s) {
          setState(() => _settings = s); // Live-Vorschau hinter dem Sheet
          setSheet(() {});
          _refreshBgDark();
        }

        Future<void> reloadPresets() async {
          presets = await state.graphicPresets();
          setSheet(() {});
        }

        // Aktuellen Look als Vorlage speichern (Name abfragen).
        Future<void> savePreset() async {
          final nameCtrl = TextEditingController();
          final name = await showDialog<String>(
            context: ctx,
            builder: (dctx) => AlertDialog(
              title: const Text('Als Vorlage speichern'),
              content: TextField(
                controller: nameCtrl,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Name der Vorlage',
                  hintText: 'z. B. Flammen Schwarz-Gold',
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dctx),
                  child: const Text('Abbrechen'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dctx, nameCtrl.text.trim()),
                  child: const Text('Speichern'),
                ),
              ],
            ),
          );
          if (name == null || name.isEmpty) return;
          await state.saveGraphicPreset(
            GraphicPreset(
              id: const Uuid().v4(),
              name: name,
              bgImage: _settings.bgImage,
              gradTop: _settings.gradTop,
              gradBottom: _settings.gradBottom,
              overlayOpacity: _settings.overlayOpacity,
              bgOpacity: _settings.bgOpacity,
              bgBlend: _settings.bgBlend,
              accent: _settings.accent,
              createdAt: DateTime.now().toIso8601String(),
            ),
          );
          await reloadPresets();
        }

        // Vorlage auf die aktuellen Einstellungen anwenden.
        void applyPreset(GraphicPreset p) => apply(
          _settings.copyWith(
            bgImage: p.bgImage,
            clearBgImage: p.bgImage == null,
            gradTop: p.gradTop,
            gradBottom: p.gradBottom,
            overlayOpacity: p.overlayOpacity,
            bgOpacity: p.bgOpacity,
            bgBlend: p.bgBlend,
            accent: p.accent,
            clearAccent: p.accent == null,
          ),
        );

        Future<void> renamePreset(GraphicPreset p) async {
          final c = TextEditingController(text: p.name);
          final name = await showDialog<String>(
            context: ctx,
            builder: (dctx) => AlertDialog(
              title: const Text('Vorlage umbenennen'),
              content: TextField(
                controller: c,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dctx),
                  child: const Text('Abbrechen'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dctx, c.text.trim()),
                  child: const Text('Speichern'),
                ),
              ],
            ),
          );
          if (name == null || name.isEmpty) return;
          await state.saveGraphicPreset(p.copyWith(name: name));
          await reloadPresets();
        }

        Future<void> deletePreset(GraphicPreset p) async {
          final ok = await showDialog<bool>(
            context: ctx,
            builder: (dctx) => AlertDialog(
              title: Text('„${p.name}" löschen?'),
              content: const Text('Die Vorlage wird für alle entfernt.'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dctx, false),
                  child: const Text('Abbrechen'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dctx, true),
                  child: const Text('Löschen'),
                ),
              ],
            ),
          );
          if (ok != true) return;
          await state.deleteGraphicPreset(p.id);
          await reloadPresets();
        }

        if (club) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            children: [
              Row(
                children: [
                  _teamBadge(),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Name und Logos erscheinen in allen Grafiken des Teams.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: titleCtrl,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  labelText: 'Titel (Vereinsname)',
                  hintText: widget.teamName,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (v) => apply(
                  _settings.copyWith(
                    title: v.trim(),
                    clearTitle: v.trim().isEmpty,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // Logo -------------------------------------------------
              _rowWithImage(
                label: 'Vereinslogo',
                preview: _settings.logo,
                onPick: () async {
                  final url = await _pickImage(asBackground: false);
                  if (url != null) apply(_settings.copyWith(logo: url));
                },
                onClear: _settings.logo == null
                    ? null
                    : () => apply(_settings.copyWith(clearLogo: true)),
                clearLabel: 'Zurück zum Team-Logo',
              ),
              const SizedBox(height: 10),
              // Logo für dunkle Hintergründe -------------------------
              _rowWithImage(
                label: 'Logo für dunkle Hintergründe',
                preview: _settings.logoDark,
                onPick: () async {
                  final url = await _pickImage(asBackground: false);
                  if (url != null) {
                    apply(_settings.copyWith(logoDark: url));
                  }
                },
                onClear: _settings.logoDark == null
                    ? null
                    : () => apply(_settings.copyWith(clearLogoDark: true)),
                clearLabel: 'Entfernen',
              ),
            ],
          );
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            if (_isFupa) ...[
              _secHead('Art', first: true),
              _fupaBgToggle(),
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  'Gilt für dieses Design und als Vorlage für neue '
                  'FuPa-Fotos.',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ],
            _secHead(
              'Vorlagen',
              first: !_isFupa,
              team: !_isFupa,
              info:
                  'Ein Tipp setzt Farben und Bild auf einmal. Eigene '
                  'Vorlagen gelten für das ganze Team.',
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final p in _presets)
                  ActionChip(
                    avatar: Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(4),
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [_hex(p.$2), _hex(p.$3)],
                        ),
                      ),
                    ),
                    label: Text(p.$1),
                    onPressed: () => apply(
                      _settings.copyWith(
                        gradTop: p.$2,
                        gradBottom: p.$3,
                        accent: p.$4,
                        clearAccent: p.$4 == null,
                      ),
                    ),
                  ),
              ],
            ),
            if (_aiBgs.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Text('KI-Hintergründe', style: TextStyle(fontSize: 13)),
              const SizedBox(height: 6),
              _aiBgStrip(ctx, setSheet),
            ],
            if (presets.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Text('Meine Vorlagen', style: TextStyle(fontSize: 13)),
              const SizedBox(height: 6),
              for (final p in presets)
                Card(
                  margin: const EdgeInsets.only(bottom: 6),
                  child: ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.only(left: 10, right: 2),
                    leading: _presetSwatch(p),
                    title: Text(
                      p.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => applyPreset(p),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Umbenennen',
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.edit_outlined, size: 20),
                          onPressed: () => renamePreset(p),
                        ),
                        IconButton(
                          tooltip: 'Löschen',
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.delete_outline, size: 20),
                          onPressed: () => deletePreset(p),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
            const SizedBox(height: 6),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: savePreset,
                icon: const Icon(Icons.bookmark_add_outlined),
                label: const Text(
                  'Aktuellen Hintergrund als Vorlage speichern',
                ),
              ),
            ),
            _secHead('Farben', team: !_isFupa),
            const Text('Verlauf oben', style: TextStyle(fontSize: 13)),
            const SizedBox(height: 6),
            _swatches(
              selected: _settings.gradTop,
              onPick: (hex) => apply(_settings.copyWith(gradTop: hex)),
            ),
            const SizedBox(height: 10),
            const Text('Verlauf unten', style: TextStyle(fontSize: 13)),
            const SizedBox(height: 6),
            _swatches(
              selected: _settings.gradBottom,
              onPick: (hex) => apply(_settings.copyWith(gradBottom: hex)),
            ),
            const SizedBox(height: 10),
            BgStyleControls(
              shape: _settings.gradShape,
              pattern: _settings.bgPattern,
              onShape: (v) => apply(
                _settings.copyWith(gradShape: v, clearGradShape: v == null),
              ),
              onPattern: (v) => apply(_settings.copyWith(bgPattern: v)),
            ),
            _secHead(
              'Bild & Foto',
              team: !_isFupa,
              info:
                  'Hintergrundbild = ein Bild für den ganzen Hintergrund. '
                  '„Fotos“ legt eigene Fotos als Hintergrund oder in einen '
                  'Foto-Bereich.',
            ),
            _rowWithImage(
              label: 'Hintergrundbild',
              preview: _settings.bgImage,
              onPick: () async {
                final url = await _pickImage(
                  asBackground: true,
                  edit: true,
                  aspectRatio: _photoAspect(_PhotoPlace.background),
                );
                if (url == null) return;
                // FuPa: importierter Hintergrund genau wie die Datei –
                // volle Deckkraft, nicht abgedunkelt.
                apply(
                  _isFupa
                      ? _settings.copyWith(
                          bgImage: url,
                          bgOpacity: 100,
                          overlayOpacity: 0,
                          bgBlend: 'normal',
                        )
                      : _settings.copyWith(bgImage: url),
                );
              },
              onClear: _settings.bgImage == null
                  ? null
                  : () => apply(_settings.copyWith(clearBgImage: true)),
              clearLabel: 'Entfernen',
            ),
            const SizedBox(height: 6),
            OutlinedButton.icon(
              onPressed: _managePhotos,
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('Fotos als Hintergrund/Bereich'),
            ),
            if (_settings.bgImage != null) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Text(
                    'Deckkraft ${_settings.bgOpacity}%',
                    style: const TextStyle(fontSize: 13),
                  ),
                  _infoIcon('Wie stark das Bild sichtbar ist.'),
                ],
              ),
              Slider(
                value: _settings.bgOpacity.toDouble(),
                min: 0,
                max: 100,
                divisions: 20,
                label: '${_settings.bgOpacity}%',
                onChanged: (v) =>
                    apply(_settings.copyWith(bgOpacity: v.round())),
              ),
              Row(
                children: [
                  Text(
                    'Abdunkeln ${_settings.overlayOpacity}%',
                    style: const TextStyle(fontSize: 13),
                  ),
                  _infoIcon(
                    'Dunkelt das Bild ab, damit Schrift und Logos besser '
                    'lesbar sind.',
                  ),
                ],
              ),
              Slider(
                value: _settings.overlayOpacity.toDouble(),
                min: 0,
                max: 100,
                divisions: 20,
                label: '${_settings.overlayOpacity}%',
                onChanged: (v) =>
                    apply(_settings.copyWith(overlayOpacity: v.round())),
              ),
              Row(
                children: [
                  const Text('Mischmodus', style: TextStyle(fontSize: 13)),
                  _infoIcon(
                    'Wie das Bild mit dem Farbverlauf verschmilzt – '
                    'einfach ausprobieren.',
                  ),
                ],
              ),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final b in _blendOptions)
                    ChoiceChip(
                      label: Text(b.$2),
                      selected: _settings.bgBlend == b.$1,
                      onSelected: (_) =>
                          apply(_settings.copyWith(bgBlend: b.$1)),
                    ),
                ],
              ),
            ],
            if (widget.isResult) ...[
              _secHead('Aufbau'),
              Center(
                child: _resultLayoutToggle(onChanged: () => setSheet(() {})),
              ),
              if (_ftLayout) ...[
                const SizedBox(height: 6),
                OutlinedButton.icon(
                  icon: const Icon(Icons.add_photo_alternate, size: 18),
                  label: Text(
                    _ftPhotoF[_designKey] == null
                        ? 'Foto oben wählen'
                        : 'Foto oben ändern / entfernen',
                  ),
                  onPressed: _pickFtPhoto,
                ),
                if (_ftPhotoF[_designKey] != null)
                  _ftPhotoScaleControls(refresh: () => setSheet(() {})),
              ],
            ],
          ],
        );
      },
      onClose: () => _saveCustomize(state),
    );
  }

  /// Hintergrund-Panel geschlossen → speichern + in die Cloud spiegeln.
  Future<void> _saveCustomize(AppState state) async {
    if (!mounted) return;
    if (_isFupa) {
      // FuPa: Hintergrund gehört zu DIESEM Design. Zusätzlich als Team-Vorlage
      // für NEUE FuPa-Fotos sichern – fertige Designs bleiben unverändert.
      final bg = _currentFupaBg();
      setState(() => _fupaBgSnap = bg.toMap());
      await state.saveGraphicPreset(bg);
      // Verlaufsform/Muster gelten teamweit – auch hier mitspeichern.
      final team = await state.graphicSettings();
      if (team.gradShape != _settings.gradShape ||
          team.bgPattern != _settings.bgPattern) {
        final upd = team.copyWith(
          gradShape: _settings.gradShape,
          clearGradShape: _settings.gradShape == null,
          bgPattern: _settings.bgPattern,
        );
        _teamSettings = upd;
        await state.saveGraphicSettings(upd);
        await state.pushGraphicSettingsToCloud();
      }
      return;
    }
    await state.saveGraphicSettings(_settings);
    await state.pushGraphicSettingsToCloud();
  }

  Widget _rowWithImage({
    required String label,
    required String? preview,
    required Future<void> Function() onPick,
    required VoidCallback? onClear,
    required String clearLabel,
  }) {
    return Row(
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          clipBehavior: Clip.antiAlias,
          child: preview != null
              ? Image.memory(
                  TeamLogo.decode(preview) ?? Uint8List(0),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const Icon(Icons.image),
                )
              : Icon(Icons.image_outlined, color: Theme.of(context).hintColor),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              if (onClear != null)
                InkWell(
                  onTap: onClear,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                      clearLabel,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton(onPressed: onPick, child: const Text('Wählen')),
      ],
    );
  }

  Widget _swatches({
    required String selected,
    required void Function(String) onPick,
    List<String>? palette,
    bool allowFree = false,
  }) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final hex in (palette ?? _palette))
          GestureDetector(
            onTap: () => onPick(hex),
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: _hex(hex),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: selected.toUpperCase() == hex.toUpperCase()
                      ? Theme.of(context).colorScheme.primary
                      : Colors.black26,
                  width: selected.toUpperCase() == hex.toUpperCase() ? 3 : 1,
                ),
              ),
            ),
          ),
        if (allowFree)
          GestureDetector(
            onTap: () async {
              final hex = await _pickColor(selected);
              if (hex != null) onPick(hex);
            },
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                gradient: const SweepGradient(
                  colors: [
                    Colors.red,
                    Colors.yellow,
                    Colors.green,
                    Colors.cyan,
                    Colors.blue,
                    Colors.purple,
                    Colors.red,
                  ],
                ),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.black26),
              ),
              child: const Icon(Icons.colorize, size: 16, color: Colors.white),
            ),
          ),
      ],
    );
  }

  /// Ein Slider-Zeile für den Farbwähler.
  Widget _hsvSlider(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged,
  ) => Row(
    children: [
      SizedBox(
        width: 80,
        child: Text(label, style: const TextStyle(fontSize: 12)),
      ),
      Expanded(
        child: Slider(value: value, min: min, max: max, onChanged: onChanged),
      ),
    ],
  );

  /// Freier Farbwähler (HSV) → gibt Hex „#RRGGBB" zurück oder null (Abbruch).
  Future<String?> _pickColor(String initialHex) async {
    var hsv = HSVColor.fromColor(_hex(initialHex));
    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final color = hsv.toColor();
          final hex =
              '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
          return AlertDialog(
            title: const Text('Farbe wählen'),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    height: 44,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.black26),
                    ),
                  ),
                  const SizedBox(height: 8),
                  _hsvSlider(
                    'Farbton',
                    hsv.hue,
                    0,
                    360,
                    (v) => setLocal(() => hsv = hsv.withHue(v)),
                  ),
                  _hsvSlider(
                    'Sättigung',
                    hsv.saturation,
                    0,
                    1,
                    (v) => setLocal(() => hsv = hsv.withSaturation(v)),
                  ),
                  _hsvSlider(
                    'Helligkeit',
                    hsv.value,
                    0,
                    1,
                    (v) => setLocal(() => hsv = hsv.withValue(v)),
                  ),
                  Text(hex, style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Abbrechen'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, hex),
                child: const Text('Übernehmen'),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Kleine Vorschau einer Hintergrund-Vorlage (Bild bzw. Verlauf + Akzentrand).
  Widget _presetSwatch(GraphicPreset p) {
    final bytes = TeamLogo.decode(p.bgImage);
    final accent = p.accent;
    return Container(
      width: 38,
      height: 38,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_hex(p.gradTop), _hex(p.gradBottom)],
        ),
        border: accent != null
            ? Border.all(color: _hex(accent), width: 2)
            : null,
      ),
      child: bytes != null
          ? Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true)
          : null,
    );
  }

  /// Die aktuell angezeigte Grafik als PNG-Bytes aufnehmen (1080 px breit).
  /// Ton-Matrix: Helligkeit (Offset), Kontrast (Skalierung um 128), Wärme
  /// (R leicht hoch, B leicht runter). Muster wie `_previewMatrix` im Editor.
  /// Legt das Profi-Finish (globale Korrektur) um die fertige Grafik. Wirkt nur
  /// aufs Gesamtbild – Elemente/Positionen/Inhalte bleiben unverändert. Liegt in
  /// der RepaintBoundary → live sichtbar UND im Export enthalten.
  Widget _gradeWrap(Widget child) {
    final g = _grade;
    if (!g.on) return child;
    Widget out = ColorFiltered(
      colorFilter: ColorFilter.matrix(g.matrix()),
      child: child,
    );
    if (g.vignette > 0 || g.grain > 0) {
      out = Stack(
        fit: StackFit.expand,
        children: [
          out,
          // Filmkorn: kachelbares Korn, Stärke über die Deckkraft.
          if (g.grain > 0)
            IgnorePointer(
              child: Opacity(
                opacity: (g.grain / 100).clamp(0.0, 1.0),
                child: Image.memory(
                  kGrainTile,
                  repeat: ImageRepeat.repeat,
                  scale: 2,
                  filterQuality: FilterQuality.none,
                  gaplessPlayback: true,
                ),
              ),
            ),
          // Vignette: Größe = wie weit sie hereinreicht, Weichheit = Übergang.
          if (g.vignette > 0)
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    radius: 0.65 + g.vigSize * 0.006,
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: (g.vignette / 100) * 0.6),
                    ],
                    stops: [(0.9 - g.vigSoft * 0.007).clamp(0.05, 0.95), 1.0],
                  ),
                ),
              ),
            ),
        ],
      );
    }
    return out;
  }

  Future<Uint8List?> _captureGraphicPng() => _capturePng(_boundaryKey);

  /// Nur die Hintergrund-Ebene (ohne Logos/Text/Sponsoren) als PNG.
  Future<Uint8List?> _captureBackgroundPng() => _capturePng(_bgBoundaryKey);

  Future<Uint8List?> _capturePng(GlobalKey key) async {
    // Höhere Export-Auflösung (1440 px Breite → 1440×2560 bzw. 1440×1440).
    final image = await _captureImage(key, _format == 'f' ? 960 : 1440);
    if (image == null) return null;
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  }

  /// Kleine Aufnahme NUR für die KI-Analyse: direkt in [widthPx] Breite und als
  /// Rohpixel → JPEG. Spart das teure Kodieren/Dekodieren der großen
  /// Export-PNG (auf dem Handy mehrere Sekunden).
  Future<String?> _captureForAi({double widthPx = 512}) async {
    final image = await _captureImage(_boundaryKey, widthPx);
    if (image == null) return null;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return null;
    return compute(_rgbaToJpegDataUrl, <String, Object>{
      'w': image.width,
      'h': image.height,
      'px': data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    });
  }

  /// Rohpixel (RGBA) → JPEG-Data-URL (läuft im Isolate).
  static String _rgbaToJpegDataUrl(Map<String, Object> a) {
    final px = a['px'] as Uint8List;
    final im = img.Image.fromBytes(
      width: a['w'] as int,
      height: a['h'] as int,
      bytes: px.buffer,
      bytesOffset: px.offsetInBytes,
      numChannels: 4,
    );
    final jpg = img.encodeJpg(im, quality: 80);
    return 'data:image/jpeg;base64,${base64Encode(jpg)}';
  }

  /// Nimmt die Grafik hinter [key] in [widthPx] Breite auf (ohne Auswahlrahmen,
  /// mit geladenen Schriften/Bildern).
  Future<ui.Image?> _captureImage(GlobalKey key, double widthPx) async {
    // Auswahl-Rahmen eines Poster-Elements nicht mit exportieren.
    final hadSel = _posterSel;
    if (hadSel != null && mounted) {
      setState(() => _posterSel = null);
      await WidgetsBinding.instance.endOfFrame;
    }
    // Gewählte Schriftart sicher geladen haben, bevor exportiert wird.
    try {
      await GoogleFonts.pendingFonts();
      await WidgetsBinding.instance.endOfFrame;
    } catch (_) {}
    // Kurz warten, damit (neu) dekodierte Bilder – Spieler/Overlays – sicher
    // gezeichnet sind, bevor die Grafik aufgenommen wird.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await WidgetsBinding.instance.endOfFrame;
    final boundary =
        key.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) return null;
    final logicalWidth = _cw;
    return boundary.toImage(pixelRatio: widthPx / logicalWidth);
  }

  String get _kind => widget.designer != null
      ? widget.designer!.templateLabel
      : widget.isAnnouncement
      ? 'Spieltag'
      : (widget.isResult ? 'Ergebnis' : 'Startelf');

  Future<void> _share() async {
    if (_sharing) return;
    setState(() => _sharing = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final bytes = await _captureGraphicPng();
      if (bytes == null) return;
      final kind = _kind;
      final savedPath = await shareOrSaveImage(
        bytes,
        '${kind}_$_title',
        text: '$kind – $_title',
      );
      if (savedPath != null && mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: Text('Als Bild gespeichert und geöffnet:\n$savedPath'),
            duration: const Duration(seconds: 6),
          ),
        );
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Teilen fehlgeschlagen: $e')),
      );
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  /// Nur speichern (ohne Teilen): PNG in den Downloads-Ordner (Desktop) bzw.
  /// app-eigenen Ordner (mobil) sichern und zur Kontrolle öffnen.
  Future<void> _saveImage() async {
    if (_sharing || _aiBusy) return;
    setState(() => _sharing = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final bytes = await _captureGraphicPng();
      if (bytes == null) return;
      final path = await saveImage(bytes, '${_kind}_$_title');
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text('Gespeichert:\n$path'),
          duration: const Duration(seconds: 6),
        ),
      );
      try {
        await OpenFilex.open(path);
      } catch (_) {
        // Öffnen optional – die Datei ist gespeichert.
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Speichern fehlgeschlagen: $e')),
      );
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  /// Nur die Hintergrund-Ebene (ohne Logos/Text/Sponsoren) als Bild speichern –
  /// z.B. um den gestalteten Hintergrund weiterzuverwenden.
  Future<void> _saveBackground() async {
    if (_sharing || _aiBusy) return;
    setState(() => _sharing = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final bytes = await _captureBackgroundPng();
      if (bytes == null) return;
      final path = await saveImage(bytes, 'Hintergrund_$_title');
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text('Hintergrund gespeichert:\n$path'),
          duration: const Duration(seconds: 6),
        ),
      );
      try {
        await OpenFilex.open(path);
      } catch (_) {
        // Öffnen optional – die Datei ist gespeichert.
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Speichern fehlgeschlagen: $e')),
      );
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  /// Mime-Typ aus einer data:-URL lesen (Default image/png).
  String _dataUrlMime(String dataUrl) {
    final m = RegExp(r'^data:([^;]+);').firstMatch(dataUrl);
    return m?.group(1) ?? 'image/png';
  }

  /// Referenzbilder für die KI im Hintergrund-Modus: NUR vom Nutzer hinzugefügte
  /// Fotos – KEINE Logos/Sponsoren (die soll die KI nicht in den Hintergrund
  /// bauen). Darf leer sein → reine Text-zu-Bild-Gestaltung.
  List<Map<String, String>> _bgReferenceImages() => [
    for (final p in _photos)
      if (p.dataUrl.contains('base64,'))
        {'mime': _dataUrlMime(p.dataUrl), 'data': p.dataUrl, 'role': 'photo'},
  ];

  /// „Mit KI gestalten": Wunsch abfragen → die KI erzeugt NUR einen Hintergrund
  /// (keine Logos/Texte); die App setzt ihn als Hintergrund und legt die echten
  /// Logos/Namen/Sponsoren scharf darüber.
  Future<void> _aiEdit() async {
    if (_aiBusy) return;
    final wish = await _askAiWish();
    if (wish == null || wish.prompt.trim().isEmpty || !mounted) return;
    setState(() {
      _aiBusy = true;
      _aiBusyLabel = 'KI gestaltet den Hintergrund …';
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      final images = _bgReferenceImages();
      final colors =
          'Vereinsfarben als Orientierung: ${_settings.gradTop}, '
          '${_settings.gradBottom}. Erzeuge NUR einen Hintergrund – KEINE Logos, '
          'Wappen, Namen, Zahlen oder Texte.';
      final fullPrompt = '$colors\n\nWunsch: ${wish.prompt.trim()}';
      final out = await CloudService.aiImage(
        images: images,
        prompt: fullPrompt,
        mode: wish.mode,
        aspect: _aiAspect,
      );
      if (out == null) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Die KI hat kein Bild zurückgegeben.')),
        );
        return;
      }
      if (!mounted) return;
      if (wish.mode == 'background') {
        // Kompakt als JPEG (PNG aus der KI wäre mehrere MB je Bild).
        Uint8List jpg;
        try {
          jpg = await compute(_aiBgJpeg, out);
        } catch (_) {
          jpg = out;
        }
        if (!mounted) return;
        final mime = jpg == out ? 'png' : 'jpeg';
        setState(
          () => _pushAiBg('data:image/$mime;base64,${base64Encode(jpg)}'),
        );
        _refreshBgDark();
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'KI-Hintergrund gesetzt. Ein-/ausschalten und frühere '
              'Hintergründe unter „Hinzufügen & Hintergrund".',
            ),
            duration: Duration(seconds: 5),
          ),
        );
        return;
      }
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => _AiResultPreview(
            bytes: out,
            name: '${_kind}_KI_$_title',
            shareText: '$_kind – $_title',
            onRetry: _aiEdit,
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(aiErrorMessage(e)),
          duration: const Duration(seconds: 6),
        ),
      );
    } finally {
      if (mounted) setState(() => _aiBusy = false);
    }
  }

  /// Spieler automatisch an den Hintergrund anpassen: Farbe/Helligkeit
  /// angleichen, Licht & Schatten aus der Lichtrichtung, weicher Schlagschatten
  /// auf den Hintergrund (Gegenseite).
  void _autoFitPlayerLight() {
    final g = _grade;
    g.match = 25;
    g.shade = 40;
    g.warm = 50;
    _posterShadow = true;
    _posterShadowStrength = 35;
    _posterShadowAngle = (g.lightDir + 180) % 360;
  }

  /// Lesbare Lichtrichtung („von links oben" …) für den Regler.
  String _lightDirLabel(double deg) {
    // Woher das Licht kommt (kurz, passt in die Werte-Spalte).
    const names = [
      'rechts',
      're. u.',
      'unten',
      'li. u.',
      'links',
      'li. o.',
      'oben',
      're. o.',
    ];
    final i = (((deg % 360) + 360 + 22.5) % 360 ~/ 45) % 8;
    return names[i];
  }

  /// „Mit KI optimieren": nimmt die fertige Grafik, lässt die Vision-KI globale
  /// Korrekturwerte (Helligkeit/Kontrast/Sättigung/Wärme/Tiefe) schätzen und
  /// wendet sie als Profi-Finish an. Verändert KEINE Inhalte, nur das Gesamtbild.
  Future<void> _aiFinish() async {
    if (_gradeBusy || _aiBusy) return;
    setState(() => _gradeBusy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      // Kleine Aufnahme direkt in Analyse-Größe (schnell, wenige Tokens).
      final dataUrl = await _captureForAi();
      if (dataUrl == null || !mounted) return;
      final vals = await CloudService.aiGrade(dataUrl);
      if (vals == null) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Die KI hat keine Werte zurückgegeben.'),
          ),
        );
        return;
      }
      if (!mounted) return;
      double num0(String k) {
        final v = vals[k];
        if (v is num) return v.toDouble();
        if (v is String) return double.tryParse(v) ?? 0;
        return 0;
      }

      setState(() {
        final g = _grade;
        g.brightness = num0('brightness').clamp(-100, 100).toDouble();
        g.contrast = num0('contrast').clamp(-100, 100).toDouble();
        g.saturation = num0('saturation').clamp(-100, 100).toDouble();
        g.warmth = num0('warmth').clamp(-100, 100).toDouble();
        g.vignette = num0('vignette').clamp(0, 100).toDouble();
        g.on = true;
      });
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'KI-Finish angewendet – mit den Reglern nachjustierbar.',
          ),
          duration: Duration(seconds: 4),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(aiErrorMessage(e)),
          duration: const Duration(seconds: 6),
        ),
      );
    } finally {
      if (mounted) setState(() => _gradeBusy = false);
    }
  }

  /// Bedien-Panel „Profi-Finish": An/Aus, KI-Optimierung (falls freigeschaltet)
  /// und Regler für die globale Bildkorrektur. Für alle Grafiktypen.
  Widget _gradeControls({bool panel = false}) {
    final g = _grade;
    final canAi = context.watch<AppState>().canAiCoach;
    Widget slider(
      String label,
      double value,
      double min,
      double max,
      ValueChanged<double> onCh, {
      String unit = '',
    }) {
      return Row(
        children: [
          SizedBox(
            width: 118,
            child: Text(label, style: const TextStyle(fontSize: 13)),
          ),
          Expanded(
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: g.on ? onCh : null,
            ),
          ),
          SizedBox(
            width: 40,
            child: Text(
              '${value.round()}$unit',
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      );
    }

    // Aufklappbare Regler-Gruppe (Basis offen, Rest zu – übersichtlich).
    Widget group(String title, List<Widget> children, {bool open = false}) =>
        ExpansionTile(
          title: Text(
            title,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          initiallyExpanded: open,
          dense: true,
          tilePadding: EdgeInsets.zero,
          childrenPadding: EdgeInsets.zero,
          shape: const Border(),
          collapsedShape: const Border(),
          children: children,
        );

    final kids = <Widget>[
      if (panel)
        _switchRow('Filter anwenden', g.on, (v) => setState(() => g.on = v))
      else
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Finish anwenden'),
          subtitle: const Text(
            'Wirkt nur aufs Gesamtbild – Inhalte bleiben unverändert',
          ),
          value: g.on,
          onChanged: (v) => setState(() => g.on = v),
        ),
      if (canAi && !panel)
        SizedBox(
          width: double.infinity,
          child: FilledButton.tonalIcon(
            onPressed: _gradeBusy ? null : _aiFinish,
            icon: _gradeBusy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_awesome),
            label: Text(_gradeBusy ? 'KI analysiert …' : 'Mit KI optimieren'),
          ),
        ),
      const SizedBox(height: 8),
      // Look-Vorlagen: ein Tipp setzt alle Regler (danach nachjustierbar).
      Align(
        alignment: Alignment.centerLeft,
        child: Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final p in kGradePresets)
              ActionChip(
                avatar: Icon(
                  p.$1 == kFupaStyleName
                      ? Icons.wb_sunny_outlined
                      : Icons.palette_outlined,
                  size: 16,
                ),
                label: Text(p.$1),
                onPressed: () => setState(() {
                  g.applyValues(p.$2);
                  g.on = true;
                  // FuPa-Style: auch Schlagschatten passend zum Licht.
                  if (p.$1 == kFupaStyleName) _autoFitPlayerLight();
                }),
              ),
          ],
        ),
      ),
      group('Basis', open: !panel, [
        slider(
          'Helligkeit',
          g.brightness,
          -100,
          100,
          (v) => setState(() => g.brightness = v),
        ),
        slider(
          'Kontrast',
          g.contrast,
          -100,
          100,
          (v) => setState(() => g.contrast = v),
        ),
        slider(
          'Sättigung',
          g.saturation,
          -100,
          100,
          (v) => setState(() => g.saturation = v),
        ),
        slider(
          'Wärme',
          g.warmth,
          -100,
          100,
          (v) => setState(() => g.warmth = v),
        ),
      ]),
      group('Licht', [
        slider(
          'Belichtung',
          g.exposure,
          -100,
          100,
          (v) => setState(() => g.exposure = v),
        ),
        slider(
          'Lichter',
          g.highlights,
          -100,
          100,
          (v) => setState(() => g.highlights = v),
        ),
        slider(
          'Tiefen',
          g.shadows,
          -100,
          100,
          (v) => setState(() => g.shadows = v),
        ),
      ]),
      group('Farbe', [
        slider(
          'Tönung (Gr↔Mag)',
          g.tint,
          -100,
          100,
          (v) => setState(() => g.tint = v),
        ),
        slider(
          'Farbton',
          g.hue,
          -180,
          180,
          (v) => setState(() => g.hue = v),
          unit: '°',
        ),
        slider('Rot', g.red, -100, 100, (v) => setState(() => g.red = v)),
        slider('Grün', g.green, -100, 100, (v) => setState(() => g.green = v)),
        slider('Blau', g.blue, -100, 100, (v) => setState(() => g.blue = v)),
      ]),
      group('Effekte', [
        slider(
          'Fade (matt)',
          g.fade,
          0,
          100,
          (v) => setState(() => g.fade = v),
        ),
        slider('Körnung', g.grain, 0, 100, (v) => setState(() => g.grain = v)),
        slider(
          'Vignette',
          g.vignette,
          0,
          100,
          (v) => setState(() => g.vignette = v),
        ),
        slider(
          'Vignette-Größe',
          g.vigSize,
          0,
          100,
          (v) => setState(() => g.vigSize = v),
        ),
        slider(
          'Vignette-Weichheit',
          g.vigSoft,
          0,
          100,
          (v) => setState(() => g.vigSoft = v),
        ),
      ]),
      Align(
        alignment: Alignment.centerRight,
        child: TextButton(
          onPressed: () => setState(g.resetValues),
          child: const Text('Alles zurücksetzen'),
        ),
      ),
    ];
    if (panel) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: kids,
      );
    }
    return ExpansionTile(
      leading: const Icon(Icons.auto_fix_high),
      title: const Text('Profi-Finish (Gesamtbild)'),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      children: kids,
    );
  }

  /// Data-URL des aktuell gewählten Bild-Elements (Spieler oder Overlay), sonst
  /// null (Text/Logos/Sponsor sind keine ersetzbaren Bilder).
  String? _selectedImageDataUrl() {
    final sel = _posterSel;
    if (sel == null) return null;
    if (sel == 'player') return _posterMain;
    if (sel.startsWith('overlay_')) {
      for (final o in _posterOverlays) {
        if (o.id == sel) return o.dataUrl;
      }
    }
    return null;
  }

  /// Ersetzt das Bild des aktuell gewählten Elements durch [url].
  void _setSelectedImageDataUrl(String url) {
    final sel = _posterSel;
    if (sel == null) return;
    if (sel == 'player') {
      _posterMainF[_designKey] = url;
    } else if (sel.startsWith('overlay_')) {
      final i = _posterOverlays.indexWhere((o) => o.id == sel);
      if (i >= 0) _posterOverlays[i] = (id: sel, dataUrl: url);
    } else {
      return;
    }
    // Neues Original für Bildeffekte; Feather/innerer Schatten zurücksetzen.
    _imgOrig[sel] = url;
    _imgFeather[sel] = 0;
    _imgInner[sel] = 0;
    _imgRim[sel] = 0;
  }

  /// Setzt nur das ANGEZEIGTE Bild eines Elements (ohne Original zu ändern).
  void _setImageById(String id, String url) {
    if (id == 'player') {
      _posterMainF[_designKey] = url;
    } else if (id.startsWith('overlay_')) {
      final i = _posterOverlays.indexWhere((o) => o.id == id);
      if (i >= 0) _posterOverlays[i] = (id: id, dataUrl: url);
    }
  }

  /// Bildeffekte (weiche Kanten + innerer Schatten) auf das Element [id]
  /// anwenden – immer aus dem Original neu berechnet (kein Verschlechtern).
  Future<void> _applyImageFx(String id) async {
    // Läuft schon eine Berechnung? Wunsch merken und danach nachholen – die
    // Regler bleiben dabei frei beweglich (keine Sperre mehr).
    if (_featherBusy) {
      _fxPending = id;
      return;
    }
    final orig = _imgOrig[id];
    if (orig == null) return;
    final feather = _imgFeather[id] ?? 0;
    final inner = _imgInner[id] ?? 0;
    final rim = _imgRim[id] ?? 0;
    if (feather <= 0 && inner <= 0 && rim <= 0) {
      setState(() => _setImageById(id, orig));
      return;
    }
    final bytes = TeamLogo.decode(orig);
    if (bytes == null) return;
    setState(() => _featherBusy = true);
    try {
      final out = await compute(applyImageFx, {
        'data': bytes,
        'feather': feather,
        'inner': inner,
        'angle': _posterShadowAngle * math.pi / 180,
        'rim': rim,
      });
      if (!mounted) return;
      setState(
        () => _setImageById(id, 'data:image/png;base64,${base64Encode(out)}'),
      );
    } catch (_) {
      // Bildeffekt fehlgeschlagen – Bild bleibt wie es war.
    } finally {
      if (mounted) setState(() => _featherBusy = false);
      final pend = _fxPending;
      if (pend != null && mounted) {
        _fxPending = null;
        _applyImageFx(pend);
      }
    }
  }

  /// KI-Freisteller für das GEWÄHLTE Bild (Spieler oder Overlay): entfernt den
  /// Foto-Hintergrund, damit der Hintergrund dahinter erscheint.
  Future<void> _cutoutSelected() async {
    if (_aiBusy) return;
    final messenger = ScaffoldMessenger.of(context);
    if (!context.read<AppState>().canAiImage) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Die Grafik-KI ist für dein Konto nicht freigeschaltet. Der '
            'Team-Admin kann sie unter Einstellungen → KI-Berechtigungen '
            'einschalten.',
          ),
          duration: Duration(seconds: 6),
        ),
      );
      return;
    }
    final sel =
        _posterSel; // Ziel merken – Auswahl kann sich währenddessen ändern
    final src = _selectedImageDataUrl();
    final srcBytes = src == null ? null : TeamLogo.decode(src);
    if (sel == null || srcBytes == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Erst ein Bild auswählen (antippen).')),
      );
      return;
    }
    final subject = await _askCutoutSubject();
    if (subject == null || !mounted) return;
    setState(() {
      _aiBusy = true;
      _aiBusyLabel = 'KI stellt frei …';
    });
    try {
      // Verkleinert + JPEG senden (schneller, unter allen Größen-Grenzen).
      final send = await compute(downscaleForCutout, srcBytes);
      // Bis zu 3 Versuche: Hat die KI den Hintergrund NICHT ersetzt (Bild
      // praktisch unverändert) oder ist die Anfrage abgebrochen (Zeitlimit,
      // Server kurz weg), wird automatisch einmal mit einer kürzeren,
      // eindeutigeren Anweisung neu versucht.
      Uint8List? png;
      Object? lastError;
      var unchanged = 0; // Antworten ohne entfernten Hintergrund
      for (var attempt = 0; attempt < 3 && png == null; attempt++) {
        // „Nichts freigestellt" höchstens 2× versuchen (kostet KI-Guthaben).
        if (unchanged >= 2) break;
        if (attempt > 0 && mounted) {
          setState(
            () => _aiBusyLabel = 'KI stellt frei … (${attempt + 1}. Versuch)',
          );
          // Kurz durchatmen – hilft bei kurzer Überlast/Netzwackler.
          await Future<void>.delayed(const Duration(milliseconds: 1500));
        }
        try {
          final out = await CloudService.aiImage(
            images: [
              {
                'mime': 'image/jpeg',
                'data': 'data:image/jpeg;base64,${base64Encode(send)}',
                'role': 'photo',
              },
            ],
            prompt: subject,
            mode: 'cutout',
            aspect: _aiAspect,
            key: 'magenta',
            retry: unchanged > 0,
          );
          if (out == null) {
            unchanged++;
            continue;
          }
          // KI liefert das Motiv auf Magenta → transparent machen; hält sie
          // sich nicht daran (anderer Grund), wird die Randfarbe entfernt.
          final keyed = await compute(cutoutFinish, out);
          // Erfolg nur, wenn wirklich Hintergrund weg ist (Rand durchsichtig).
          if (await compute(cutoutLooksDone, keyed)) {
            png = keyed;
          } else {
            unchanged++;
          }
        } catch (e) {
          lastError = e;
          // Nur vorübergehende Fehler erneut versuchen.
          if (!_isTransientAiError(e)) rethrow;
        }
      }
      if (!mounted) return;
      if (png == null) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              lastError != null
                  ? aiErrorMessage(lastError)
                  : 'Die KI hat den Hintergrund nicht entfernt – das Bild '
                        'bleibt unverändert. Bitte erneut versuchen, evtl. '
                        'mit genauerem Motiv (z. B. „der Spieler in der '
                        'Mitte").',
            ),
            duration: const Duration(seconds: 7),
          ),
        );
        return;
      }
      final url = 'data:image/png;base64,${base64Encode(png)}';
      setState(() {
        _setImageById(sel, url);
        _imgOrig[sel] = url;
        // Wirkt „im Bild" statt aufgeklebt: weiche Kante + Rand verschmelzen
        // (Regler im Element-Menü zum Nachjustieren).
        _imgFeather[sel] = _kCutoutFeather;
        _imgInner[sel] = 0;
        _imgRim[sel] = _kCutoutRim;
      });
      unawaited(_applyImageFx(sel));
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Freigestellt. Reste am Rand? „Weiche Kanten" etwas erhöhen oder '
            'mit genauerem Motiv erneut freistellen.',
          ),
          duration: Duration(seconds: 5),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(aiErrorMessage(e)),
          duration: const Duration(seconds: 6),
        ),
      );
    } finally {
      if (mounted) setState(() => _aiBusy = false);
    }
  }

  /// Abfrage vor dem KI-Freistellen: WELCHES Motiv bleiben soll (alles andere
  /// wird entfernt). Vorschläge + freies Textfeld. null = abgebrochen.
  Future<String?> _askCutoutSubject() async {
    final ctrl = TextEditingController(
      text: 'Den Spieler im Vordergrund (nur diese eine Person)',
    );
    const ideas = <String>[
      'Den Spieler in der Mitte',
      'Den Spieler im Vordergrund',
      'Alle Personen',
      'Die Person links',
      'Die Person rechts',
      'Den Spieler mit dem Ball',
    ];
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: const Text('Was soll freigestellt werden?'),
        content: SizedBox(
          width: double.maxFinite,
          child: StatefulBuilder(
            builder: (ctx, setLocal) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Nur dieses Motiv bleibt – Wand, Boden, andere Personen und '
                  'alles andere wird entfernt.',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final s in ideas)
                      ChoiceChip(
                        label: Text(s),
                        selected: ctrl.text == s,
                        onSelected: (_) => setLocal(() {
                          ctrl.text = s;
                          ctrl.selection = TextSelection.collapsed(
                            offset: s.length,
                          );
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: ctrl,
                  maxLines: 2,
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: (_) => setLocal(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Motiv (frei beschreiben)',
                    hintText: 'z. B. Spieler mit Nr. 7 im roten Trikot',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () {
              final t = ctrl.text.trim();
              if (t.isEmpty) return;
              Navigator.pop(ctx, t);
            },
            child: const Text('Freistellen'),
          ),
        ],
      ),
    );
  }

  /// Einfarbigen Hintergrund des GEWÄHLTEN Bildes clientseitig entfernen (ohne
  /// KI). Nutzt [removeUniformBackground] in einem Isolate.
  /// Rosa/Magenta-Reste (vom KI-Freistellen) aus dem gewählten Bild entfernen
  /// – lokal, ohne neue KI-Anfrage; auch eingeschlossene Flächen (z. B.
  /// zwischen Arm und Körper).
  Future<void> _removePinkSelected() async {
    if (_bgBusy) return;
    final sel = _posterSel;
    // Vom ORIGINAL (ohne eingebackene Kanten-Effekte wie einen dunklen Ring)
    // ausgehen, sonst bleiben alte Effekte im Bild.
    final src = (sel == null ? null : _imgOrig[sel]) ?? _selectedImageDataUrl();
    final bytes = src == null ? null : TeamLogo.decode(src);
    if (sel == null || bytes == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Erst ein Bild auswählen (antippen).')),
      );
      return;
    }
    setState(() => _bgBusy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final out = await compute(cutoutFinish, bytes);
      if (!mounted) return;
      final url = 'data:image/png;base64,${base64Encode(out)}';
      setState(() {
        _setImageById(sel, url);
        _imgOrig[sel] = url;
        _imgFeather[sel] = _kCutoutFeather;
        _imgInner[sel] = 0;
        _imgRim[sel] = _kCutoutRim;
      });
      unawaited(_applyImageFx(sel));
      messenger.showSnackBar(
        const SnackBar(content: Text('Hintergrund-Reste entfernt.')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Entfernen fehlgeschlagen: $e')),
      );
    } finally {
      if (mounted) setState(() => _bgBusy = false);
    }
  }

  Future<void> _removeBgSelected() async {
    if (_bgBusy) return;
    final src = _selectedImageDataUrl();
    if (src == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Erst ein Bild auswählen (antippen).')),
      );
      return;
    }
    final bytes = TeamLogo.decode(src);
    if (bytes == null) return;
    setState(() => _bgBusy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final out = await compute(removeUniformBackground, bytes);
      if (!mounted) return;
      setState(
        () => _setSelectedImageDataUrl(
          'data:image/png;base64,${base64Encode(out)}',
        ),
      );
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Einfarbiger Hintergrund entfernt. Reste? Noch mal probieren oder '
            'eigenes transparentes PNG nutzen.',
          ),
          duration: Duration(seconds: 4),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Hintergrund-Entfernen fehlgeschlagen: $e')),
      );
    } finally {
      if (mounted) setState(() => _bgBusy = false);
    }
  }

  /// Übersetzt die (oft sehr langen) Gemini-/Function-Fehler in eine kurze,
  /// verständliche Meldung für den Trainer.
  /// Vorübergehender Fehler (Zeitlimit, Überlast, Verbindung kurz weg) → ein
  /// automatischer zweiter Versuch lohnt sich.
  bool _isTransientAiError(Object e) {
    final low = e.toString().toLowerCase();
    return const [
      'timeout',
      'timed out',
      '502',
      '503',
      '504',
      '546',
      'wall clock',
      'worker_limit',
      'socketexception',
      'clientexception',
      'connection',
      'kein bild von der ki',
      'overloaded',
      'unavailable',
    ].any(low.contains);
  }

  /// Kurzer, einzeiliger Auszug einer Fehlermeldung (für Diagnose).
  /// Dialog für den KI-Wunsch (Freitext + Vorschlags-Chips). Die KI gestaltet
  /// NUR den Hintergrund – Logos, Namen, Sponsoren & Score bleiben unverändert
  /// (die App legt sie scharf darüber). Gibt Wunsch + Modus ('background') zurück.
  Future<({String prompt, String mode})?> _askAiWish() async {
    final ctrl = TextEditingController();
    const ideas = <String>[
      'Heller & kräftiger',
      'Dramatischer Look',
      'Konfetti & Feier',
      'Stadion-Stimmung',
      'Mehr Vereinsfarben',
    ];
    return showDialog<({String prompt, String mode})>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: const Text('Mit KI gestalten'),
        content: SizedBox(
          width: double.maxFinite,
          child: StatefulBuilder(
            builder: (ctx, setLocal) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Die KI gestaltet nur den Hintergrund. Deine Logos, Namen, '
                  'Sponsoren & der Score bleiben unverändert und scharf.',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                const Text('Wünsche zu Bild & Design:'),
                const SizedBox(height: 8),
                TextField(
                  controller: ctrl,
                  maxLines: 3,
                  autofocus: true,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    hintText: 'z.B. heller, dramatischer, Konfetti …',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final s in ideas)
                      ActionChip(
                        label: Text(s),
                        onPressed: () => setLocal(() {
                          ctrl.text = ctrl.text.trim().isEmpty
                              ? s
                              : '${ctrl.text.trim()}, $s';
                          ctrl.selection = TextSelection.collapsed(
                            offset: ctrl.text.length,
                          );
                        }),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, (
              prompt: ctrl.text.trim(),
              mode: 'background',
            )),
            child: const Text('Erstellen'),
          ),
        ],
      ),
    );
  }

  /// Baut die Grafik mit allen aktuellen Einstellungen. [backgroundOnly] rendert
  /// nur die Hintergrund-Ebene (für „Nur Hintergrund speichern").
  Widget _graphic({bool backgroundOnly = false}) => _StartelfGraphic(
    title: _title,
    logo: _effectiveLogo,
    starters: widget.starters,
    benchNames: widget.benchNames,
    mainSponsor: _mainSponsor,
    barSponsors: _barSponsors,
    bgImage: _settings.bgImage,
    gradTop: _hex(_settings.gradTop),
    gradBottom: _hex(_settings.gradBottom),
    gradShape: _settings.gradShape,
    bgPattern: _settings.bgPattern,
    overlayOpacity: _settings.overlayOpacity / 100,
    matchDate: widget.matchDate,
    isHome: widget.isHome,
    opponentName: widget.opponentName,
    opponentLogo: _settings.showOpponentLogo ? widget.opponentLogo : null,
    compact: !_story,
    result: widget.result,
    announcement: widget.announcement,
    photoBg: _photoBg,
    bandPhotos: _bandPhotos,
    showPhotos: _settings.showPhotos,
    photoController: _photoCtrl,
    designMode: false,
    accent: _settings.accent == null ? null : _hex(_settings.accent!),
    bgOpacity: _settings.bgOpacity / 100,
    bgBlend: _blendModeOf(_settings.bgBlend),
    logoCircle: _settings.logoShape == 'circle',
    backgroundOnly: backgroundOnly,
    anim: _animT == null ? null : (_previewAnim ?? _anim),
    animBase: _format == 'f' ? null : _anim,
    animT: _animT,
    hideBackground: _hideBg,
    showScorers: _settings.showScorers,
    infoPos: Offset(_settings.infoX, _settings.infoY),
    onInfoMove: (p) => setState(
      () => _settings = _settings.copyWith(infoX: p.dx, infoY: p.dy),
    ),
    onInfoMoveEnd: () =>
        context.read<AppState>().saveGraphicSettings(_settings),
    posterStyle: false,
    posterHeadline: _posterHeadline,
    posterMain: _posterMain,
    posterBadge: _posterBadge,
    posterLogoDisc: _posterLogoDisc,
    posterShadow: _posterShadow,
    posterBlend: _posterBlend && !_isFupa,
    fupaPlayer: _isFupa,
    playerGlow: _grade.glow / 100,
    playerMatch: _grade.match / 100,
    playerShade: _grade.shade / 100,
    playerWarm: _grade.warm / 100,
    playerLightDir: _grade.lightDir * math.pi / 180,
    playerLight: _playerLight,
    posterShadowStrength: _posterShadowStrength,
    posterShadowAngle: _posterShadowAngle,
    posterOrder: _posterOrder,
    posterOverlays: {for (final o in _posterOverlays) o.id: o.dataUrl},
    posterItemPos: _posterPos,
    posterItemScale: _posterScale,
    posterItemRot: _posterRot,
    posterSelected: _animT == null ? _posterSel : null,
    posterCentered: _posCentered,
    onPosterAnchor: (id, rel) {
      if (!mounted || _posCentered.contains(id)) return;
      setState(() {
        _posterPos[id] = rel;
        _posCentered.add(id);
      });
      // Nur Umrechnung (sieht gleich aus) → kein eigener Rückgängig-Schritt.
      if (_histReady) _history.replaceCurrent(_histState());
    },
    onPosterItemMove: (id, p) => setState(() => _posterPos[id] = p),
    // Ziel der Geste wird beim Start festgelegt (null = nichts getroffen/gewählt
    // → Geste ignorieren).
    onPosterGestureStart: (id) {
      _gTarget = id;
      if (id == null) return;
      _gScale0 = _posterScale[id] ?? 1.0;
      _gRot0 = _posterRot[id] ?? 0.0;
      _snapStart(id);
    },
    onPosterGestureUpdate: (_, d, w, h) {
      final id = _gTarget;
      if (id == null) return;
      setState(() {
        // Ein Finger = verschieben (rastet an Hilfslinien ein); zwei Finger =
        // zusätzlich skalieren + drehen.
        final mv = _snapMove(d.focalPointDelta, snap: d.pointerCount < 2);
        if (id.startsWith('std_')) {
          // Festes Teil: Verschiebung in logischen px (1:1 mit dem Finger).
          _stdOff[id] = _gOff0 + mv;
        } else {
          final p0 = _gPos0 ?? const Offset(0.5, 0.5);
          _posterPos[id] = Offset(p0.dx + mv.dx / w, p0.dy + mv.dy / h);
        }
        _posterScale[id] = (_gScale0 * d.scale).clamp(0.2, 6.0).toDouble();
        _posterRot[id] = _gRot0 + d.rotation;
      });
    },
    onPosterGestureEnd: _onGestureEnd,
    onPosterWheel: (id, dy) => _scalePoster(id, dy < 0 ? 1.08 : 1 / 1.08),
    stdOffset: _stdOff,
    stdHidden: _stdHidden,
    stdCtx: _stdCtx,
    stdNatCtx: _stdNatCtx,
    boxSize: _boxSize,
    onBoxResizeStart: (id, measured) {
      _rzStart = _boxSize[id] ?? measured;
      _rzAcc = Offset.zero;
    },
    onBoxResizeUpdate: (id, delta, w, h) {
      final s0 = _rzStart;
      if (s0 == null) return;
      final rot = _posterRot[id] ?? 0.0;
      final sc = _posterScale[id] ?? 1.0;
      final c = math.cos(rot), sn = math.sin(rot);
      // Finger-Delta in Kasten-Achsen (Drehung zurück, ÷ Skalierung).
      final lx = (delta.dx * c + delta.dy * sn) / sc;
      final ly = (-delta.dx * sn + delta.dy * c) / sc;
      Size sizeFor(Offset a) =>
          Size(math.max(60, s0.width + a.dx), math.max(40, s0.height + a.dy));
      final prev = sizeFor(_rzAcc);
      _rzAcc += Offset(w ? lx : 0, h ? ly : 0);
      final next = sizeFor(_rzAcc);
      // Kästen wachsen um ihre Mitte → Mitte um die halbe Änderung nachführen,
      // damit die gegenüberliegende Kante stehen bleibt (Griff unterm Finger).
      final hw = (next.width - prev.width) * sc / 2;
      final hh = (next.height - prev.height) * sc / 2;
      setState(() {
        _boxSize[id] = next;
        _stdOff[id] =
            (_stdOff[id] ?? Offset.zero) +
            Offset(hw * c - hh * sn, hw * sn + hh * c);
      });
    },
    resultLayout: _resultLayout,
    ftPhoto: _ftPhotoF[_designKey],
    ftController: _ftCtrl,
    onFtPhotoChanged: () =>
        setState(() => _ftMatrixF[_designKey] = _ftCtrl.value.storage.toList()),
    ftSplit: _ftSplit,
    editing: _editable && _aiPick == null && _animT == null,
    infoOverride: widget.designer?.infoLine,
    onFtSplitDrag: (dFrac) => setState(
      () => _ftSplitF[_designKey] = (_ftSplit + dFrac).clamp(0.2, 0.85),
    ),
    onPosterLongPress: _showElementProperties,
    onPosterRotateTo: (id, a) => setState(() => _posterRot[id] = a),
    onBackgroundLongPress: () => _toggleTool('add'),
    onBackgroundTap: () => _selectElement(null),
    canvasKey: _posterCanvasKey,
    onPosterSelect: _selectElement,
    onPosterTap: _onPosterTap,
    posterFont: _posterFont,
    showMainSponsor: _showMainSponsor,
    showOtherSponsors: _showOtherSponsors,
    mainSponsorMode: _mainSponsorMode,
    posterTextShadow: Map.of(_textShadow),
    posterTextAlign: Map.of(_textAlign),
    posterTexts: {
      for (final id in _textIds)
        id: (
          text: _animStr(id, _textContent[id] ?? ''),
          font: _textFont[id] ?? 'standard',
          color: _textColor[id] ?? 'white',
        ),
      // Datum („info") als editierbarer Override, falls gesetzt.
      // Datum-Override auch, wenn NUR Schrift/Farbe geändert wurde (nicht nur
      // bei geändertem Text) – sonst greift die Farbwahl beim Datum nicht.
      if (_textContent.containsKey('info') ||
          _textFont.containsKey('info') ||
          _textColor.containsKey('info'))
        'info': (
          text: _textContent['info'] ?? '',
          font: _textFont['info'] ?? 'standard',
          color: _textColor['info'] ?? 'accent',
        ),
      // Titel/Überschrift/Datum (feste Teile) mit eigener Schrift/Farbe.
      for (final id in _kStyledFixedTextIds)
        if (_textContent.containsKey(id) ||
            _textFont.containsKey(id) ||
            _textColor.containsKey(id))
          id: (
            text: _textContent[id] ?? '',
            // Datum ohne eigene Schrift: Standardschrift (nicht Poster-Font).
            font:
                _textFont[id] ?? (id == 'std_info' ? 'standard' : _posterFont),
            color: _textColor[id] ?? 'white',
          ),
      // „Präsentiert von"-Texte (Poster + feste Teile) mit eigenem Inhalt/Stil.
      for (final id in _kSponsorTextIds)
        if (_textContent.containsKey(id) ||
            _textFont.containsKey(id) ||
            _textColor.containsKey(id))
          id: (
            text: _textContent[id] ?? '',
            font: _textFont[id] ?? 'standard',
            color: _textColor[id] ?? 'white',
          ),
    },
  );

  /// Standardtext der „Präsentiert von"-Objekte.
  String _sponsorTextDefault(String id) =>
      id == 'sponsortext' ? 'Präsentiert von' : 'PRÄSENTIERT VON';

  /// Aktuelle Textfarbe eines Elements als Hex (Schlüssel aufgelöst).
  String _textColorHex(String id) {
    final c = _textColor[id] ?? (id == 'info' ? 'accent' : 'white');
    if (c == 'white') return '#FFFFFF';
    if (c == 'black') return '#000000';
    if (c == 'accent') return _settings.accent ?? '#FFFFFF';
    return c;
  }

  /// Langdruck auf einen Text → kompaktes Menü: oben der Text, darunter die
  /// Reiter „Stil" (Schrift-Kacheln, Farbkreise, Schatten) und „Lage" (Größe,
  /// Drehung, Ebene). Löschen als Symbol oben rechts; die Grafik bleibt
  /// ungedimmt sichtbar.
  Widget Function(BuildContext, StateSetter) _textPanel(
    String id, {
    required bool isSponsorText,
    required bool isStd,
    required String sectionKey,
  }) {
    final isHeadline =
        id == 'headline' || id == 'std_title' || id == 'std_ft_title';
    return (ctx, setSheet) {
      void apply(VoidCallback fn) {
        setState(fn);
        setSheet(() {});
      }

      final scheme = Theme.of(ctx).colorScheme;
      final hint = Theme.of(ctx).hintColor;

      Widget section(String label, Widget child) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: hint,
              ),
            ),
            const SizedBox(height: 6),
            child,
          ],
        ),
      );

      Widget hScroll(List<Widget> kids) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final k in kids)
              Padding(padding: const EdgeInsets.only(right: 8), child: k),
          ],
        ),
      );

      Widget slider(
        String label,
        double value,
        double min,
        double max,
        ValueChanged<double> onCh,
        String text,
      ) => Row(
        children: [
          SizedBox(
            width: 64,
            child: Text(label, style: const TextStyle(fontSize: 13)),
          ),
          Expanded(
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: onCh,
            ),
          ),
          SizedBox(
            width: 46,
            child: Text(
              text,
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      );

      // ---------------------------------------------------- Stil
      final curFont = _textFont[id] ?? (isHeadline ? _posterFont : 'standard');
      final fonts = hScroll([
        for (final e in _kPosterFonts.entries)
          ChoiceChip(
            showCheckmark: false,
            label: Text(
              e.value,
              style: posterFontStyle(
                e.key,
                const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
            ),
            selected: curFont == e.key,
            onSelected: (_) => apply(() => _textFont[id] = e.key),
          ),
      ]);

      final curColor = _textColor[id] ?? (id == 'info' ? 'accent' : 'white');
      Widget circle(Color c, bool sel, VoidCallback onTap, String tip) =>
          Tooltip(
            message: tip,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: c,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: sel ? scheme.primary : Colors.black26,
                    width: sel ? 3 : 1,
                  ),
                ),
                child: sel
                    ? Icon(
                        Icons.check,
                        size: 18,
                        color: c.computeLuminance() > 0.5
                            ? Colors.black
                            : Colors.white,
                      )
                    : null,
              ),
            ),
          );
      final isCustom = !_kTextColors.containsKey(curColor);
      final colors = hScroll([
        for (final e in _kTextColors.entries)
          circle(
            switch (e.key) {
              'white' => Colors.white,
              'black' => Colors.black,
              _ => _hex(_settings.accent ?? '#FFFFFF'),
            },
            curColor == e.key,
            () => apply(() => _textColor[id] = e.key),
            e.value,
          ),
        if (isCustom) circle(_hex(curColor), true, () {}, 'Eigene Farbe'),
        Tooltip(
          message: 'Farbe wählen',
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () async {
              final hex = await _pickColor(_textColorHex(id));
              if (hex != null) apply(() => _textColor[id] = hex);
            },
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const SweepGradient(
                  colors: [
                    Colors.red,
                    Colors.yellow,
                    Colors.green,
                    Colors.cyan,
                    Colors.blue,
                    Colors.purple,
                    Colors.red,
                  ],
                ),
                border: Border.all(color: Colors.black26),
              ),
              child: const Icon(Icons.add, color: Colors.white, size: 20),
            ),
          ),
        ),
      ]);

      const shadowKinds = {
        'none': 'Aus',
        'soft': 'Weich',
        'strong': 'Stark',
        'outline': 'Kontur',
        'glow': 'Leuchten',
      };
      final defAlign = id == 'std_title' ? 'left' : 'center';
      final curAlign = _textAlign[id] ?? defAlign;
      final alignRow = SegmentedButton<String>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(
            value: 'left',
            icon: Icon(Icons.format_align_left),
            tooltip: 'Linksbündig',
          ),
          ButtonSegment(
            value: 'center',
            icon: Icon(Icons.format_align_center),
            tooltip: 'Zentriert',
          ),
          ButtonSegment(
            value: 'right',
            icon: Icon(Icons.format_align_right),
            tooltip: 'Rechtsbündig',
          ),
        ],
        selected: {curAlign},
        onSelectionChanged: (v) => apply(() {
          if (v.first == defAlign) {
            _textAlign.remove(id);
          } else {
            _textAlign[id] = v.first;
          }
        }),
      );
      final curShadow = _textShadow[id] ?? 'none';
      final shadows = hScroll([
        for (final e in shadowKinds.entries)
          ChoiceChip(
            label: Text(e.value),
            selected: curShadow == e.key,
            onSelected: (_) => apply(() {
              if (e.key == 'none') {
                _textShadow.remove(id);
              } else {
                _textShadow[id] = e.key;
              }
            }),
          ),
      ]);

      // ---------------------------------------------------- Lage
      final rotDeg = ((_posterRot[id] ?? 0) * 180 / math.pi).clamp(
        -180.0,
        180.0,
      );
      final lage = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          slider(
            'Größe',
            _posterScale[id] ?? 1.0,
            0.4,
            3.0,
            (v) => apply(() => _posterScale[id] = v),
            '${((_posterScale[id] ?? 1.0) * 100).round()}%',
          ),
          slider('Drehung', rotDeg, -180, 180, (v) {
            // Magnetisch bei 0° und ±90°/±180° einrasten.
            var d = v;
            for (final snap in const [-180.0, -90.0, 0.0, 90.0, 180.0]) {
              if ((v - snap).abs() <= 6) {
                d = snap;
                break;
              }
            }
            apply(() => _posterRot[id] = d * math.pi / 180);
          }, '${rotDeg.round()}°'),
          const SizedBox(height: 4),
          if (isStd)
            OutlinedButton.icon(
              icon: const Icon(Icons.undo, size: 18),
              label: const Text('Position, Größe & Drehung zurück'),
              onPressed: () => apply(() {
                _stdOff.remove(id);
                _posterScale.remove(id);
                _posterRot.remove(id);
                _boxSize.remove(id);
              }),
            )
          else
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.flip_to_back, size: 18),
                    label: const Text('Nach hinten'),
                    onPressed: () {
                      _reorderPoster(id, -1);
                      setSheet(() {});
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.flip_to_front, size: 18),
                    label: const Text('Nach vorne'),
                    onPressed: () {
                      _reorderPoster(id, 1);
                      setSheet(() {});
                    },
                  ),
                ),
              ],
            ),
        ],
      );

      // Automatik-/Standard-Text wiederherstellen (Datum, „Präsentiert von").
      final VoidCallback? restore =
          id == 'info' || isSponsorText || id == 'std_info'
          ? () => apply(() {
              _textContent.remove(id);
              _textFont.remove(id);
              _textColor.remove(id);
              _textShadow.remove(id);
              _textAlign.remove(id);
              _editorSeq++; // Feld mit Standard-Text neu aufbauen
            })
          : isHeadline
          ? () => apply(() {
              _annHeadMode = 'spieltag';
              _annHeadText = '';
              _editorSeq++;
            })
          : null;
      InputDecoration fieldDeco(String? label, {bool withRestore = true}) =>
          InputDecoration(
            isDense: true,
            filled: true,
            labelText: label,
            hintText: label == null ? 'Text' : null,
            helperText: 'Zeilenumbruch nur mit Enter',
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            suffixIcon: restore == null || !withRestore
                ? null
                : IconButton(
                    tooltip: id == 'info' || id == 'std_info'
                        ? 'Automatisches Datum'
                        : 'Standardtext',
                    icon: const Icon(Icons.restore),
                    onPressed: restore,
                  ),
          );
      final Widget headlineField = TextFormField(
        key: ValueKey('sheethead_${id}_$_editorSeq'),
        initialValue: _annHeadMode == 'custom' ? _annHeadText : _posterHeadline,
        minLines: 1,
        maxLines: 3,
        keyboardType: TextInputType.multiline,
        textCapitalization: TextCapitalization.characters,
        style: const TextStyle(fontSize: 16),
        decoration: fieldDeco('Überschrift'),
        onChanged: (v) => apply(() {
          _annHeadMode = 'custom';
          _annHeadText = v;
        }),
      );

      // Überschrift: Vorgabe (z. B. SPIELTAG), Heim/Auswärts oder eigener Text.
      void setHead(String mode) => apply(() {
        _annHeadMode = mode;
        _editorSeq++; // Feld mit neuem Text aufbauen
      });
      final Widget headModes = _defaultHeadline.trim().isEmpty
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  ChoiceChip(
                    label: Text(_defaultHeadline),
                    selected: _annHeadMode == 'spieltag',
                    onSelected: (_) => setHead('spieltag'),
                  ),
                  if (widget.designer == null)
                    ChoiceChip(
                      label: const Text('Heim/Auswärts'),
                      selected: _annHeadMode == 'auto',
                      onSelected: (_) => setHead('auto'),
                    ),
                  ChoiceChip(
                    label: const Text('Eigener Text'),
                    selected: _annHeadMode == 'custom',
                    onSelected: (_) => setHead('custom'),
                  ),
                ],
              ),
            );
      final body = <Widget>[
        if (sectionKey == 'text') ...[
          if (id == 'std_title') ...[
            TextFormField(
              initialValue: _title,
              textCapitalization: TextCapitalization.characters,
              style: const TextStyle(fontSize: 16),
              decoration: fieldDeco(
                'Vereinsname (gilt für alle Grafiken)',
                withRestore: false,
              ).copyWith(helperText: null),
              onChanged: (v) {
                _titleDirty = true;
                apply(
                  () => _settings = v.trim().isEmpty
                      ? _settings.copyWith(clearTitle: true)
                      : _settings.copyWith(title: v.trim()),
                );
              },
            ),
            const SizedBox(height: 8),
            headModes,
            headlineField,
          ] else if (isHeadline) ...[
            headModes,
            headlineField,
          ] else
            TextFormField(
              key: ValueKey('sheettxt_${id}_$_editorSeq'),
              initialValue: id == 'info'
                  ? (_textContent['info'] ?? _autoInfoLine)
                  : id == 'std_info'
                  ? (_textContent['std_info'] ?? _autoStdInfoLine)
                  : isSponsorText
                  ? (_textContent[id] ?? _sponsorTextDefault(id))
                  : (_textContent[id] ?? ''),
              minLines: 1,
              maxLines: 4,
              keyboardType: TextInputType.multiline,
              style: const TextStyle(fontSize: 16),
              decoration: fieldDeco(null),
              onChanged: (v) => apply(() => _textContent[id] = v),
            ),
        ] else if (sectionKey == 'style') ...[
          section('Ausrichtung', alignRow),
          section('Schrift', fonts),
          section('Farbe', colors),
          section('Schatten', shadows),
        ] else if (sectionKey == 'anim')
          _animSection(id, apply, open: true)
        else
          lage,
      ];
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        children: body,
      );
    };
  }

  bool _isTextEl(String id) =>
      id.startsWith('text_') ||
      id == 'info' ||
      _kSponsorTextIds.contains(id) ||
      _kStyledFixedTextIds.contains(id);

  bool _isImageEl(String id) => id == 'player' || id.startsWith('overlay_');

  /// Abschnitte der Kontextleiste für ein Element (Schlüssel, Name, Symbol).
  List<(String, String, IconData)> _elementSections(String id) {
    final isText = _isTextEl(id);
    return [
      if (isText) ('text', 'Text', Icons.edit_outlined),
      if (isText) ('style', 'Stil', Icons.format_paint_outlined),
      if (_isImageEl(id)) ('fx', 'Bild', Icons.auto_fix_high),
      ('pos', 'Position', Icons.open_with),
      if (_format != 'f') ('anim', 'Bewegung', Icons.animation),
    ];
  }

  /// Name zum Löschen/Ausblenden eines Elements.
  String _removeLabel(String id) => id == 'player'
      ? 'Entfernen'
      : (id.startsWith('overlay_') || id.startsWith('text_'))
      ? 'Löschen'
      : 'Ausblenden';

  /// Element wählen und seinen Abschnitt im Panel öffnen ([section] null =
  /// erster Abschnitt). Auch per Langdruck.
  void _showElementProperties(String id, [String? section]) {
    final secs = _elementSections(id);
    final sec = secs.firstWhere(
      (e) => e.$1 == section,
      orElse: () => secs.first,
    );
    final isStd = id.startsWith('std_');
    setState(() => _posterSel = id);
    _openPanel(
      'el:$id:${sec.$1}',
      '${_posterItemLabel(id)} · ${sec.$2}',
      _isTextEl(id)
          ? _textPanel(
              id,
              isSponsorText: _kSponsorTextIds.contains(id),
              isStd: isStd,
              sectionKey: sec.$1,
            )
          : _elementPanel(id, sec.$1),
      onClose: _saveTitleIfDirty,
    );
  }

  /// Vereinsname im Text-Panel geändert → teamweit speichern.
  bool _titleDirty = false;
  void _saveTitleIfDirty() {
    if (!_titleDirty || !mounted) return;
    _titleDirty = false;
    context.read<AppState>().saveGraphicSettings(_settings);
  }

  /// Element-Panel (Bilder/Logos/feste Teile): Lage, Effekte, Animation.
  Widget Function(BuildContext, StateSetter) _elementPanel(
    String id,
    String sectionKey,
  ) {
    final isImage = _isImageEl(id);
    // Feste Teile (Ergebnis/Startelf) liegen im Layout – keine Ebenen-Reihenfolge.
    final isStd = id.startsWith('std_');
    return (ctx, setSheet) {
      void apply(VoidCallback fn) {
        setState(fn);
        setSheet(() {});
      }

      Widget labeledSlider(
        String label,
        double value,
        double min,
        double max,
        ValueChanged<double> onCh, {
        ValueChanged<double>? onEnd,
        String Function(double)? fmt,
      }) {
        final v = value.clamp(min, max);
        return Row(
          children: [
            SizedBox(
              width: 92,
              child: Text(label, style: const TextStyle(fontSize: 13)),
            ),
            Expanded(
              child: Slider(
                value: v,
                min: min,
                max: max,
                onChanged: onCh,
                onChangeEnd: onEnd,
              ),
            ),
            SizedBox(
              width: 46,
              child: Text(
                fmt != null ? fmt(v) : v.round().toString(),
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        );
      }

      final rotDeg = ((_posterRot[id] ?? 0) * 180 / math.pi).clamp(
        -180.0,
        180.0,
      );
      final body = <Widget>[
        if (sectionKey == 'anim')
          _animSection(id, apply, open: true)
        else if (sectionKey == 'fx') ...[
          if (isImage) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.auto_fix_high, size: 18),
                    label: const Text('Freistellen (KI)'),
                    onPressed: _aiBusy
                        ? null
                        : () {
                            _cutoutSelected();
                          },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.format_color_reset, size: 18),
                    label: const Text('Hintergrund weg'),
                    onPressed: _bgBusy
                        ? null
                        : () {
                            _removeBgSelected();
                          },
                  ),
                ),
              ],
            ),
            // Nach KI-Freistellen: übrig gebliebenes Rosa entfernen.
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.cleaning_services, size: 18),
                label: const Text('Reste entfernen (Rosa/Hintergrund)'),
                onPressed: _bgBusy
                    ? null
                    : () {
                        _removePinkSelected();
                      },
              ),
            ),
            labeledSlider(
              'Weiche Kanten',
              _imgFeather[id] ?? 0,
              0,
              100,
              (v) => apply(() => _imgFeather[id] = v),
              onEnd: (_) => _applyImageFx(id),
            ),
            labeledSlider(
              'Innerer Schatten',
              _imgInner[id] ?? 0,
              0,
              100,
              (v) => apply(() => _imgInner[id] = v),
              onEnd: (_) => _applyImageFx(id),
            ),
            labeledSlider(
              'Rand verschmelzen',
              _imgRim[id] ?? 0,
              0,
              100,
              (v) => apply(() => _imgRim[id] = v),
              onEnd: (_) => _applyImageFx(id),
            ),
            if (id == 'player') ...[
              const Divider(height: 20),
              const Text(
                'An Hintergrund anpassen',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonalIcon(
                  icon: const Icon(Icons.wb_incandescent_outlined),
                  label: const Text('Automatisch anpassen'),
                  onPressed: () => apply(_autoFitPlayerLight),
                ),
              ),
              labeledSlider(
                'Licht angleichen',
                _grade.match,
                0,
                100,
                (v) => apply(() => _grade.match = v),
              ),
              labeledSlider(
                'Wärme',
                _grade.warm,
                0,
                100,
                (v) => apply(() => _grade.warm = v),
              ),
              labeledSlider(
                'Licht & Schatten',
                _grade.shade,
                0,
                100,
                (v) => apply(() => _grade.shade = v),
              ),
              labeledSlider(
                'Lichtrichtung',
                _grade.lightDir,
                -180,
                180,
                (v) => apply(() {
                  _grade.lightDir = v;
                  // Schlagschatten fällt auf die Gegenseite.
                  _posterShadowAngle = (v + 180) % 360;
                }),
                fmt: (v) => _lightDirLabel(v),
              ),
              labeledSlider(
                'Licht hinter Spieler',
                _grade.glow,
                0,
                100,
                (v) => apply(() => _grade.glow = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('Schatten auf den Hintergrund'),
                value: _posterShadow,
                onChanged: (v) => apply(() => _posterShadow = v),
              ),
              if (_posterShadow)
                labeledSlider(
                  'Schattenstärke',
                  _posterShadowStrength,
                  0,
                  100,
                  (v) => apply(() => _posterShadowStrength = v),
                ),
            ],
          ],
        ] else ...[
          labeledSlider(
            'Größe',
            _posterScale[id] ?? 1.0,
            0.4,
            3.0,
            (v) => apply(() => _posterScale[id] = v),
            fmt: (v) => '${(v * 100).round()}%',
          ),
          labeledSlider('Drehung', rotDeg, -180, 180, (v) {
            // Magnetisch bei 0° (Mitte) und ±90°/±180° einrasten,
            // damit sich das Objekt leicht gerade ausrichten lässt.
            var d = v;
            for (final s in const [-180.0, -90.0, 0.0, 90.0, 180.0]) {
              if ((v - s).abs() <= 6) {
                d = s;
                break;
              }
            }
            apply(() => _posterRot[id] = d * math.pi / 180);
          }, fmt: (v) => '${v.round()}°'),
          if (isStd)
            OutlinedButton.icon(
              icon: const Icon(Icons.undo, size: 18),
              label: const Text('Position, Größe & Drehung zurück'),
              onPressed: () => apply(() {
                _stdOff.remove(id);
                _posterScale.remove(id);
                _posterRot.remove(id);
                _boxSize.remove(id); // gezogene Kastengröße
              }),
            ),
          if (!isStd)
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.flip_to_back, size: 18),
                    label: const Text('Nach hinten'),
                    onPressed: () {
                      _reorderPoster(id, -1);
                      setSheet(() {});
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.flip_to_front, size: 18),
                    label: const Text('Nach vorne'),
                    onPressed: () {
                      _reorderPoster(id, 1);
                      setSheet(() {});
                    },
                  ),
                ),
              ],
            ),
        ],
      ];
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        children: body,
      );
    };
  }

  /// Anzeigename eines Poster-Elements (für den Größe-Regler).
  String _posterItemLabel(String id) {
    switch (id) {
      case 'player':
        return 'Spieler';
      case 'sponsor':
        return 'Sponsor-Logo';
      case 'sponsortext':
      case 'std_sponsor_text':
      case 'std_ft_sponsor_text':
        return '„Präsentiert von"';
      case 'sponsorbar':
        return 'Sponsoren';
      case 'logos':
        return 'Logos';
      case 'headline':
        return 'Titel';
      case 'info':
        return 'Datum';
      case 'std_logo':
        return 'Vereinslogo';
      case 'std_title':
        return 'Überschrift';
      case 'std_sponsor':
        return 'Sponsor-Logo';
      case 'std_info':
        return 'Datum & Uhrzeit';
      case 'std_vs':
        return 'Gegner';
      case 'std_score':
        return 'Ergebnis';
      case 'std_scorers':
        return 'Torschützen';
      case 'std_lineup':
        return 'Aufstellung';
      case 'std_sponsorbar':
      case 'std_ft_sponsorbar':
        return 'Sponsoren';
      case 'std_ft_title':
        return 'Überschrift';
      case 'std_ft_banner':
        return 'Ergebnis-Balken';
      case 'std_ft_scorers':
        return 'Torschützen';
      case 'std_ft_sponsor':
        return 'Sponsor-Logo';
      default:
        if (id.startsWith('overlay_')) return 'Bild';
        if (id.startsWith('text_')) return 'Text';
        return id;
    }
  }

  /// Verschiebt ein Element in der Ebenen-Reihenfolge um eine Position
  /// ([dir] +1 = nach vorne, -1 = nach hinten).
  void _reorderPoster(String id, int dir) {
    final i = _posterOrder.indexOf(id);
    if (i < 0) return;
    final j = i + dir;
    if (j < 0 || j >= _posterOrder.length) return;
    setState(() {
      final tmp = _posterOrder[i];
      _posterOrder[i] = _posterOrder[j];
      _posterOrder[j] = tmp;
    });
  }

  /// Eigenes Bild/Grafik als Overlay hinzufügen (Galerie/Kamera, Transparenz
  /// bleibt erhalten). Neues Overlay kommt nach vorne und wird ausgewählt.
  Future<void> _addPosterOverlay() async {
    final src0 = await _askPosterSource(allowKader: false);
    if (src0 == null || src0 == 'remove' || !mounted) return;
    final src = await _resolveGoogleSource(src0);
    if (src == null || !mounted) return;
    final url = await _pickImage(
      asBackground: true,
      source: src == 'camera' ? ImageSource.camera : ImageSource.gallery,
      edit: true,
      keepAlpha: true,
      maxSize: 1600,
    );
    if (url == null || !mounted) return;
    final id = 'overlay_${_posterOverlaySeq++}';
    setState(() {
      _posterOverlays.add((id: id, dataUrl: url)); // nur aktuelles Format
      _posterOrder.add(id);
      _posterPos[id] = const Offset(0.5, 0.5);
      _posCentered.add(id);
      _imgOrig[id] = url;
      _imgFeather[id] = 0;
      _imgInner[id] = 0;
      _imgRim[id] = 0;
      _posterSel = id;
    });
  }

  /// Eigenes Textfeld hinzufügen (aktuelles Format). Kommt nach vorne + gewählt.
  void _addPosterText() {
    final id = 'text_${_textSeq++}';
    setState(() {
      _textIds.add(id);
      _textContent[id] = 'TEXT';
      _textFont[id] = _posterFont;
      _textColor[id] = 'white';
      _posterOrder.add(id);
      _posterPos[id] = const Offset(0.5, 0.5);
      _posCentered.add(id);
      _posterSel = id;
    });
  }

  // ------------------------------------------- Story ↔ Post übernehmen
  /// Übernehmen zwischen Story und Post möglich (nicht im FuPa-Format).
  bool get _canCopyFormats => !_isFupa && (_format == 's' || _format == 'p');

  String get _otherFormat => _format == 's' ? 'p' : 's';

  static String _formatName(String k) => k == 's' ? 'Story' : 'Post';

  Size _canvasOf(String k) => k == 's'
      ? const Size(_storyW, _storyH)
      : (k == 'f' ? const Size(_fupaW, _fupaH) : const Size(_postW, _postH));

  /// Einpassen der Quell- in die Ziel-Leinwand („contain", mittig): Faktor
  /// für Größen und Umrechnung relativer Positionen.
  (double, Offset Function(Offset)) _fitMap(String src, String dst) {
    final s = _canvasOf(src), d = _canvasOf(dst);
    final f = math.min(d.width / s.width, d.height / s.height);
    final ox = (d.width - s.width * f) / 2;
    final oy = (d.height - s.height * f) / 2;
    return (
      f,
      (Offset rel) => Offset(
        (rel.dx * s.width * f + ox) / d.width,
        (rel.dy * s.height * f + oy) / d.height,
      ),
    );
  }

  /// Ziel-Format mit seinen Grundwerten anlegen, bevor etwas hineinkopiert
  /// wird (sonst fehlten Grundpositionen/Startelf-Vorgaben später).
  void _prepareFormat(String k) {
    _seedAnnouncementLayout(k);
    _posterOrderF.putIfAbsent(
      k,
      () => widget.isAnnouncement
          ? List<String>.from(_kPosterBaseOrder)
          : <String>[],
    );
    if (_kind == 'Startelf') {
      final off = _stdOffF.putIfAbsent(k, () => {});
      if (off.isEmpty) off.addAll(_kStartelfOffDefaults[k] ?? const {});
      final box = _boxSizeF.putIfAbsent(k, () => {});
      if (box.isEmpty) box.addAll(_kStartelfBoxDefaults[k] ?? const {});
    }
  }

  /// Bild-Daten (angezeigtes Bild, Original, Effekte) von [src] nach [dst].
  void _copyImageData(String id, String src, String dst) {
    if (id == 'player') {
      // Ohne Spielerfoto in der Quelle bleibt das Foto im Ziel.
      if (_posterMainF[src] == null) return;
      _posterMainF[dst] = _posterMainF[src];
    } else {
      final o = (_posterOverlaysF[src] ?? const []).where((o) => o.id == id);
      if (o.isNotEmpty) {
        final list = _posterOverlaysF.putIfAbsent(dst, () => []);
        final i = list.indexWhere((x) => x.id == id);
        if (i >= 0) {
          list[i] = o.first;
        } else {
          list.add(o.first);
        }
      }
    }
    final orig = _imgOrigF[src]?[id];
    if (orig != null) _imgOrigF.putIfAbsent(dst, () => {})[id] = orig;
    for (final m in [_imgFeatherF, _imgInnerF, _imgRimF]) {
      final v = m[src]?[id];
      if (v != null) m.putIfAbsent(dst, () => {})[id] = v;
    }
  }

  /// Text-Inhalt und -Stil von [src] nach [dst] (fehlende Werte = Standard).
  void _copyTextData(String id, String src, String dst) {
    for (final m in [
      _textContentF,
      _textFontF,
      _textColorF,
      _textShadowF,
      _textAlignF,
    ]) {
      final v = m[src]?[id];
      final t = m.putIfAbsent(dst, () => {});
      if (v == null) {
        t.remove(id);
      } else {
        t[id] = v;
      }
    }
    if (id.startsWith('text_')) {
      final ids = _textIdsF.putIfAbsent(dst, () => []);
      if (!ids.contains(id)) ids.add(id);
    }
  }

  /// Ist [id] im Format [k] vorhanden (sichtbar)?
  bool _hasElement(String id, String k) {
    if (id.startsWith('std_')) return !(_stdHiddenF[k]?.contains(id) ?? false);
    final inOrder = _posterOrderF[k]?.contains(id) ?? false;
    if (id == 'player') return inOrder && _posterMainF[k] != null;
    if (id.startsWith('text_')) {
      return inOrder && (_textIdsF[k]?.contains(id) ?? false);
    }
    if (id.startsWith('overlay_')) {
      return inOrder && (_posterOverlaysF[k]?.any((o) => o.id == id) ?? false);
    }
    return inOrder;
  }

  /// Element [id] von [src] nach [dst] übernehmen: Inhalt + Stil immer;
  /// Position/Größe nur, wenn es im Ziel noch nicht vorhanden ist (dann ins
  /// Ziel eingepasst).
  void _copyElement(String id, String src, String dst) {
    _prepareFormat(dst);
    final existed = _hasElement(id, dst);
    if (id == 'player' || id.startsWith('overlay_')) {
      _copyImageData(id, src, dst);
    }
    // Texte (eigene, Grundtexte und feste Teile) tragen ihren Stil in den
    // Text-Maps – für Bild-Elemente sind diese leer.
    if (!id.startsWith('overlay_') && id != 'player') {
      _copyTextData(id, src, dst);
    }
    final ea = _animF[src]?.items[id];
    if (ea != null) {
      _animF.putIfAbsent(dst, () => GraphicAnim()).items[id] = ea.copy();
    }
    if (existed) return;
    final (f, map) = _fitMap(src, dst);
    if (id.startsWith('std_')) {
      _stdHiddenF[dst]?.remove(id);
      final off = _stdOffF[src]?[id];
      if (off != null) _stdOffF.putIfAbsent(dst, () => {})[id] = off * f;
    } else {
      final order = _posterOrderF[dst]!;
      if (!order.contains(id)) order.add(id);
      final pos =
          _posterPosF[src]?[id] ??
          _kCenteredItemDefaults[id] ??
          const Offset(0.5, 0.5);
      _posterPosF.putIfAbsent(dst, () => {})[id] = map(pos);
      final centered = _posCenteredF.putIfAbsent(dst, () => <String>{});
      if (_posCenteredF[src]?.contains(id) ?? false) {
        centered.add(id);
      } else {
        centered.remove(id);
      }
    }
    _posterScaleF.putIfAbsent(dst, () => {})[id] =
        ((_posterScaleF[src]?[id] ?? 1.0) * f).clamp(0.2, 6.0).toDouble();
    final rot = _posterRotF[src]?[id];
    if (rot != null) _posterRotF.putIfAbsent(dst, () => {})[id] = rot;
    final box = _boxSizeF[src]?[id];
    if (box != null) _boxSizeF.putIfAbsent(dst, () => {})[id] = box * f;
  }

  /// Ausgewähltes Element ins andere Format (Story ↔ Post) übernehmen.
  void _copyElementToOther(String id) {
    final src = _format, dst = _otherFormat;
    setState(() => _copyElement(id, src, dst));
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text('In ${_formatName(dst)} übernommen'),
        action: SnackBarAction(
          label: 'Ansehen',
          onPressed: () {
            if (!mounted) return;
            setState(() {
              _format = dst;
              _posterSel = id;
            });
            _syncFtCtrl();
          },
        ),
      ),
    );
  }

  /// Ganzes Design aus dem anderen Format ins aktuelle übernehmen: Inhalte und
  /// Stil ersetzen, vorhandene Positionen bleiben, fehlende Elemente kommen
  /// eingepasst dazu. Ausgeblendetes wird auch hier ausgeblendet.
  Future<void> _copyDesignFromOther() async {
    final src = _otherFormat, dst = _format;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Design aus ${_formatName(src)} übernehmen?'),
        content: Text(
          'Texte, Bilder und Stil aus ${_formatName(src)} werden in '
          '${_formatName(dst)} übernommen. Was es in ${_formatName(dst)} schon '
          'gibt, behält seine Position; neue Elemente werden passend '
          'eingesetzt.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Übernehmen'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _prepareFormat(src);
      _prepareFormat(dst);
      final srcOrder = List<String>.from(_posterOrderF[src] ?? const []);
      // Elemente der Quelle (Ebenen + feste Teile) übernehmen.
      for (final id in srcOrder) {
        _copyElement(id, src, dst);
      }
      if (!widget.isAnnouncement) {
        for (final id in _kStdOrder) {
          if (!(_stdHiddenF[src]?.contains(id) ?? false)) {
            _copyElement(id, src, dst);
          }
        }
        _stdHiddenF[dst] = {...?_stdHiddenF[src]};
      }
      // Ebenen-Reihenfolge wie in der Quelle; nur im Ziel vorhandene eigene
      // Elemente bleiben oben drauf. In der Quelle ausgeblendete
      // Grundelemente werden auch im Ziel ausgeblendet.
      final dstOrder = _posterOrderF[dst]!;
      final extra = [
        for (final id in dstOrder)
          if (!srcOrder.contains(id) && !_kPosterBaseOrder.contains(id)) id,
      ];
      _posterOrderF[dst] = [...srcOrder, ...extra];
      // Formatweite Einstellungen.
      final an = _animF[src];
      if (an != null) _animF[dst] = an.copy();
      final look = _lookF[src];
      if (look == null) {
        _lookF.remove(dst);
      } else {
        final l = _AiLook.fromJson(look.toJson());
        if (l != null) _lookF[dst] = l;
      }
      final grade = _gradeF[src];
      if (grade != null) _gradeF[dst] = _Grade.fromJson(grade.toJson());
      if (_aiBgSelF.containsKey(src)) _aiBgSelF[dst] = _aiBgSelF[src];
      final ft = _ftPhotoF[src];
      if (ft != null) _ftPhotoF[dst] = ft;
      final split = _ftSplitF[src];
      if (split != null) _ftSplitF[dst] = split;
      _posterSel = null;
    });
    _syncFtCtrl();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Design aus ${_formatName(src)} übernommen')),
    );
  }

  /// Knopf im Element-Sheet: Element ins andere Format übernehmen.
  // ------------------------------------------------------------ Animation
  /// Animation je Format (Story/Post): Vorlage, Länge, Effekte je Element.
  final Map<String, GraphicAnim> _animF = {};
  GraphicAnim get _anim => _animF.putIfAbsent(_designKey, () => GraphicAnim());

  /// KI-Video als bewegter Hintergrund je Format (lokaler Pfad, je Gerät).
  final Map<String, String> _aiVideoF = {};
  String? get _aiVideoPath {
    final p = _aiVideoF[_designKey];
    return p != null && File(p).existsSync() ? p : null;
  }

  double? _animT; // Zeitpunkt beim Abspielen/Export (null = Standbild)
  Ticker? _animTicker;
  bool _hideBg = false; // Video-Export über KI-Video: Hintergrund weglassen
  bool _videoBusy = false;
  bool _videoCancel = false;
  String _videoStatus = '';
  String _aiAnimProvider = 'claude';

  bool get _animPlaying => _animTicker?.isActive ?? false;

  /// Nur ein Element animieren (Vorschau im Element-Panel); null = alle.
  GraphicAnim? _previewAnim;

  /// Animation einmal abspielen (Vorschau). [only] spielt nur die Bewegung
  /// dieses Elements (die übrigen stehen still) – Auswahl/Panel bleiben.
  void _playAnim({String? only}) {
    _animTicker?.dispose();
    var from = 0.0, to = _anim.seconds.toDouble();
    GraphicAnim? pa;
    if (only != null) {
      final it = _anim.items[only];
      if (it == null || !it.isActive) {
        _stopAnim();
        return;
      }
      pa = _anim.copy()
        ..items.removeWhere((k, _) => k != only)
        ..bg = 'none';
      // Kurz vor dem Start beginnen, nach dem Effekt noch kurz stehen lassen.
      from = math.max(0, it.start - 0.3);
      final pulse = it.pulse || it.shine;
      to = math.min(
        _anim.seconds.toDouble(),
        it.start + it.len + (pulse ? 2.5 : 0.8),
      );
    }
    setState(() {
      if (only == null) _posterSel = null;
      _previewAnim = pa;
      _animT = from;
    });
    _animTicker = createTicker((elapsed) {
      if (!mounted) return;
      final t = from + elapsed.inMicroseconds / 1e6;
      if (t >= to) {
        _stopAnim();
        return;
      }
      setState(() => _animT = t);
    })..start();
  }

  void _stopAnim() {
    _animTicker?.dispose();
    _animTicker = null;
    if (mounted) {
      setState(() {
        _animT = null;
        _previewAnim = null;
      });
    }
  }

  /// Text für den Zähler (Zahlen hochzählen/rollen) beim Abspielen.
  String _animStr(String id, String text) {
    final t = _animT;
    if (t == null) return text;
    return countText(text, _anim.items[id], t, seed: id);
  }

  String _animType(String id) {
    if (id == 'player') return 'player';
    if (id.startsWith('overlay_')) return 'image';
    if (id == 'std_score') return 'score';
    const logos = {
      'logos',
      'sponsor',
      'std_logo',
      'std_sponsor',
      'std_ft_sponsor',
    };
    if (logos.contains(id)) return 'logo';
    const other = {
      'std_lineup',
      'std_scorers',
      'std_ft_scorers',
      'std_ft_banner',
      'sponsorbar',
      'std_sponsorbar',
      'std_ft_sponsorbar',
    };
    if (other.contains(id)) return 'other';
    return 'text';
  }

  String? _animTextOf(String id) {
    if (id == 'std_score') {
      final r = widget.result;
      return r == null ? null : '${r.ownScore} : ${r.oppScore}';
    }
    if (id == 'headline') return _annHeadText;
    return _textContent[id];
  }

  /// Sichtbare Elemente des aktuellen Formats (oben → unten) für Vorlagen/KI.
  List<AnimElement> _animElements() {
    final ids = <String>[];
    if (!widget.isAnnouncement) {
      for (final id in _kStdOrder) {
        if (_stdCtx.containsKey(id) && !_stdHidden.contains(id)) ids.add(id);
      }
    }
    final free = [
      for (final id in _posterOrder)
        if (!(id == 'player' && _posterMainF[_designKey] == null) &&
            !ids.contains(id))
          id,
    ];
    double yOf(String id) =>
        (_posterPosF[_designKey]?[id] ?? _kCenteredItemDefaults[id])?.dy ?? 0.5;
    free.sort((a, b) => yOf(a).compareTo(yOf(b)));
    ids.addAll(free);
    return [
      for (final id in ids)
        (id: id, type: _animType(id), text: _animTextOf(id)),
    ];
  }

  void _applyAnimPreset(String preset) {
    final secs = _anim.seconds;
    setState(() {
      _animF[_designKey] = applyPreset(
        preset,
        _animElements(),
        kind: _kind,
        seconds: secs,
      );
    });
    if (preset != 'none') _playAnim();
  }

  /// „Mit KI animieren": KI wählt je Element Effekt/Zeit/Zähler.
  Future<bool> _aiAnimate({
    bool play = true,
    Set<String>? ids,
    bool withBg = true,
  }) async {
    final els = [
      for (final e in _animElements())
        if (ids == null || ids.contains(e.id)) e,
    ];
    if (_aiBusy || (els.isEmpty && !withBg)) return false;
    final messenger = ScaffoldMessenger.of(context);
    _stopAnim();
    setState(() {
      _aiBusy = true;
      _aiBusyLabel = 'KI plant die Animation …';
    });
    try {
      final shot = await _captureForAi();
      if (shot == null) throw Exception('Aufnahme fehlgeschlagen');
      final res = await CloudService.aiAnim(
        provider: _aiAnimProvider,
        image: shot,
        elements: [
          for (var i = 0; i < els.length; i++)
            {
              'id': els[i].id,
              'type': els[i].type,
              if (els[i].text != null) 'text': els[i].text,
              if (_posterPosF[_designKey]?[els[i].id] case final p?) ...{
                'x': double.parse(p.dx.toStringAsFixed(2)),
                'y': double.parse(p.dy.toStringAsFixed(2)),
              },
              'layer': i,
            },
        ],
        kind: _kind,
        format: _format,
        seconds: _anim.seconds,
        note: ids == null
            ? null
            : 'Der Trainer hat diese Elemente gezielt ausgewaehlt: animiere '
                  'JEDES uebergebene Element. Hintergrund bewegen: '
                  '${withBg ? 'ja' : 'nein (bg = none)'}.',
      );
      if (res == null) throw Exception('Keine Antwort der KI');
      final picked = {for (final e in els) e.id};
      final ai = GraphicAnim.fromJson(res, ids: picked, seconds: _anim.seconds);
      if (!mounted) return false;
      final a = mergeAnim(_anim, ai, picked, withBg: withBg);
      setState(() => _animF[_designKey] = a);
      if (play) _playAnim();
      return true;
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('KI-Animation fehlgeschlagen: $e')),
      );
      return false;
    } finally {
      if (mounted) {
        setState(() {
          _aiBusy = false;
        });
      }
    }
  }

  /// Grafik bzw. nur Hintergrund als JPEG-Data-URL (für das KI-Video).
  Future<String?> _captureJpegDataUrl(GlobalKey key, double widthPx) async {
    final image = await _captureImage(key, widthPx);
    if (image == null) return null;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return null;
    return compute(_rgbaToJpegDataUrl, <String, Object>{
      'w': image.width,
      'h': image.height,
      'px': data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    });
  }

  /// MP4 aus der Animation erzeugen (Frame für Frame) und teilen.
  Future<void> _exportVideo() async {
    if (!VideoEncoder.isSupported || _videoBusy) return;
    final messenger = ScaffoldMessenger.of(context);
    final bgVideo = _aiVideoPath;
    const fps = 30;
    final total = _anim.seconds * fps;
    _stopAnim();
    setState(() {
      _posterSel = null;
      _videoBusy = true;
      _videoCancel = false;
      _videoStatus = 'Video wird erstellt … 0 %';
      _hideBg = bgVideo != null;
      _animT = 0;
    });
    var started = false;
    try {
      try {
        await GoogleFonts.pendingFonts();
      } catch (_) {}
      await WidgetsBinding.instance.endOfFrame;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final boundary =
          _boundaryKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) throw Exception('Grafik nicht bereit');
      final ratio = 1080 / _cw;
      final path = await appFilePath(
        '${_kind}_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.mp4',
        temp: true,
      );
      for (var i = 0; i < total; i++) {
        if (_videoCancel) {
          if (started) await VideoEncoder.cancel();
          return;
        }
        if (i > 0) {
          setState(() => _animT = i / fps);
          await WidgetsBinding.instance.endOfFrame;
        }
        final img = await boundary.toImage(pixelRatio: ratio);
        final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
        final w = img.width, h = img.height;
        img.dispose();
        if (data == null) throw Exception('Bild konnte nicht gelesen werden');
        if (!started) {
          started = await VideoEncoder.start(
            path: path,
            width: w,
            height: h,
            fps: fps,
            bgVideo: bgVideo,
          );
          if (!started) throw Exception('Encoder startet nicht');
        }
        await VideoEncoder.frame(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          i,
        );
        if (i % 6 == 0 && mounted) {
          setState(
            () => _videoStatus =
                'Video wird erstellt … ${(i * 100 / total).round()} %',
          );
        }
      }
      setState(() => _videoStatus = 'Video wird gespeichert …');
      final out = await VideoEncoder.finish();
      started = false;
      if (out != null) await shareFile(out, text: _kind);
    } catch (e) {
      if (started) await VideoEncoder.cancel();
      messenger.showSnackBar(
        SnackBar(content: Text('Video fehlgeschlagen: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _videoBusy = false;
          _animT = null;
          _hideBg = false;
        });
      }
    }
  }

  /// KI-Video: Variante wählen, erzeugen lassen (Gemini Omni Flash, 9:16).
  Future<void> _askAiVideo() async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('KI-Video erzeugen'),
        content: Text(
          'Die KI macht aus dem Bild ein bewegtes Video. Das kostet '
          'Google-Guthaben und dauert meist 1–3 Minuten.'
          '${_format == 'p' ? ' Für den Post wird das Video quadratisch '
                    'zugeschnitten.' : ''}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Abbrechen'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(ctx, 'full'),
            child: const Text('Ganze Grafik'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'bg'),
            child: const Text('Nur Hintergrund (Schrift scharf)'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    await _aiVideo(full: choice == 'full');
  }

  Future<bool> _aiVideo({required bool full}) async {
    final messenger = ScaffoldMessenger.of(context);
    _stopAnim();
    setState(() {
      _videoBusy = true;
      _videoCancel = false;
      _videoStatus = 'KI erstellt das Video …';
    });
    try {
      final img = await _captureJpegDataUrl(
        full ? _boundaryKey : _bgBoundaryKey,
        720,
      );
      if (img == null) throw Exception('Aufnahme fehlgeschlagen');
      final prompt = full
          ? 'Erwecke diese Fussball-Social-Media-Grafik dezent zum Leben: '
                'langsame, ruhige Kamerafahrt, Licht und Atmosphaere bewegen '
                'sich, der Spieler wirkt lebendig. Schrift, Zahlen und Logos '
                'bleiben exakt unveraendert, scharf und an ihrem Platz. Keine '
                'Schnitte, kein Ton.'
          : 'Erwecke diesen Hintergrund einer Fussball-Social-Media-Grafik '
                'zum Leben: langsame Kamerafahrt, Lichtstrahlen, leichter '
                'Nebel und Partikel, Stadion-Atmosphaere. Gleiche Farben und '
                'Stimmung. Keine Texte, Logos oder Personen hinzufuegen, keine '
                'Schnitte, kein Ton.';
      final start = await CloudService.aiVideoStart(
        image: img,
        prompt: prompt,
        seconds: _anim.seconds.clamp(5, 15),
      );
      var video = start.video;
      final op = start.operation;
      final t0 = DateTime.now();
      while (video == null && op != null) {
        if (_videoCancel) return false;
        final secs = DateTime.now().difference(t0).inSeconds;
        if (secs > 600) throw Exception('Zeitüberschreitung');
        if (mounted) {
          setState(() => _videoStatus = 'KI erstellt das Video … $secs s');
        }
        await Future<void>.delayed(const Duration(seconds: 10));
        final p = await CloudService.aiVideoPoll(op);
        if (p.done) video = p.video;
      }
      if (video == null) throw Exception('Kein Video erhalten');
      final path = await appFilePath(
        'ki_video_${DateTime.now().millisecondsSinceEpoch}.mp4',
      );
      await File(path).writeAsBytes(video);
      if (full) {
        // KI liefert Hochformat 9:16 → für den Post quadratisch zuschneiden.
        final out = _format == 's' ? path : await _cropVideoToFormat(path);
        if (out == null) return false;
        await shareFile(out, text: _kind);
      } else {
        if (!mounted) return false;
        setState(() {
          _aiVideoF[_designKey] = path;
        });
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'KI-Hintergrund fertig – „Als Video teilen" legt alles '
              'scharf darüber.',
            ),
          ),
        );
      }
      return true;
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('KI-Video fehlgeschlagen: $e')),
      );
      return false;
    } finally {
      if (mounted) setState(() => _videoBusy = false);
    }
  }

  /// Video ([src], 9:16) auf das aktuelle Format zuschneiden (mittig, füllend)
  /// – über den Encoder mit dem Video als Hintergrund und leeren Frames.
  Future<String?> _cropVideoToFormat(String src) async {
    const fps = 30;
    final w = 1080, h = (_ch * 1080 / _cw).round();
    final path = await appFilePath(
      'ki_video_${_format}_${DateTime.now().millisecondsSinceEpoch}.mp4',
      temp: true,
    );
    if (!await VideoEncoder.start(
      path: path,
      width: w,
      height: h,
      fps: fps,
      bgVideo: src,
    )) {
      return null;
    }
    final empty = Uint8List(w * h * 4); // komplett transparent
    final total = _anim.seconds * fps;
    for (var i = 0; i < total; i++) {
      if (_videoCancel) {
        await VideoEncoder.cancel();
        return null;
      }
      await VideoEncoder.frame(empty, i);
      if (i % 15 == 0 && mounted) {
        setState(
          () => _videoStatus =
              'Video wird zugeschnitten … ${(i * 100 / total).round()} %',
        );
      }
    }
    return VideoEncoder.finish();
  }

  /// „Alles mit KI": KI animiert die Elemente, erzeugt den bewegten
  /// Hintergrund und erstellt danach direkt das Video zum Teilen.
  Future<void> _aiAll({Set<String>? ids, bool withBg = true}) async {
    final app = context.read<AppState>();
    final withVideo = VideoEncoder.isSupported && app.canAiImage;
    if (withVideo) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Alles mit KI'),
          content: Text(
            withBg
                ? 'Die KI animiert die gewählten Elemente, erzeugt einen '
                      'bewegten Hintergrund (Google-Guthaben, meist 1–3 '
                      'Minuten) und macht daraus das Video zum Teilen. Schrift '
                      'und Logos bleiben gestochen scharf.'
                : 'Die KI animiert die gewählten Elemente und macht daraus '
                      'das Video zum Teilen.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Los'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    if (!await _aiAnimate(play: !withVideo, ids: ids, withBg: withBg)) return;
    if (!withVideo || !mounted) return;
    if (withBg && !await _aiVideo(full: false)) return;
    if (!mounted) return;
    await _exportVideo();
  }

  // ------------------------------------- KI: Elemente gezielt auswählen
  /// Auswahlmodus „Elemente für die KI antippen" (null = aus).
  Set<String>? _aiPick;
  bool _aiPickBg = true;
  String _aiPickAction = 'effects'; // 'effects' | 'all'
  final Map<String, Set<String>> _aiPickLastF = {};
  final GlobalKey _aiPickKey = GlobalKey();
  Map<String, Rect> _aiPickRects = {};

  /// Auswählbare Elemente, oberstes zuerst (für das Antippen).
  List<String> _aiPickCandidates() {
    final ids = {for (final e in _animElements()) e.id};
    return [
      for (final id in _posterOrder.reversed)
        if (ids.contains(id)) id,
      for (final id in _kStdOrder)
        if (ids.contains(id)) id,
    ];
  }

  void _startAiPick(String action) {
    _closePanel();
    _stopAnim();
    final all = {for (final e in _animElements()) e.id};
    final last = _aiPickLastF[_designKey];
    setState(() {
      _posterSel = null;
      _aiPickAction = action;
      _aiPick = last == null ? all : last.intersection(all);
      _aiPickRects = {};
    });
  }

  void _endAiPick() => setState(() {
    _aiPick = null;
    _aiPickRects = {};
  });

  void _runAiPick() {
    final ids = {...?_aiPick};
    final bg = _aiPickBg;
    final action = _aiPickAction;
    _aiPickLastF[_designKey] = ids;
    _endAiPick();
    if (action == 'all') {
      _aiAll(ids: ids, withBg: bg);
    } else {
      _aiAnimate(ids: ids, withBg: bg);
    }
  }

  /// Lage der Elemente in der Auswahl-Ebene messen (auch gedreht/skaliert
  /// und in der verkleinerten Vorschau).
  void _measureAiPick() {
    final layer = _aiPickKey.currentContext?.findRenderObject();
    if (layer is! RenderBox || !layer.attached || !layer.hasSize) return;
    final rects = <String, Rect>{};
    for (final id in _aiPickCandidates()) {
      final c = _stdCtx[id];
      if (c == null || !c.mounted) continue;
      final b = c.findRenderObject();
      if (b is! RenderBox || !b.attached || !b.hasSize) continue;
      try {
        rects[id] = MatrixUtils.transformRect(
          b.getTransformTo(layer),
          Offset.zero & b.size,
        );
      } catch (_) {}
    }
    if (!mapEquals(rects, _aiPickRects)) setState(() => _aiPickRects = rects);
  }

  /// Ebene über der Vorschau: Antippen wählt Elemente für die KI (nichts
  /// wird verschoben). Liegt außerhalb der Grafik → nie im Export.
  Widget _aiPickLayer() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _aiPick != null) _measureAiPick();
    });
    final pick = _aiPick ?? const <String>{};
    return Positioned.fill(
      child: GestureDetector(
        key: _aiPickKey,
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) {
          final p = d.localPosition;
          for (final id in _aiPickCandidates()) {
            final r = _aiPickRects[id];
            if (r == null || !r.contains(p)) continue;
            setState(() {
              final s = _aiPick ?? <String>{};
              s.contains(id) ? s.remove(id) : s.add(id);
              _aiPick = s;
            });
            return;
          }
        },
        child: Stack(
          children: [
            for (final e in _aiPickRects.entries)
              Positioned.fromRect(
                rect: e.value.inflate(2),
                child: IgnorePointer(
                  child: Container(
                    alignment: Alignment.topRight,
                    decoration: BoxDecoration(
                      color: pick.contains(e.key)
                          ? Colors.greenAccent.withValues(alpha: 0.12)
                          : null,
                      border: Border.all(
                        color: pick.contains(e.key)
                            ? Colors.greenAccent
                            : Colors.white.withValues(alpha: 0.45),
                        width: pick.contains(e.key) ? 3 : 1,
                      ),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: pick.contains(e.key)
                        ? const Icon(
                            Icons.check_circle,
                            color: Colors.greenAccent,
                            size: 20,
                          )
                        : null,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Leiste über der Vorschau im Auswahlmodus.
  /// Chip-Name: Texte mit ihrem Inhalt (sonst hießen alle nur „Text").
  String _pickLabel(String id) {
    final t = _animTextOf(id)?.replaceAll('\n', ' ').trim();
    if (id.startsWith('text_') && t != null && t.isNotEmpty) {
      return t.length > 16 ? '${t.substring(0, 16)} …' : t;
    }
    return _posterItemLabel(id);
  }

  Widget _aiPickBar() {
    final n = _aiPick?.length ?? 0;
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Tippe in der Grafik oder unten an, was die KI animieren soll · '
              '$n gewählt',
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            // Alle Elemente als Chips – auch winzige sicher an-/abwählbar.
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final id in _aiPickCandidates())
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: FilterChip(
                        label: Text(_pickLabel(id)),
                        selected: _aiPick?.contains(id) ?? false,
                        onSelected: (v) => setState(() {
                          final s = {...?_aiPick};
                          v ? s.add(id) : s.remove(id);
                          _aiPick = s;
                        }),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 6,
              runSpacing: 4,
              children: [
                FilterChip(
                  label: const Text('Hintergrund'),
                  selected: _aiPickBg,
                  onSelected: (v) => setState(() => _aiPickBg = v),
                ),
                TextButton(
                  onPressed: () =>
                      setState(() => _aiPick = {..._aiPickCandidates()}),
                  child: const Text('Alle'),
                ),
                TextButton(
                  onPressed: () => setState(() => _aiPick = <String>{}),
                  child: const Text('Keine'),
                ),
                TextButton(
                  onPressed: _endAiPick,
                  child: const Text('Abbrechen'),
                ),
                FilledButton.icon(
                  onPressed: n == 0 && !_aiPickBg ? null : _runAiPick,
                  icon: const Icon(Icons.auto_awesome, size: 18),
                  label: const Text('KI animieren'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Fortschritt (Video-Export/KI-Video) über der Vorschau – nicht im Bild.
  Widget _videoOverlay() => Positioned.fill(
    child: AbsorbPointer(
      absorbing: false,
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.35),
        child: Center(
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 12),
                  Text(_videoStatus, textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => setState(() => _videoCancel = true),
                    child: const Text('Abbrechen'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );

  /// Bereich „Animation" im Hauptscreen.
  Widget _animControls({bool panel = false}) {
    final a = _anim;
    final app = context.watch<AppState>();
    final canClaude = app.canAiCoach, canGemini = app.canAiImage;
    if (!canClaude && _aiAnimProvider == 'claude' && canGemini) {
      _aiAnimProvider = 'gemini';
    }
    final hint = TextStyle(fontSize: 12, color: Theme.of(context).hintColor);
    final kids = <Widget>[
      if (panel)
        _secHead(
          'Vorlage',
          first: true,
          info:
              'Wie die Elemente erscheinen. Einzelne Elemente stellst du '
              'direkt ein: Element antippen → Bewegung.',
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final e in GraphicAnim.presets.entries)
              ChoiceChip(
                label: Text(e.value),
                selected: a.preset == e.key,
                onSelected: (_) => _applyAnimPreset(e.key),
              ),
          ],
        ),
      ),
      Row(
        children: [
          const Text('Länge'),
          Expanded(
            child: Slider(
              value: a.seconds.toDouble(),
              min: 5,
              max: 15,
              divisions: 10,
              label: '${a.seconds} s',
              onChanged: (v) => setState(() => a.seconds = v.round()),
            ),
          ),
          Text('${a.seconds} s'),
        ],
      ),
      if (panel)
        _secHead(
          'Hintergrund bewegt sich',
          info:
              'Aus = steht still. Heranzoomen = langsamer Zoom ins Bild. '
              'Schwenken = langsame Seitwärtsbewegung.',
        ),
      Row(
        children: [
          if (!panel) ...[const Text('Hintergrund'), const SizedBox(width: 12)],
          Expanded(
            child: SegmentedButton<String>(
              showSelectedIcon: false,
              segments: [
                for (final e in GraphicAnim.backgrounds.entries)
                  ButtonSegment(value: e.key, label: Text(e.value)),
              ],
              selected: {a.bg},
              onSelectionChanged: (s) => setState(() => a.bg = s.first),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      if (!panel && (canClaude || canGemini)) ...[
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _aiBusy || _videoBusy ? null : () => _startAiPick('all'),
            icon: const Icon(Icons.auto_awesome),
            label: Text(
              VideoEncoder.isSupported && canGemini
                  ? 'Alles mit KI (animieren + Video)'
                  : 'Alles mit KI animieren',
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            if (canClaude && canGemini) ...[
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'claude', label: Text('Claude')),
                  ButtonSegment(value: 'gemini', label: Text('Gemini')),
                ],
                selected: {_aiAnimProvider},
                onSelectionChanged: (s) =>
                    setState(() => _aiAnimProvider = s.first),
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: _aiBusy || _videoBusy
                    ? null
                    : () => _startAiPick('effects'),
                icon: const Icon(Icons.auto_awesome, size: 18),
                label: const Text('Nur Effekte'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
      ],
      Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: !a.isActive || _videoBusy
                  ? null
                  : (_animPlaying ? _stopAnim : _playAnim),
              icon: Icon(_animPlaying ? Icons.stop : Icons.play_arrow),
              label: Text(_animPlaying ? 'Stopp' : 'Abspielen'),
            ),
          ),
          if (canGemini && !panel) ...[
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: VideoEncoder.isSupported && !_videoBusy && !_aiBusy
                    ? _askAiVideo
                    : null,
                icon: const Icon(Icons.movie_creation_outlined, size: 18),
                label: const Text('KI-Video'),
              ),
            ),
          ],
        ],
      ),
      if (_aiVideoPath != null)
        Row(
          children: [
            const Icon(Icons.videocam_outlined, size: 18),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'KI-Hintergrundvideo aktiv – bewegt sich im Video-Export',
                style: hint,
              ),
            ),
            TextButton(
              onPressed: () => setState(() => _aiVideoF.remove(_designKey)),
              child: const Text('Entfernen'),
            ),
          ],
        ),
      const SizedBox(height: 4),
      Text(
        VideoEncoder.isSupported
            ? 'Das Video teilst du oben über „Teilen" → „Als Video teilen". '
                  'KI-Bewegung findest du im Reiter KI.'
            : 'Video-Export gibt es in der Android-App. KI-Bewegung findest '
                  'du im Reiter KI.',
        style: hint,
      ),
    ];
    if (panel) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: kids,
      );
    }
    return ExpansionTile(
      leading: const Icon(Icons.movie_filter_outlined),
      title: const Text('Animation (Video für Instagram)'),
      subtitle: a.isActive
          ? Text(
              '${a.preset == 'ai' ? 'KI' : GraphicAnim.presets[a.preset] ?? 'Eigene'}'
              ' · ${a.seconds} s',
            )
          : null,
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      children: kids,
    );
  }

  /// Abschnitt „Animation" im Element-Sheet.
  Widget _animSection(
    String id,
    void Function(VoidCallback fn) apply, {
    bool open = false,
  }) {
    final cur = _anim.items[id] ?? ElementAnim();
    final maxStart = math.max(1, _anim.seconds - 1).toDouble();
    void upd(void Function(ElementAnim x) f, {bool play = true}) {
      apply(() {
        final x = _anim.items[id] ?? ElementAnim();
        f(x);
        if (x.isActive) {
          _anim.items[id] = x;
        } else {
          _anim.items.remove(id);
        }
      });
      // Änderung direkt in der Grafik zeigen (nur dieses Element).
      if (play) _playAnim(only: id);
    }

    final txt = _animTextOf(id);
    final canCount = id == 'std_score' || (txt != null && hasNumber(txt));
    final kids = <Widget>[
      DropdownButtonFormField<String>(
        initialValue: cur.fx,
        decoration: const InputDecoration(labelText: 'Effekt'),
        items: [
          for (final e in ElementAnim.effects.entries)
            DropdownMenuItem(value: e.key, child: Text(e.value)),
        ],
        onChanged: (v) => upd((x) => x.fx = v ?? 'none'),
      ),
      Row(
        children: [
          const Text('Start'),
          Expanded(
            child: Slider(
              value: cur.start.clamp(0, maxStart).toDouble(),
              min: 0,
              max: maxStart,
              divisions: (maxStart * 10).round(),
              label: '${cur.start.toStringAsFixed(1)} s',
              onChanged: (v) => upd((x) => x.start = v, play: false),
              onChangeEnd: (_) => _playAnim(only: id),
            ),
          ),
          Text('${cur.start.toStringAsFixed(1).replaceAll('.', ',')} s'),
        ],
      ),
      if (canCount)
        Row(
          children: [
            const Text('Zahl'),
            const SizedBox(width: 12),
            Expanded(
              child: SegmentedButton<String>(
                showSelectedIcon: false,
                segments: [
                  for (final e in ElementAnim.counts.entries)
                    ButtonSegment(value: e.key, label: Text(e.value)),
                ],
                selected: {cur.count},
                onSelectionChanged: (s) => upd((x) {
                  x.count = s.first;
                  if (x.count != 'none' && x.len < 1.2) x.len = 1.5;
                }),
              ),
            ),
          ],
        ),
      Wrap(
        spacing: 8,
        children: [
          FilterChip(
            label: const Text('Glanz'),
            selected: cur.shine,
            onSelected: (v) => upd((x) => x.shine = v),
          ),
          FilterChip(
            label: const Text('Pulsieren'),
            selected: cur.pulse,
            onSelected: (v) => upd((x) => x.pulse = v),
          ),
        ],
      ),
      const SizedBox(height: 6),
      SizedBox(
        width: double.infinity,
        child: FilledButton.tonalIcon(
          onPressed: !cur.isActive
              ? null
              : (_animPlaying ? _stopAnim : () => _playAnim(only: id)),
          icon: Icon(_animPlaying ? Icons.stop : Icons.play_arrow),
          label: Text(
            !cur.isActive
                ? 'Erst einen Effekt wählen'
                : (_animPlaying ? 'Stopp' : 'Vorschau abspielen'),
          ),
        ),
      ),
    ];
    // Im Panel: ohne Klapp-Kachel (Titel steht schon oben), mit Abstand,
    // damit das Feld-Label nicht abgeschnitten wird.
    if (open) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [const SizedBox(height: 10), ...kids],
      );
    }
    return ExpansionTile(
      leading: const Icon(Icons.animation),
      title: const Text('Animation'),
      initiallyExpanded: open,
      subtitle: cur.isActive
          ? Text(
              '${ElementAnim.effects[cur.fx]} · ab '
              '${cur.start.toStringAsFixed(1).replaceAll('.', ',')} s',
            )
          : null,
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.zero,
      shape: const Border(),
      collapsedShape: const Border(),
      children: kids,
    );
  }

  /// Ausgeblendete Grundteile dieses Formats (zum Wieder-Einblenden):
  /// Ergebnis/Startelf = ausgeblendete feste Teile, Ankündigung = aus der
  /// Ebenen-Liste entfernte Grundelemente.
  List<String> get _hiddenItems => widget.isAnnouncement
      ? [
          for (final id in _kPosterBaseOrder)
            if (!_posterOrder.contains(id)) id,
        ]
      : [
          for (final id in _kStdOrder)
            if (_stdHidden.contains(id)) id,
        ];

  // Feste Teile von Ergebnis/Startelf in Layout-Reihenfolge (für Listen).
  static const List<String> _kStdOrder = [
    'std_logo',
    'std_title',
    'std_sponsor_text',
    'std_sponsor',
    'std_info',
    'std_vs',
    'std_score',
    'std_scorers',
    'std_lineup',
    'std_sponsorbar',
    'std_ft_sponsor_text',
    'std_ft_sponsor',
    'std_ft_title',
    'std_ft_banner',
    'std_ft_scorers',
    'std_ft_sponsorbar',
  ];

  /// Ein ausgeblendetes Grundteil wieder einblenden (Ankündigung: an seiner
  /// ursprünglichen Ebenen-Position).
  void _restoreHiddenItem(String id) {
    setState(() {
      if (id.startsWith('std_')) {
        _stdHidden.remove(id);
        return;
      }
      if (_posterOrder.contains(id)) return;
      final base = _kPosterBaseOrder;
      final bi = base.indexOf(id);
      var insertAt = _posterOrder.length;
      for (var i = bi + 1; i < base.length; i++) {
        final j = _posterOrder.indexOf(base[i]);
        if (j >= 0) {
          insertAt = j;
          break;
        }
      }
      _posterOrder.insert(insertAt, id);
    });
  }

  /// Ein Overlay ODER Textfeld wieder entfernen (aktuelles Format).
  void _removePosterItem(String id) {
    setState(() {
      if (id.startsWith('std_')) {
        // Festes Teil: nur ausblenden (Platz bleibt), über das Menü
        // „Hinzufügen & Hintergrund" wieder einblendbar.
        _stdHidden.add(id);
        if (_posterSel == id) _posterSel = null;
        return;
      }
      if (id == 'player') {
        // Spieler: nur das Bild entfernen (bleibt in der Reihenfolge, lässt sich
        // über „Spielerbild" wieder hinzufügen).
        _posterMainF[_designKey] = null;
        _imgOrig.remove('player');
        _imgFeather.remove('player');
        _imgInner.remove('player');
        _imgRim.remove('player');
        if (_posterSel == 'player') _posterSel = null;
        return;
      }
      if (_kPosterBaseOrder.contains(id)) {
        // Grundelement: nur ausblenden – Position/Text bleiben erhalten.
        _posterOrder.remove(id);
        if (_posterSel == id) _posterSel = null;
        return;
      }
      _posterOverlays.removeWhere((o) => o.id == id);
      _textIds.remove(id);
      _textContent.remove(id);
      _textFont.remove(id);
      _textColor.remove(id);
      _posterOrder.remove(id); // strukturelle Elemente werden ausgeblendet
      _posterPos.remove(id);
      _posCentered.remove(id);
      _posterScale.remove(id);
      _posterRot.remove(id);
      _imgOrig.remove(id);
      _imgFeather.remove(id);
      _imgInner.remove(id);
      _imgRim.remove(id);
      if (_posterSel == id) _posterSel = null;
    });
  }

  /// FuPa: Foto aufnehmen/wählen (Kamera, Galerie, Kader) und direkt per KI
  /// freistellen (Motiv-Abfrage wie gewohnt).
  Future<void> _fupaTakePhoto() async {
    final before = _posterMain;
    await _addPosterMain();
    if (!mounted || _posterMain == null || _posterMain == before) return;
    setState(() => _posterSel = 'player');
    await _cutoutSelected();
  }

  /// FuPa: fertiges Bild (960×1200) als eigenes FuPa-, Vereins- oder
  /// Actionfoto ins Spielerprofil übernehmen – optional als Profilbild.
  Future<void> _fupaAdoptAsPlayerPhoto() async {
    final messenger = ScaffoldMessenger.of(context);
    final state = context.read<AppState>();
    final pid = widget.designer?.playerId;
    final teamId = widget.teamId;
    if (pid == null || teamId == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Kein Spieler verknüpft.')),
      );
      return;
    }
    final players = await state.playersOf(teamId);
    if (!mounted) return;
    final player = players.where((p) => p.id == pid).firstOrNull;
    if (player == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Spieler nicht mehr im Kader.')),
      );
      return;
    }
    // Fach wählen: eigenes FuPa-Foto, Vereins- oder Actionfoto (+ Profilbild).
    var slot = PlayerPhotoSlot.own;
    var asProfile = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text('Foto für ${player.fullName}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final s in const [
                PlayerPhotoSlot.own,
                PlayerPhotoSlot.club,
                PlayerPhotoSlot.action,
              ])
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    slot == s
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                  ),
                  title: Text(s.description),
                  onTap: () => setD(() {
                    slot = s;
                    asProfile = s == PlayerPhotoSlot.own;
                  }),
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Als Profilbild verwenden'),
                subtitle: const Text('Rundes Bild in Kader und Grafiken'),
                value: asProfile,
                onChanged: (v) => setD(() => asProfile = v),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Übernehmen'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _sharing = true);
    try {
      // Originalformat der FuPa-Vorlage: 960×1200.
      final image = await _captureImage(_boundaryKey, 960);
      if (image == null) return;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return;
      final url = await compute(_rgbaToJpegDataUrl, <String, Object>{
        'w': image.width,
        'h': image.height,
        'px': data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      });
      await state.setPlayerPhoto(player, slot, url, asProfile: asProfile);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Als ${slot.description} von ${player.fullName} gespeichert'
            '${asProfile ? ' (Profilbild)' : ''}.',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Übernehmen fehlgeschlagen: $e')),
      );
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  /// Schlanker Hauptscreen-Block: großer „Bearbeiten"-Button. Die element-
  /// schweren Werkzeuge stecken im Vollbild-Editor (_editTools).
  /// Element-Werkzeuge (im Vollbild-Editor): Auswahl (Antippen/Liste/Pfeile),
  /// Hinzufügen, gewähltes Element, Bild-Effekte, Text, Überschrift/Sponsoren.
  /// Zentrale Hintergrund-/Kopf-Eigenschaften (Überschrift, Schrift, Sponsoren,
  /// Logos, Schatten) – im Hintergrund-Menü. [refresh] aktualisiert das Sheet
  /// live (zusätzlich zum setState der Grafik dahinter).
  /// Langdruck auf den leeren Hintergrund → Objekte hinzufügen + zentrale
  /// Hintergrund-Eigenschaften (wie moderne Design-Apps).
  /// Kurzname eines Looks (Vorlagen-Name oder Anfang des eigenen Textes).
  String _lookName(_AiLook l) {
    for (final group in kAiLookPresets.values) {
      for (final p in group) {
        if (p.$2 == l.theme) return p.$1;
      }
    }
    final t = l.theme.trim();
    return t.length > 32 ? '${t.substring(0, 32)} …' : t;
  }

  /// Abschnitt „KI-Look (Overlay)" im Menü „Hinzufügen & Hintergrund".
  Widget _lookSection(BuildContext ctx, void Function(VoidCallback) setSheet) {
    final look = _look;
    void upd(VoidCallback fn) {
      setState(fn);
      setSheet(() {});
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Row(
          children: [
            Icon(Icons.auto_awesome, size: 18),
            SizedBox(width: 6),
            Text(
              'KI-Look (Overlay)',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        const SizedBox(height: 2),
        const Text(
          'Deko über der Grafik (z. B. Karneval, Derby) – Texte, Logos und '
          'Spieler bleiben unverändert.',
          style: TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 6),
        if (look == null)
          OutlinedButton.icon(
            icon: _lookBusy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_awesome, size: 18),
            label: Text(_lookBusy ? 'KI gestaltet …' : 'KI-Look erstellen'),
            onPressed: _lookBusy
                ? null
                : () {
                    _closePanel();
                    _openLookDialog();
                  },
          )
        else ...[
          Text(
            'Aktiv: ${_lookName(look)} · '
            '${look.mode == 'cutout' ? 'Freigestellt' : 'Leuchtend'}',
            style: const TextStyle(fontSize: 13),
          ),
          Row(
            children: [
              const SizedBox(
                width: 52,
                child: Text('Stärke', style: TextStyle(fontSize: 12)),
              ),
              Expanded(
                child: Slider(
                  value: look.opacity.clamp(0.1, 1.0),
                  min: 0.1,
                  max: 1.0,
                  onChanged: (v) => upd(() => look.opacity = v),
                ),
              ),
              SizedBox(
                width: 40,
                child: Text(
                  '${(look.opacity * 100).round()}%',
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Neu erzeugen'),
                onPressed: _lookBusy
                    ? null
                    : () {
                        _closePanel();
                        _createLook(theme: look.theme, mode: look.mode);
                      },
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.edit, size: 18),
                label: const Text('Ändern'),
                onPressed: _lookBusy
                    ? null
                    : () {
                        _closePanel();
                        _openLookDialog(current: look);
                      },
              ),
              TextButton.icon(
                icon: const Icon(Icons.delete_outline, color: Colors.red),
                label: const Text(
                  'Entfernen',
                  style: TextStyle(color: Colors.red),
                ),
                onPressed: () => upd(() => _lookF.remove(_designKey)),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// Dialog „KI-Look erstellen": Vorlagen (füllen das Textfeld, frei
  /// änderbar) oder eigener Text + Darstellung Leuchtend/Freigestellt.
  Future<void> _openLookDialog({_AiLook? current}) async {
    final res = await showAiLookDialog(
      context,
      theme: current?.theme,
      mode: current?.mode ?? 'glow',
    );
    if (res == null || !mounted) return;
    await _createLook(theme: res.theme, mode: res.mode);
  }

  /// Erzeugt den KI-Look: leere Leinwand im Zielformat (Schwarz/Magenta) an
  /// Gemini (Modus `overlay`), Ergebnis in ein PNG mit Alpha umrechnen und als
  /// Deko-Ebene über die Grafik legen (je Format gespeichert).
  Future<void> _createLook({
    required String theme,
    required String mode,
  }) async {
    if (_lookBusy) return;
    setState(() => _lookBusy = true);
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(
        content: Text('KI gestaltet den Look …'),
        duration: Duration(seconds: 3),
      ),
    );
    try {
      final png = await generateAiLookPng(
        theme: theme,
        mode: mode,
        width: _format == 's' ? 576 : (_format == 'f' ? 819 : 1024),
        height: 1024,
        aspect: _aiAspect,
        gradTop: _settings.gradTop,
        gradBottom: _settings.gradBottom,
      );
      if (png == null) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Die KI hat kein Bild zurückgegeben.')),
        );
        return;
      }
      if (!mounted) return;
      final keepOpacity = _look?.opacity ?? 1.0;
      setState(
        () => _lookF[_designKey] = _AiLook(
          dataUrl: 'data:image/png;base64,${base64Encode(png)}',
          mode: mode,
          theme: theme,
          opacity: keepOpacity,
        ),
      );
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'KI-Look gesetzt – Stärke, Neu erzeugen oder Entfernen unter '
            '„Hinzufügen & Hintergrund".',
          ),
          duration: Duration(seconds: 5),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(aiErrorMessage(e)),
          duration: const Duration(seconds: 6),
        ),
      );
    } finally {
      if (mounted) setState(() => _lookBusy = false);
    }
  }

  /// Ergebnis-Layout: „Standard" oder „Mit Foto" (ENDSTAND).
  Widget _resultLayoutToggle({VoidCallback? onChanged}) =>
      SegmentedButton<String>(
        segments: const [
          ButtonSegment(value: 'std', label: Text('Standard')),
          ButtonSegment(
            value: 'photo',
            label: Text('Mit Foto'),
            icon: Icon(Icons.photo),
          ),
        ],
        selected: {_resultLayout},
        showSelectedIcon: false,
        onSelectionChanged: (s) {
          setState(() {
            _resultLayout = s.first;
            _posterSel = null; // andere Objekte im anderen Layout
          });
          onChanged?.call();
        },
      );

  /// ENDSTAND: Regler „Foto-Größe" (50–300 %) + Ausschnitt zurücksetzen.
  /// [refresh] aktualisiert zusätzlich ein offenes Sheet.
  Widget _ftPhotoScaleControls({VoidCallback? refresh}) {
    final scale = _ftCtrl.value.getMaxScaleOnAxis().clamp(0.5, 3.0).toDouble();
    return Row(
      children: [
        const Text('Foto-Größe', style: TextStyle(fontSize: 12)),
        Expanded(
          child: Slider(
            value: scale,
            min: 0.5,
            max: 3.0,
            onChanged: (v) {
              setState(() => _setFtScale(v));
              refresh?.call();
            },
          ),
        ),
        SizedBox(
          width: 40,
          child: Text(
            '${(scale * 100).round()}%',
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 12),
          ),
        ),
        IconButton(
          tooltip: 'Ausschnitt zurücksetzen',
          icon: const Icon(Icons.restart_alt, size: 20),
          onPressed: () {
            setState(() {
              _ftCtrl.value = Matrix4.identity();
              _ftMatrixF.remove(_designKey);
            });
            refresh?.call();
          },
        ),
      ],
    );
  }

  /// ENDSTAND: Foto oben wählen/ändern/entfernen (je Format gespeichert). Freier
  /// Zuschnitt; den Ausschnitt legt der Nutzer im Editor per Ziehen/Zoomen fest.
  Future<void> _pickFtPhoto() async {
    final src0 = await _askPosterSource(
      hasExisting: _ftPhotoF[_designKey] != null,
      allowKader: false,
    );
    if (src0 == null || !mounted) return;
    if (src0 == 'remove') {
      setState(() {
        _ftPhotoF.remove(_designKey);
        _ftMatrixF.remove(_designKey);
      });
      _ftCtrl.value = Matrix4.identity();
      return;
    }
    final src = await _resolveGoogleSource(src0);
    if (src == null || !mounted) return;
    final url = await _pickImage(
      asBackground: true,
      source: src == 'camera' ? ImageSource.camera : ImageSource.gallery,
      edit: true,
    );
    if (url == null || !mounted) return;
    setState(() {
      _ftPhotoF[_designKey] = url;
      _ftMatrixF.remove(_designKey); // neues Foto → Ausschnitt neu
    });
    _ftCtrl.value = Matrix4.identity();
  }

  /// Bildleiste „KI-Hintergrund": Aus + die letzten KI-Hintergründe; Antippen
  /// schaltet für das aktuelle Format um, ✕ löscht einen aus dem Verlauf.
  Widget _aiBgStrip(BuildContext ctx, void Function(VoidCallback) setSheet) {
    final sel = _aiBgSel;
    final scheme = Theme.of(ctx).colorScheme;
    final aspect = _cw / _ch;
    const h = 92.0;
    final w = h * aspect;
    Widget tile({
      required bool selected,
      required Widget child,
      required VoidCallback onTap,
      VoidCallback? onDelete,
    }) => Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          GestureDetector(
            onTap: onTap,
            child: Container(
              width: w,
              height: h,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: selected ? scheme.primary : Colors.black26,
                  width: selected ? 3 : 1,
                ),
              ),
              child: child,
            ),
          ),
          if (onDelete != null)
            Positioned(
              right: -6,
              top: -6,
              child: InkWell(
                onTap: onDelete,
                customBorder: const CircleBorder(),
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: const BoxDecoration(
                    color: Colors.black54,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.close, size: 14, color: Colors.white),
                ),
              ),
            ),
        ],
      ),
    );

    void select(int? i) {
      setState(() => _aiBgSelF[_designKey] = i);
      setSheet(() {});
      _refreshBgDark();
    }

    Future<void> delete(int i) async {
      final ok = await showDialog<bool>(
        context: ctx,
        builder: (dctx) => AlertDialog(
          title: const Text('KI-Hintergrund löschen?'),
          content: const Text(
            'Er verschwindet aus dem Verlauf (in Story und Post).',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dctx, true),
              child: const Text('Löschen'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      setState(() => _removeAiBg(i));
      setSheet(() {});
      _refreshBgDark();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'KI-Hintergrund (${_story ? 'Story' : 'Post'})',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 2),
        const Text(
          'Antippen schaltet um – „Aus" zeigt den normalen Hintergrund. '
          'Die letzten 5 bleiben gespeichert.',
          style: TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: h + 8,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.only(top: 6, right: 6),
            children: [
              tile(
                selected: sel == null,
                onTap: () => select(null),
                child: ColoredBox(
                  color: scheme.surfaceContainerHighest,
                  child: const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.hide_image_outlined),
                        SizedBox(height: 2),
                        Text('Aus', style: TextStyle(fontSize: 12)),
                      ],
                    ),
                  ),
                ),
              ),
              for (var i = 0; i < _aiBgs.length; i++)
                tile(
                  selected: sel == i,
                  onTap: () => select(i),
                  onDelete: () => delete(i),
                  child: Image.memory(
                    TeamLogo.decode(_aiBgs[i]) ?? Uint8List(0),
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    errorBuilder: (_, _, _) => const Icon(Icons.broken_image),
                  ),
                ),
              if (context.read<AppState>().canAiImage)
                tile(
                  selected: false,
                  onTap: () {
                    _closePanel();
                    _aiEdit();
                  },
                  child: ColoredBox(
                    color: scheme.primaryContainer,
                    child: const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.auto_awesome),
                          SizedBox(height: 2),
                          Text(
                            'Neu mit KI',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// Neuen KI-Hintergrund vorne in den Verlauf (max. 5) und fürs aktuelle
  /// Format einschalten. Auswahlen anderer Formate rücken mit.
  void _pushAiBg(String url) {
    _aiBgs.insert(0, url);
    for (final k in _aiBgSelF.keys.toList()) {
      final v = _aiBgSelF[k];
      if (v != null) _aiBgSelF[k] = v + 1;
    }
    while (_aiBgs.length > _kMaxAiBgs) {
      final gone = _aiBgs.length - 1;
      _aiBgs.removeLast();
      _aiBgSelF.updateAll((_, v) => v == gone ? null : v);
    }
    _aiBgSelF[_designKey] = 0;
  }

  /// KI-Hintergrund [i] aus dem Verlauf löschen (Auswahlen anpassen).
  void _removeAiBg(int i) {
    if (i < 0 || i >= _aiBgs.length) return;
    _aiBgs.removeAt(i);
    _aiBgSelF.updateAll(
      (_, v) => v == null || v == i ? null : (v > i ? v - 1 : v),
    );
  }

  /// Die Vorschau-/Canvas-Fläche (feste logische Größe). [interactive]=true →
  /// Elemente antippen/ziehen (im Vollbild-Editor). [interactive]=false am
  /// Hauptscreen: bei der Ankündigung nicht fummelig – Tippen öffnet stattdessen
  /// den Editor (Spieler-Ebene ignoriert Gesten).
  Widget _previewStack({required bool interactive}) {
    // Hintergrund gewechselt (egal wo) → Licht/Logo-Variante neu bestimmen.
    if ((_photoBg ?? _settings.bgImage) != _bgDarkFor) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _refreshBgDark();
      });
    }
    final w = _cw;
    final h = _ch;
    final look = _look;
    final lookBytes = look?.bytes;
    final mainGraphic = RepaintBoundary(
      key: _boundaryKey,
      // KI-Look liegt ÜBER allem (auch im Export), fängt aber keine Gesten ab.
      // Die Grafik bleibt immer Kind 0 → wird beim Ein-/Ausblenden nicht neu
      // aufgebaut.
      child: Stack(
        fit: StackFit.expand,
        children: [
          _gradeWrap(_graphic()),
          if (look != null && lookBytes != null)
            IgnorePointer(
              child: Opacity(
                opacity: look.opacity.clamp(0.1, 1.0),
                child: Image.memory(
                  lookBytes,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                ),
              ),
            ),
        ],
      ),
    );
    // Alle editierbaren Grafiktypen öffnen beim Tippen den Vollbild-Editor;
    // der Band-Foto-Zoom lebt dann im Editor (interactive).
    final lockForTap = _editable && !interactive;
    final stack = SizedBox(
      width: w,
      height: h,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Verdeckte Hintergrund-Ebene (nur Verlauf/Foto) für „Nur Hintergrund".
          RepaintBoundary(
            key: _bgBoundaryKey,
            child: _graphic(backgroundOnly: true),
          ),
          lockForTap ? IgnorePointer(child: mainGraphic) : mainGraphic,
          if (_aiBusy || _bgBusy) _busyOverlay(_busyText ?? 'Bitte warten …'),
          if (_videoBusy) _videoOverlay(),
          if (_aiPick != null && !interactive) _aiPickLayer(),
          if (_guideX != null || _guideY != null) _guideLayer(),
        ],
      ),
    );
    return stack;
  }

  /// Abgedunkelte Fläche mit Kreisel + Text über dem Canvas, solange KI bzw.
  /// Bildbearbeitung läuft (blockiert Eingaben, liegt NICHT im Export).
  Widget _busyOverlay(String text) {
    return Positioned.fill(
      child: AbsorbPointer(
        child: ColoredBox(
          color: Colors.black.withValues(alpha: 0.45),
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 30,
                    height: 30,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    text,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (_aiBusy) ...[
                    const SizedBox(height: 4),
                    Text(
                      'dauert meist 10–30 Sekunden',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.75),
                        fontSize: 10.5,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Design dieses Formats komplett zurücksetzen (nach Rückfrage): entfernt alle
  /// hinzugefügten Bilder/Texte/Positionen/Finish; das Grundlayout bleibt.
  Future<void> _resetDesign() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Design zurücksetzen?'),
        content: const Text(
          'Alle hinzugefügten Bilder, Texte und Anpassungen dieses Formats '
          'werden entfernt. Das Grundlayout bleibt.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Zurücksetzen'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      final k = _designKey;
      _posterPosF.remove(k);
      _posCenteredF.remove(k);
      _stdOffF.remove(k);
      _stdHiddenF.remove(k);
      _lookF.remove(k);
      _photos.clear(); // hinzugefügte Fotos gehören zum Design
      _boxSizeF.remove(k);
      _ftPhotoF.remove(k);
      _ftMatrixF.remove(k);
      _ftSplitF.remove(k);
      _ftCtrl.value = Matrix4.identity();
      _posterScaleF.remove(k);
      _posterRotF.remove(k);
      _posterOrderF.remove(k);
      _posterMainF.remove(k);
      _posterOverlaysF.remove(k);
      _textIdsF.remove(k);
      _textContentF.remove(k);
      _textFontF.remove(k);
      _textColorF.remove(k);
      _textShadowF.remove(k);
      _textAlignF.remove(k);
      _imgOrigF.remove(k);
      _imgFeatherF.remove(k);
      _imgInnerF.remove(k);
      _imgRimF.remove(k);
      _gradeF.remove(k);
      _posterSel = null;
    });
  }

  /// Vollbild-Editor: das Canvas nimmt (fast) den ganzen Schirm; der
  /// „Hinzufügen & Hintergrund"-Button schwebt als FAB darüber. Hinzufügen geht
  /// zusätzlich per Langdruck auf den Hintergrund, Objekt-Optionen per Langdruck.
  /// Editor-Zoom per Knopf: um die Mitte des sichtbaren Bereichs skalieren
  /// (1×–5×); 1× = ganz zurück (keine Verschiebung).
  void _zoomEditor(double factor, Size viewport) {
    final m = _editZoom.value;
    final cur = m.getMaxScaleOnAxis();
    final next = (cur * factor).clamp(1.0, 5.0);
    if (next <= 1.0001) {
      _editZoom.value = Matrix4.identity();
    } else {
      final c = _editZoom.toScene(viewport.center(Offset.zero));
      final f = next / cur;
      _editZoom.value = m.clone()
        ..translateByDouble(c.dx, c.dy, 0, 1)
        ..scaleByDouble(f, f, 1, 1)
        ..translateByDouble(-c.dx, -c.dy, 0, 1);
    }
    setState(() => _editZoomed = next > 1.0001);
  }

  // =================================================================== Studio
  // Ein Vollbild-Editor fürs Handy: Grafik so groß wie möglich, unten eine
  // Werkzeugleiste (bzw. Kontextleiste fürs gewählte Element). Einstellungen
  // öffnen sich in einem flachen, NICHT modalen Panel – die Grafik schrumpft
  // darüber und bleibt komplett sichtbar.

  String? _panelKey;
  String _panelTitle = '';
  Widget Function(BuildContext, StateSetter)? _panelBuilder;
  VoidCallback? _panelOnClose;
  bool _panelBig = false;

  void _openPanel(
    String key,
    String title,
    Widget Function(BuildContext, StateSetter) builder, {
    VoidCallback? onClose,
  }) {
    final prev = _panelOnClose;
    _panelOnClose = null;
    prev?.call();
    if (!mounted) return;
    setState(() {
      _panelKey = key;
      _panelTitle = title;
      _panelBuilder = builder;
      _panelOnClose = onClose;
    });
  }

  void _closePanel() {
    final prev = _panelOnClose;
    _panelOnClose = null;
    prev?.call();
    if (!mounted || _panelBuilder == null) return;
    setState(() {
      _panelKey = null;
      _panelBuilder = null;
    });
  }

  /// Auswahl ändern. Ein offenes Element-Panel wandert mit (gleicher
  /// Abschnitt), ein Werkzeug-Panel schließt beim Wählen eines Elements.
  void _selectElement(String? id) {
    if (id == _posterSel) return;
    final k = _panelKey;
    setState(() => _posterSel = id);
    if (k == null) return;
    if (id == null) {
      if (k.startsWith('el:')) _closePanel();
    } else if (k.startsWith('el:')) {
      _showElementProperties(id, k.split(':').last);
    } else {
      _closePanel();
    }
  }

  /// Letzte Tipp-Stelle (Canvas) – für „nochmal tippen = darunter".
  Offset? _lastTapPos;

  void _onPosterTap(List<String> hits, Offset p) {
    if (hits.isEmpty) return;
    var id = hits.first;
    final sel = _posterSel;
    final last = _lastTapPos;
    if (sel != null &&
        hits.contains(sel) &&
        last != null &&
        (last - p).distance < 14) {
      id = hits[(hits.indexOf(sel) + 1) % hits.length];
    }
    _lastTapPos = p;
    _selectElement(id);
  }

  /// Werkzeug der unteren Leiste öffnen (nochmal tippen = schließen).
  void _toggleTool(String key) {
    if (_panelKey == 'tool:$key') {
      _closePanel();
      return;
    }
    final state = context.read<AppState>();
    switch (key) {
      case 'add':
        _openPanel(
          'tool:add',
          'Elemente',
          _elementsPanel,
          onClose: () => _saveSettingsIfDirty(state),
        );
      case 'bg':
        _openCustomize('bg');
      case 'club':
        _openCustomize('club');
      case 'look':
        _openPanel(
          'tool:look',
          'Look',
          _lookPanel,
          onClose: () => _saveSettingsIfDirty(state),
        );
      case 'anim':
        _openPanel(
          'tool:anim',
          'Bewegung (Video für Instagram)',
          (ctx, setSheet) => ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [_animControls(panel: true)],
          ),
        );
      case 'ai':
        _openPanel('tool:ai', 'KI', _aiPanel);
    }
  }

  // Teamweite Grafik-Einstellungen aus Elemente/Look: beim Schließen sichern.
  bool _settingsDirty = false;

  void _applySettings(GraphicSettings s) {
    setState(() => _settings = s);
    _settingsDirty = true;
    _refreshBgDark();
  }

  void _saveSettingsIfDirty(AppState state) {
    if (!_settingsDirty) return;
    _settingsDirty = false;
    _saveCustomize(state);
  }

  // ------------------------------------------------- Panel-Bausteine
  /// ⓘ: Erklärung beim Antippen (Tooltip).
  Widget _infoIcon(String text) => Tooltip(
    message: text,
    triggerMode: TooltipTriggerMode.tap,
    showDuration: const Duration(seconds: 6),
    preferBelow: false,
    child: Padding(
      padding: const EdgeInsets.all(6),
      child: Icon(
        Icons.info_outline,
        size: 18,
        color: Theme.of(context).hintColor,
      ),
    ),
  );

  /// Einheitliche Abschnittsüberschrift im Panel (optional mit ⓘ).
  /// Kennzeichen „Team“: Option gilt für alle Grafiken des Teams.
  Widget _teamBadge() {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message:
          'Gilt für alle Grafiken des Teams – auch bei den anderen Trainern. '
          'Rückgängig geht wie gewohnt.',
      triggerMode: TooltipTriggerMode.tap,
      showDuration: const Duration(seconds: 6),
      child: Container(
        margin: const EdgeInsets.only(left: 6),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: scheme.tertiaryContainer,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.groups, size: 13, color: scheme.onTertiaryContainer),
            const SizedBox(width: 3),
            Text(
              'Team',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: scheme.onTertiaryContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _secHead(
    String title, {
    String? info,
    bool first = false,
    bool team = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(top: first ? 2 : 16, bottom: 4),
      child: Row(
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: scheme.primary,
            ),
          ),
          if (team) _teamBadge(),
          if (info != null) _infoIcon(info),
          const SizedBox(width: 8),
          Expanded(child: Divider(color: scheme.outlineVariant)),
        ],
      ),
    );
  }

  /// Schalter-Zeile mit optionalem ⓘ (kompakt, ohne Untertitel-Wust).
  Widget _switchRow(
    String title,
    bool value,
    ValueChanged<bool>? onChanged, {
    String? info,
    bool team = false,
  }) => Row(
    children: [
      Flexible(child: Text(title, style: const TextStyle(fontSize: 14))),
      if (team) _teamBadge(),
      if (info != null) _infoIcon(info),
      const Spacer(),
      Switch(value: value, onChanged: onChanged),
    ],
  );

  IconData _elementIcon(String id) {
    if (_isTextEl(id) || id == 'headline' || id == 'std_title') {
      return Icons.text_fields;
    }
    if (id == 'player') return Icons.person;
    if (id.contains('sponsor')) return Icons.handshake_outlined;
    if (id.contains('logo') || id == 'logos') return Icons.shield_outlined;
    if (id.contains('score') || id.contains('banner')) return Icons.scoreboard;
    if (id.contains('lineup')) return Icons.groups_outlined;
    if (id.contains('scorers')) return Icons.sports_soccer;
    return Icons.image_outlined;
  }

  /// Alle gerade sichtbaren Teile der Grafik, oberstes zuerst.
  List<String> _visibleElements() {
    bool shown(String id) => _stdCtx[id]?.mounted ?? false;
    return [
      for (final id in _posterOrder.reversed)
        if (shown(id)) id,
      for (final id in _kStdOrder)
        if (!_stdHidden.contains(id) && shown(id)) id,
    ];
  }

  /// Reiter „Elemente": hinzufügen + Liste aller Teile (Auge = aus/ein).
  Widget _elementsPanel(BuildContext ctx, StateSetter setSheet) {
    final scheme = Theme.of(ctx).colorScheme;
    Widget addBtn(IconData icon, String label, VoidCallback onTap) => Expanded(
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        ),
        onPressed: () {
          _closePanel();
          onTap();
        },
        child: Column(
          children: [
            Icon(icon, size: 22),
            const SizedBox(height: 2),
            FittedBox(fit: BoxFit.scaleDown, child: Text(label)),
          ],
        ),
      ),
    );
    final visible = _visibleElements();
    final hidden = _hiddenItems;
    Widget row(String id, {required bool isHidden}) {
      final userMade = id.startsWith('overlay_') || id.startsWith('text_');
      final label = _pickLabel(id);
      return ListTile(
        dense: true,
        contentPadding: const EdgeInsets.only(left: 4),
        leading: Icon(
          _elementIcon(id),
          color: isHidden ? scheme.outline : scheme.primary,
        ),
        title: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: isHidden ? scheme.outline : null),
        ),
        selected: _posterSel == id,
        onTap: isHidden ? null : () => _selectElement(id),
        trailing: isHidden
            ? IconButton(
                tooltip: 'Einblenden',
                icon: const Icon(Icons.visibility_off_outlined),
                onPressed: () => _restoreHiddenItem(id),
              )
            : (userMade || id == 'player')
            ? IconButton(
                tooltip: 'Entfernen',
                icon: Icon(Icons.delete_outline, color: scheme.error),
                onPressed: () => _removePosterItem(id),
              )
            : IconButton(
                tooltip: 'Ausblenden',
                icon: const Icon(Icons.visibility_outlined),
                onPressed: () => _removePosterItem(id),
              ),
      );
    }

    final s = _settings;
    final hasMain = _mainSponsor != null;
    final hasBar = _barSponsors.isNotEmpty;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        _secHead('Hinzufügen', first: true),
        Row(
          children: [
            addBtn(Icons.text_fields, 'Text', _addPosterText),
            const SizedBox(width: 8),
            addBtn(Icons.add_photo_alternate, 'Bild/Logo', _addPosterOverlay),
            const SizedBox(width: 8),
            addBtn(Icons.person, 'Spielerfoto', _addPosterMain),
          ],
        ),
        if (_isFupa) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: _aiBusy
                      ? null
                      : () {
                          _closePanel();
                          _fupaTakePhoto();
                        },
                  icon: const Icon(Icons.photo_camera),
                  label: const Text('Foto + freistellen'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: _sharing || _posterMain == null
                      ? null
                      : _fupaAdoptAsPlayerPhoto,
                  icon: const Icon(Icons.how_to_reg),
                  label: const Text('Ins Profil'),
                ),
              ),
            ],
          ),
        ],
        _secHead(
          'In der Grafik',
          info:
              'Antippen wählt das Teil aus. Das Auge blendet es aus oder '
              'wieder ein; selbst hinzugefügte Texte und Bilder werden über '
              'den Papierkorb entfernt.',
        ),
        for (final id in visible) row(id, isHidden: false),
        for (final id in hidden) row(id, isHidden: true),
        if (visible.isEmpty && hidden.isEmpty)
          const Text('Noch nichts in der Grafik.'),
        if (hasMain || hasBar) ...[
          _secHead('Sponsoren'),
          if (hasMain) ...[
            _switchRow(
              'Hauptsponsor',
              _showMainSponsor,
              (v) => setState(() => _showMainSponsor = v),
            ),
            if (_showMainSponsor)
              Row(
                children: [
                  const Text('Zeigen als', style: TextStyle(fontSize: 13)),
                  const SizedBox(width: 10),
                  ChoiceChip(
                    label: const Text('Logo'),
                    selected: _mainSponsorMode == 'logo',
                    onSelected: (_) =>
                        setState(() => _mainSponsorMode = 'logo'),
                  ),
                  const SizedBox(width: 6),
                  ChoiceChip(
                    label: const Text('Text'),
                    selected: _mainSponsorMode == 'text',
                    onSelected: (_) =>
                        setState(() => _mainSponsorMode = 'text'),
                  ),
                ],
              ),
          ],
          if (hasBar)
            _switchRow(
              'Weitere Sponsoren (Logo-Reihe)',
              _showOtherSponsors,
              (v) => setState(() => _showOtherSponsors = v),
            ),
        ],
        if (widget.opponentLogo != null || widget.isResult) ...[
          _secHead('Weitere Inhalte', team: true),
          if (widget.opponentLogo != null)
            _switchRow(
              'Gegner-Logo',
              s.showOpponentLogo,
              (v) => _applySettings(s.copyWith(showOpponentLogo: v)),
              info: 'Logo des Gegners neben „vs …". Gilt für alle Grafiken.',
            ),
          if (widget.isResult) ...[
            _switchRow(
              'Torschützen',
              s.showScorers,
              (v) => _applySettings(s.copyWith(showScorers: v)),
              info: 'Liste der Tore mit Spieler und Minute.',
            ),
            _switchRow(
              'Spielerfotos bei den Toren',
              s.showPhotos,
              (v) => _applySettings(s.copyWith(showPhotos: v)),
            ),
          ],
        ],
      ],
    );
  }

  /// Reiter „Look": Schrift, Akzentfarbe, Logos, Schatten, Filter.
  Widget _lookPanel(BuildContext ctx, StateSetter setSheet) {
    final s = _settings;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        _secHead(
          'Schrift',
          first: true,
          info:
              'Grundschrift der Grafik. Einzelne Texte änderst du direkt: '
              'Text antippen → Stil.',
        ),
        DropdownButton<String>(
          isExpanded: true,
          value: _posterFont,
          items: [
            for (final e in _kPosterFonts.entries)
              DropdownMenuItem(
                value: e.key,
                child: Text(
                  e.value,
                  style: posterFontStyle(
                    e.key,
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
          ],
          onChanged: (v) => setState(() => _posterFont = v ?? 'standard'),
        ),
        _secHead(
          'Akzentfarbe',
          team: true,
          info: 'Farbe für Linien, „vs", Spielstand und Datum.',
        ),
        _swatches(
          selected: s.accent ?? '#FFFFFF',
          palette: _accentPalette,
          allowFree: true,
          onPick: (hex) => _applySettings(
            hex == '#FFFFFF'
                ? s.copyWith(clearAccent: true)
                : s.copyWith(accent: hex),
          ),
        ),
        _secHead('Logos', team: true),
        Row(
          children: [
            const Text('Form', style: TextStyle(fontSize: 14)),
            const SizedBox(width: 12),
            ChoiceChip(
              label: const Text('Eckig'),
              selected: s.logoShape != 'circle',
              onSelected: (_) =>
                  _applySettings(s.copyWith(logoShape: 'rounded')),
            ),
            const SizedBox(width: 8),
            ChoiceChip(
              label: const Text('Rund'),
              selected: s.logoShape == 'circle',
              onSelected: (_) =>
                  _applySettings(s.copyWith(logoShape: 'circle')),
            ),
          ],
        ),
        if (widget.isAnnouncement)
          _switchRow(
            'Auf hellem Kreis',
            _posterLogoDisc,
            (v) => setState(() => _posterLogoDisc = v),
            info:
                'Legt die Vereinslogos auf einen hellen Kreis – gut '
                'lesbar auf dunklem Hintergrund.',
          ),
        _secHead(
          'Schatten',
          info:
              'Schlagschatten hinter Spieler und eingefügten Bildern. Wirkt '
              'am besten bei freigestellten Bildern.',
        ),
        _switchRow(
          'Schatten anzeigen',
          _posterShadow,
          (v) => setState(() => _posterShadow = v),
        ),
        if (_posterShadow) ...[
          Row(
            children: [
              const SizedBox(width: 60, child: Text('Stärke')),
              Expanded(
                child: Slider(
                  value: _posterShadowStrength,
                  min: 0,
                  max: 100,
                  onChanged: (v) => setState(() => _posterShadowStrength = v),
                ),
              ),
            ],
          ),
          Row(
            children: [
              const SizedBox(width: 60, child: Text('Winkel')),
              Expanded(
                child: Slider(
                  value: _posterShadowAngle,
                  min: 0,
                  max: 360,
                  divisions: 72,
                  label: '${_posterShadowAngle.round()}°',
                  onChanged: (v) => setState(() => _posterShadowAngle = v),
                ),
              ),
            ],
          ),
        ],
        if (!_isFupa)
          _switchRow(
            'Spielerfoto weich einblenden',
            _posterBlend,
            (v) => setState(() => _posterBlend = v),
            info:
                'Das Spielerfoto geht randlos mit weichem Übergang in den '
                'Hintergrund über (nur bei Fotos ohne Freistellung).',
          ),
        _secHead(
          'Filter & Farben',
          info:
              'Wirkt wie ein Foto-Filter auf die ganze Grafik – Inhalte '
              'bleiben unverändert. Erst eine Vorlage wählen, dann bei '
              'Bedarf nachregeln.',
        ),
        _gradeControls(panel: true),
      ],
    );
  }

  /// Reiter „KI": alles mit KI an einem Ort.
  Widget _aiPanel(BuildContext ctx, StateSetter setSheet) {
    final app = context.watch<AppState>();
    final canGemini = app.canAiImage, canClaude = app.canAiCoach;
    final busy = _aiBusy || _videoBusy || _sharing || _gradeBusy;
    final hint = TextStyle(fontSize: 12, color: Theme.of(ctx).hintColor);
    const off = 'Für dich nicht freigeschaltet (Admin fragen).';
    Widget action(
      IconData icon,
      String title,
      String info,
      VoidCallback? onTap, {
      bool allowed = true,
      bool primary = false,
    }) {
      final btn = primary
          ? FilledButton.icon(
              onPressed: allowed && !busy ? onTap : null,
              icon: Icon(icon),
              label: Text(title),
            )
          : OutlinedButton.icon(
              onPressed: allowed && !busy ? onTap : null,
              icon: Icon(icon),
              label: Text(title),
            );
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          children: [
            Expanded(child: btn),
            _infoIcon(allowed ? info : '$info\n\n$off'),
          ],
        ),
      );
    }

    final anim = _format != 'f';
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        _secHead('Bild', first: true),
        action(
          Icons.auto_awesome,
          'Ganzes Bild neu gestalten',
          'Gemini gestaltet aus deiner Grafik ein neues Bild. Du siehst '
              'zuerst eine Vorschau und entscheidest dann.',
          () {
            _closePanel();
            _aiEdit();
          },
          allowed: canGemini,
        ),
        action(
          Icons.tune,
          'Filter automatisch einstellen',
          'Claude schaut sich die Grafik an und stellt „Filter & Farben" '
              'passend ein (unter Look nachregelbar).',
          _aiFinish,
          allowed: canClaude,
        ),
        if (anim) ...[
          _secHead(
            'Bewegung',
            info:
                'Die KI animiert Elemente für ein Instagram-Video. Du tippst '
                'vorher an, welche Elemente sie bewegen soll.',
          ),
          if (canClaude && canGemini)
            Row(
              children: [
                const Text('KI', style: TextStyle(fontSize: 13)),
                const SizedBox(width: 10),
                SegmentedButton<String>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 'claude', label: Text('Claude')),
                    ButtonSegment(value: 'gemini', label: Text('Gemini')),
                  ],
                  selected: {_aiAnimProvider},
                  onSelectionChanged: (v) =>
                      setState(() => _aiAnimProvider = v.first),
                ),
              ],
            ),
          const SizedBox(height: 6),
          action(
            Icons.animation,
            'Elemente animieren lassen',
            'Du wählst Elemente aus, die KI gibt ihnen passende '
                'Bewegungen. Die übrigen behalten ihre Einstellung.',
            () => _startAiPick('effects'),
            allowed: canClaude || canGemini,
          ),
          action(
            Icons.movie_creation_outlined,
            VideoEncoder.isSupported && canGemini
                ? 'Alles mit KI (inkl. Video)'
                : 'Alles mit KI animieren',
            'Animiert die gewählten Elemente, erzeugt bei Bedarf einen '
            'bewegten Hintergrund und macht direkt das Video zum Teilen.',
            () => _startAiPick('all'),
            allowed: canClaude || canGemini,
            primary: true,
          ),
          action(
            Icons.videocam_outlined,
            'Bewegter KI-Hintergrund',
            'Gemini macht aus dem Bild ein kurzes Video. Schrift und Logos '
                'bleiben scharf darüber. Kostet Google-Guthaben, dauert '
                '1–3 Minuten.',
            _askAiVideo,
            allowed: canGemini && VideoEncoder.isSupported,
          ),
          if (!VideoEncoder.isSupported)
            Text('Videos gibt es nur in der Android-App.', style: hint),
        ],
        if (canGemini) ...[
          _secHead(
            'Deko-Ebene',
            info:
                'Die KI malt Effekte (z. B. Licht, Rauch, Funken) als Ebene '
                'über die Grafik. Deine Inhalte bleiben unverändert.',
          ),
          _lookSection(ctx, setSheet),
        ],
      ],
    );
  }

  /// FuPa: Bild-Hintergrund oder Vereinsverlauf.
  Widget _fupaBgToggle() => SizedBox(
    width: double.infinity,
    child: SegmentedButton<String>(
      segments: const [
        ButtonSegment(
          value: 'image',
          icon: Icon(Icons.image_outlined),
          label: Text('Bild'),
        ),
        ButtonSegment(
          value: 'club',
          icon: Icon(Icons.gradient),
          label: Text('Vereinsverlauf'),
        ),
      ],
      selected: {_fupaBgVar},
      showSelectedIcon: false,
      onSelectionChanged: (v) => _switchFupaBg(v.first),
    ),
  );

  // ------------------------------------------------------------- Leisten
  Widget _barContent(
    IconData icon,
    String label, {
    bool active = false,
    bool danger = false,
    bool enabled = true,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final color = !enabled
        ? scheme.onSurface.withValues(alpha: 0.38)
        : danger
        ? scheme.error
        : active
        ? scheme.onSecondaryContainer
        : scheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
            decoration: BoxDecoration(
              color: active ? scheme.secondaryContainer : null,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(icon, size: 22, color: color),
          ),
          const SizedBox(height: 3),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              label,
              maxLines: 1,
              style: TextStyle(
                fontSize: 11.5,
                color: color,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _barBtn(
    IconData icon,
    String label,
    VoidCallback? onTap, {
    bool active = false,
    bool danger = false,
  }) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(12),
    child: _barContent(
      icon,
      label,
      active: active,
      danger: danger,
      enabled: onTap != null,
    ),
  );

  /// Knopfreihe: Knöpfe teilen sich die Breite (Labels verkleinern sich
  /// notfalls statt abgeschnitten zu werden).
  Widget _barRow(List<Widget> items) => SizedBox(
    height: 64,
    child: Row(children: [for (final i in items) Expanded(child: i)]),
  );

  Widget _toolBar() {
    final tools = <(String, String, IconData)>[
      ('add', 'Elemente', Icons.category_outlined),
      ('bg', 'Hintergrund', Icons.wallpaper_outlined),
      ('look', 'Look', Icons.palette_outlined),
      if (_format != 'f') ('anim', 'Bewegung', Icons.movie_filter_outlined),
      ('ai', 'KI', Icons.auto_awesome),
    ];
    return _barRow([
      for (final t in tools)
        _barBtn(
          t.$3,
          t.$2,
          () => _toggleTool(t.$1),
          active: _panelKey == 'tool:${t.$1}',
        ),
    ]);
  }

  /// Kontextleiste fürs gewählte Element: Fertig, Abschnitte, ⋯ Mehr.
  Widget _contextBar(String id) {
    final isStd = id.startsWith('std_');
    return _barRow([
      _barBtn(Icons.check, 'Fertig', () {
        _closePanel();
        setState(() => _posterSel = null);
      }),
      for (final s in _elementSections(id))
        _barBtn(
          s.$3,
          s.$2,
          () => _panelKey == 'el:$id:${s.$1}'
              ? _closePanel()
              : _showElementProperties(id, s.$1),
          active: _panelKey == 'el:$id:${s.$1}',
        ),
      PopupMenuButton<String>(
        tooltip: 'Mehr',
        onSelected: (v) {
          switch (v) {
            case 'front':
              _reorderPoster(id, 1);
            case 'back':
              _reorderPoster(id, -1);
            case 'copy':
              _copyElementToOther(id);
            case 'remove':
              _closePanel();
              _removePosterItem(id);
          }
        },
        itemBuilder: (_) {
          PopupMenuItem<String> item(String v, IconData i, String t) =>
              PopupMenuItem(
                value: v,
                child: Row(
                  children: [
                    Icon(
                      i,
                      size: 20,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 12),
                    Text(t),
                  ],
                ),
              );
          return [
            if (!isStd) ...[
              item('front', Icons.flip_to_front, 'Nach vorne'),
              item('back', Icons.flip_to_back, 'Nach hinten'),
            ],
            if (_canCopyFormats)
              item(
                'copy',
                Icons.copy_all,
                'In ${_formatName(_otherFormat)} kopieren',
              ),
            item(
              'remove',
              id.startsWith('overlay_') || id.startsWith('text_')
                  ? Icons.delete_outline
                  : Icons.visibility_off_outlined,
              _removeLabel(id),
            ),
          ];
        },
        child: _barContent(Icons.more_horiz, 'Mehr'),
      ),
    ]);
  }

  /// Das flache Panel (unten bzw. rechts auf breiten Fenstern).
  Widget _panelHost({required bool side}) {
    final b = _panelBuilder;
    if (b == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    void toggleBig() => setState(() => _panelBig = !_panelBig);
    return Material(
      color: scheme.surface,
      elevation: 8,
      child: Column(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: side ? null : toggleBig,
            onVerticalDragEnd: side
                ? null
                : (d) {
                    final v = d.primaryVelocity ?? 0;
                    if (v < -150 && !_panelBig) {
                      toggleBig();
                    } else if (v > 150) {
                      _panelBig ? toggleBig() : _closePanel();
                    }
                  },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 4, 0),
              child: Column(
                children: [
                  if (!side)
                    Container(
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.only(top: 2),
                      decoration: BoxDecoration(
                        color: scheme.outlineVariant,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _panelTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (!side)
                        IconButton(
                          tooltip: _panelBig ? 'Kleiner' : 'Größer',
                          icon: Icon(
                            _panelBig ? Icons.expand_more : Icons.expand_less,
                          ),
                          onPressed: toggleBig,
                        ),
                      IconButton(
                        tooltip: 'Schließen',
                        icon: const Icon(Icons.close),
                        onPressed: _closePanel,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: StatefulBuilder(key: ValueKey(_panelKey), builder: b),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ Kopfzeile
  String get _screenTitle => widget.designer != null
      ? (_designerTitle.isEmpty
            ? widget.designer!.templateLabel
            : _designerTitle)
      : widget.isAnnouncement
      ? 'Spielankündigung'
      : widget.isResult
      ? 'Ergebnis-Grafik'
      : 'Startelf-Grafik';

  void _setFormat(String f) {
    if (f == _format) return;
    _closePanel();
    _stopAnim();
    setState(() {
      _format = f;
      _posterSel = null;
    });
    _syncFtCtrl(); // Foto-Ausschnitt des anderen Formats laden
  }

  Widget _formatMenu(Color fg) {
    final label = _isFupa ? '4:5' : (_story ? '9:16' : '1:1');
    final iconColor = Theme.of(context).colorScheme.onSurfaceVariant;
    // Alle Zeilen gleich aufgebaut: Symbol-Spalte (24 px) + Text → bündig.
    Widget item(IconData? i, String t, {bool bold = false}) => Row(
      children: [
        SizedBox(
          width: 24,
          // Feste Farbe: sonst erbt das Symbol das Weiß der Kopfzeile.
          child: i == null ? null : Icon(i, size: 20, color: iconColor),
        ),
        const SizedBox(width: 14),
        Text(
          t,
          style: bold ? const TextStyle(fontWeight: FontWeight.w700) : null,
        ),
      ],
    );
    return PopupMenuButton<String>(
      tooltip: 'Format & mehr',
      onSelected: (v) {
        switch (v) {
          case 's' || 'p':
            _setFormat(v);
          case 'copy':
            _copyDesignFromOther();
          case 'club':
            _toggleTool('club');
          case 'rename':
            _renameDesign();
          case 'reset':
            _resetDesign();
        }
      },
      itemBuilder: (_) => [
        if (!_isFupa) ...[
          PopupMenuItem(
            value: 's',
            child: item(
              _format == 's' ? Icons.check : null,
              'Story 9:16',
              bold: _format == 's',
            ),
          ),
          PopupMenuItem(
            value: 'p',
            child: item(
              _format == 'p' ? Icons.check : null,
              'Post 1:1',
              bold: _format == 'p',
            ),
          ),
          if (_canCopyFormats)
            PopupMenuItem(
              value: 'copy',
              child: item(
                Icons.copy_all,
                'Aus ${_formatName(_otherFormat)} übernehmen',
              ),
            ),
          const PopupMenuDivider(),
        ],
        if (!_isFupa)
          PopupMenuItem(
            value: 'club',
            child: item(Icons.shield_outlined, 'Vereinsdaten (Name, Logos)'),
          ),
        if (widget.designer != null)
          PopupMenuItem(
            value: 'rename',
            child: item(Icons.drive_file_rename_outline, 'Umbenennen'),
          ),
        PopupMenuItem(
          value: 'reset',
          child: item(Icons.restart_alt, 'Design zurücksetzen'),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(color: fg, fontWeight: FontWeight.w700),
            ),
            Icon(Icons.arrow_drop_down, color: fg),
          ],
        ),
      ),
    );
  }

  /// „Teilen" oben: WhatsApp, Instagram-Video, Bild/Hintergrund speichern.
  void _showShareMenu() {
    final canVideo = _format != 'f' && _anim.isActive;
    void go(BuildContext ctx, VoidCallback f) {
      Navigator.pop(ctx);
      f();
    }

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.share),
              title: const Text('Teilen (WhatsApp)'),
              subtitle: const Text('Als Bild'),
              onTap: () => go(ctx, _share),
            ),
            if (_format != 'f')
              ListTile(
                leading: const Icon(Icons.movie_outlined),
                title: const Text('Als Video teilen (Instagram)'),
                subtitle: Text(
                  !VideoEncoder.isSupported
                      ? 'Nur in der Android-App'
                      : canVideo
                      ? 'MP4 mit Animation'
                      : 'Erst unter „Animation" eine Vorlage wählen',
                ),
                enabled: VideoEncoder.isSupported && canVideo && !_videoBusy,
                onTap: () => go(ctx, _exportVideo),
              ),
            ListTile(
              leading: const Icon(Icons.download),
              title: const Text('Bild speichern'),
              onTap: () => go(ctx, _saveImage),
            ),
            ListTile(
              leading: const Icon(Icons.wallpaper_outlined),
              title: const Text('Nur Hintergrund speichern'),
              onTap: () => go(ctx, _saveBackground),
            ),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _studioAppBar() {
    final theme = Theme.of(context);
    final fg = theme.appBarTheme.foregroundColor ?? theme.colorScheme.onPrimary;
    final narrow = MediaQuery.sizeOf(context).width < 420;
    final shareBusy = _sharing || _aiBusy || _videoBusy;
    return AppBar(
      titleSpacing: 0,
      title: GestureDetector(
        onTap: widget.designer != null ? _renameDesign : null,
        child: Text(
          _busyText ?? _screenTitle,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
      ),
      bottom: _busyText != null
          ? const PreferredSize(
              preferredSize: Size.fromHeight(3),
              child: LinearProgressIndicator(minHeight: 3),
            )
          : null,
      actions: [
        IconButton(
          tooltip: 'Rückgängig',
          icon: const Icon(Icons.undo),
          onPressed: _history.canUndo ? _undo : null,
        ),
        IconButton(
          tooltip: 'Wiederholen',
          icon: const Icon(Icons.redo),
          onPressed: _history.canRedo ? _redo : null,
        ),
        _formatMenu(fg),
        if (narrow)
          IconButton(
            tooltip: 'Teilen',
            icon: const Icon(Icons.share),
            onPressed: shareBusy ? null : _showShareMenu,
          )
        else
          TextButton.icon(
            onPressed: shareBusy ? null : _showShareMenu,
            style: TextButton.styleFrom(foregroundColor: fg),
            icon: const Icon(Icons.share, size: 18),
            label: const Text('Teilen'),
          ),
        const SizedBox(width: 4),
      ],
    );
  }

  // --------------------------------------------------------------- Canvas
  Widget _studioCanvas() => LayoutBuilder(
    builder: (context, c) {
      final viewport = Size(c.maxWidth, c.maxHeight);
      return Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              transformationController: _editZoom,
              minScale: 1,
              maxScale: 5,
              onInteractionEnd: (_) {
                final z = _editZoom.value.getMaxScaleOnAxis() > 1.0001;
                if (z != _editZoomed) setState(() => _editZoomed = z);
              },
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: SizedBox.expand(
                  child: FittedBox(
                    fit: BoxFit.contain,
                    child: _previewStack(interactive: _aiPick == null),
                  ),
                ),
              ),
            ),
          ),
          // Gewähltes Element größer/kleiner (links oben).
          if (_posterSel != null && _aiPick == null)
            Positioned(
              left: 8,
              top: 8,
              child: Material(
                color: Theme.of(
                  context,
                ).colorScheme.primaryContainer.withValues(alpha: 0.95),
                elevation: 2,
                borderRadius: BorderRadius.circular(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Auswahl größer',
                      icon: const Icon(Icons.add_circle_outline),
                      onPressed: () => _scalePoster(_posterSel!, 1.1),
                    ),
                    Text(
                      '${((_posterScale[_posterSel!] ?? 1.0) * 100).round()}%',
                      style: const TextStyle(fontSize: 11),
                    ),
                    IconButton(
                      tooltip: 'Auswahl kleiner',
                      icon: const Icon(Icons.remove_circle_outline),
                      onPressed: () => _scalePoster(_posterSel!, 1 / 1.1),
                    ),
                  ],
                ),
              ),
            ),
          // Zoom-Knöpfe (rechts oben).
          Positioned(
            right: 8,
            top: 8,
            child: Material(
              color: Theme.of(
                context,
              ).colorScheme.surface.withValues(alpha: 0.92),
              elevation: 2,
              borderRadius: BorderRadius.circular(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Vergrößern',
                    icon: const Icon(Icons.zoom_in),
                    onPressed: () => _zoomEditor(1.5, viewport),
                  ),
                  IconButton(
                    tooltip: 'Verkleinern',
                    icon: const Icon(Icons.zoom_out),
                    onPressed: _editZoomed
                        ? () => _zoomEditor(1 / 1.5, viewport)
                        : null,
                  ),
                  if (_editZoomed)
                    IconButton(
                      tooltip: 'Ganzes Bild',
                      icon: const Icon(Icons.fit_screen),
                      onPressed: () => _zoomEditor(0, viewport),
                    ),
                ],
              ),
            ),
          ),
        ],
      );
    },
  );

  Widget _buildStudio() {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    final sel = _posterSel;
    final scheme = Theme.of(context).colorScheme;
    final Widget bar = _aiPick != null
        ? _aiPickBar()
        : sel != null
        ? _contextBar(sel)
        : _toolBar();
    final hasPanel = _panelBuilder != null && _aiPick == null;
    return PopScope(
      canPop: _aiPick == null && _panelBuilder == null && sel == null,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_aiPick != null) {
          _endAiPick();
        } else if (_panelBuilder != null) {
          _closePanel();
        } else {
          setState(() => _posterSel = null);
        }
      },
      child: Scaffold(
        appBar: _studioAppBar(),
        body: SafeArea(
          top: false,
          child: LayoutBuilder(
            builder: (context, c) {
              final canvas = _studioCanvas();
              final Widget main;
              if (wide) {
                main = Row(
                  children: [
                    Expanded(child: canvas),
                    if (hasPanel)
                      SizedBox(width: 380, child: _panelHost(side: true)),
                  ],
                );
              } else {
                final ph = c.maxHeight * (_panelBig ? 0.6 : 0.4);
                main = Column(
                  children: [
                    Expanded(child: canvas),
                    if (hasPanel)
                      SizedBox(height: ph, child: _panelHost(side: false)),
                  ],
                );
              }
              return Column(
                children: [
                  Expanded(child: main),
                  if (!keyboard || wide)
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainer,
                        border: Border(
                          top: BorderSide(
                            color: Theme.of(context).dividerColor,
                          ),
                        ),
                      ),
                      child: bar,
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------ Rückgängig/Wiederholen
  final DesignHistory _history = DesignHistory();
  Timer? _histTimer;
  bool _histReady = false;
  bool _histSync = false; // nach Undo/Redo: Stand nur übernehmen

  // Große Texte (Bilder als Data-URL) nur einmal halten: im Verlauf steht
  // ein Kürzel – so bleiben 50 Schritte klein.
  final Map<String, String> _blobTok = {};
  final Map<String, String> _tokBlob = {};
  static const _kBlob = '\u0000blob';

  Object? _packBlobs(Object? v) {
    if (v is String && v.length > 1024) {
      return _blobTok.putIfAbsent(v, () {
        final t = '$_kBlob${_tokBlob.length}';
        _tokBlob[t] = v;
        return t;
      });
    }
    if (v is Map) {
      return <String, dynamic>{
        for (final e in v.entries) e.key.toString(): _packBlobs(e.value),
      };
    }
    if (v is List) return <dynamic>[for (final x in v) _packBlobs(x)];
    return v;
  }

  Object? _unpackBlobs(Object? v) {
    if (v is String && v.startsWith(_kBlob)) return _tokBlob[v] ?? v;
    if (v is Map) {
      return <String, dynamic>{
        for (final e in v.entries) e.key.toString(): _unpackBlobs(e.value),
      };
    }
    if (v is List) return <dynamic>[for (final x in v) _unpackBlobs(x)];
    return v;
  }

  String _histState() =>
      jsonEncode(_packBlobs({'d': _designToJson(), 's': _settings.toMap()}));

  /// Gedrosselt nach jeder Änderung: neuen Stand merken (eine Geste = ein
  /// Schritt).
  void _scheduleHistory() {
    _histTimer?.cancel();
    _histTimer = Timer(const Duration(milliseconds: 450), () {
      if (!mounted || _gTarget != null) return;
      final st = _histState();
      if (!_histReady || _histSync) {
        _histReady = true;
        _histSync = false;
        _history.replaceCurrent(st);
        return;
      }
      if (_history.record(st)) setState(() {});
    });
  }

  void _applyHistory(String? st) {
    if (st == null) return;
    final m = _unpackBlobs(jsonDecode(st)) as Map<String, dynamic>;
    final before = jsonEncode(_settings.toMap());
    _histTimer?.cancel();
    _closePanel();
    _stopAnim();
    setState(() {
      _posterSel = null;
      _applyDesignJson(Map<String, dynamic>.from(m['d'] as Map));
      _settings = GraphicSettings.fromMap(
        Map<String, Object?>.from(m['s'] as Map),
      );
      _editorSeq++;
      _histSync = true;
    });
    _syncFtCtrl();
    _refreshBgDark();
    if (jsonEncode(_settings.toMap()) != before) {
      _saveCustomize(context.read<AppState>());
    }
  }

  void _undo() => _applyHistory(_history.undo());
  void _redo() => _applyHistory(_history.redo());

  // ------------------------------------------- Ziehen: Hilfslinien/Einrasten
  Rect? _gRect0; // Lage des Elements beim Start (Canvas-Koordinaten)
  Offset _gAcc = Offset.zero; // aufsummierte Fingerbewegung
  Offset? _gPos0; // relative Position (freie Elemente) beim Start
  Offset _gOff0 = Offset.zero; // Verschiebung (feste Teile) beim Start
  List<double> _gLinesX = const [], _gLinesY = const [];
  double? _guideX, _guideY;

  /// Lage eines Elements im Canvas (gedreht/skaliert als Hüllrechteck).
  Rect? _elementRect(String id) {
    final root = _boundaryKey.currentContext?.findRenderObject();
    final b = _stdCtx[id]?.findRenderObject();
    if (root is! RenderBox || b is! RenderBox) return null;
    if (!b.attached || !b.hasSize || !root.attached) return null;
    try {
      return MatrixUtils.transformRect(
        b.getTransformTo(root),
        Offset.zero & b.size,
      );
    } catch (_) {
      return null;
    }
  }

  void _snapStart(String id) {
    _gAcc = Offset.zero;
    _gRect0 = _elementRect(id);
    _gPos0 = _posterPos[id] ?? _kCenteredItemDefaults[id];
    _gOff0 = _stdOff[id] ?? Offset.zero;
    final xs = <double>[_cw / 2], ys = <double>[_ch / 2];
    for (final o in _stdCtx.keys) {
      if (o == id || _stdHidden.contains(o)) continue;
      final r = _elementRect(o);
      if (r == null) continue;
      xs.add(r.center.dx);
      ys.add(r.center.dy);
    }
    _gLinesX = xs;
    _gLinesY = ys;
  }

  /// Verschiebung inkl. Einrasten; setzt die Hilfslinien.
  Offset _snapMove(Offset delta, {required bool snap}) {
    _gAcc += delta;
    final r0 = _gRect0;
    if (!snap || r0 == null) {
      _guideX = _guideY = null;
      return _gAcc;
    }
    final c = r0.center + _gAcc;
    const margin = 16.0;
    final sx = snapAxis(
      center: c.dx,
      half: r0.width / 2,
      centerLines: _gLinesX,
      edgeLines: [margin, _cw - margin],
    );
    final sy = snapAxis(
      center: c.dy,
      half: r0.height / 2,
      centerLines: _gLinesY,
      edgeLines: [margin, _ch - margin],
    );
    _guideX = sx.line;
    _guideY = sy.line;
    return _gAcc + Offset(sx.offset, sy.offset);
  }

  void _onGestureEnd() {
    if (_gTarget == null) return;
    // Neu aufbauen: Hilfslinien weg + Verlauf merkt sich den Schritt.
    setState(() {
      _gTarget = null;
      _guideX = _guideY = null;
    });
  }

  /// Hilfslinien über der Grafik (nie im Export).
  Widget _guideLayer() {
    const color = Color(0xFFFF2D95);
    return Positioned.fill(
      child: IgnorePointer(
        child: Stack(
          children: [
            if (_guideX != null)
              Positioned(
                left: _guideX! - 0.75,
                top: 0,
                bottom: 0,
                child: const SizedBox(
                  width: 1.5,
                  child: ColoredBox(color: color),
                ),
              ),
            if (_guideY != null)
              Positioned(
                top: _guideY! - 0.75,
                left: 0,
                right: 0,
                child: const SizedBox(
                  height: 1.5,
                  child: ColoredBox(color: color),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    // Jede Änderung (rebuild) stößt debounced das Speichern an – so bleibt immer
    // der letzte Stand je Spiel erhalten.
    if (_editable && _hasStorage && _designLoaded) {
      _scheduleSave();
    }
    if (!_hasStorage || _designLoaded) _scheduleHistory();
    return _buildStudio();
  }
}

// Kuratierte Farbpalette für die Verlaufsfarben.
const _palette = <String>[
  '#0E3325',
  '#15603F',
  '#0B6B43',
  '#064E3B',
  '#0C4A6E',
  '#1E3A8A',
  '#111827',
  '#1F2937',
  '#000000',
  '#7F1D1D',
  '#92400E',
  '#3F3F46',
];

// Fertige Verlauf-Vorlagen (Name, oben, unten, Akzentfarbe/null = Weiß).
const _presets = <(String, String, String, String?)>[
  ('Dunkelgrün', '#0E3325', '#15603F', null),
  ('Vereinsgrün', '#0B6B43', '#0E3D28', null),
  ('Schwarz', '#1F2937', '#000000', null),
  ('Schwarz-Gold', '#1C1403', '#000000', '#D4AF37'),
  ('Nacht', '#0C4A6E', '#111827', null),
  ('Weinrot', '#7F1D1D', '#111827', null),
];

/// Öffentlich für andere Grafik-Editoren (z. B. Vergleich).
const List<String> kGradientPalette = _palette;
const List<(String, String, String, String?)> kGradientPresets = _presets;

// Akzentfarben für Highlights (erste = Weiß = „kein Akzent").
const _accentPalette = <String>[
  '#FFFFFF', // kein Akzent (Weiß wie bisher)
  '#000000', // Schwarz
  '#D4AF37', // Gold
  '#E9C46A', // Hellgold
  '#C0A062', // Altgold
  '#C0C0C0', // Silber
  '#38BDF8', // Hellblau
];

Color _hex(String h) {
  var s = h.replaceAll('#', '').trim();
  if (s.length == 6) s = 'FF$s';
  return Color(int.tryParse(s, radix: 16) ?? 0xFF0E3325);
}

// Mischmodi für das Hintergrundbild (Schlüssel, Anzeigename). „Ineinander-
// kopieren" ist der deutsche Photoshop-Name für Overlay.
const _blendOptions = <(String, String)>[
  ('normal', 'Normal'),
  ('overlay', 'Ineinanderkopieren'),
  ('multiply', 'Multiplizieren'),
  ('screen', 'Negativ multipl.'),
  ('softlight', 'Weiches Licht'),
];

BlendMode _blendModeOf(String s) => switch (s) {
  'overlay' => BlendMode.overlay,
  'multiply' => BlendMode.multiply,
  'screen' => BlendMode.screen,
  'softlight' => BlendMode.softLight,
  _ => BlendMode.srcOver,
};

/// Vorschau der KI-bearbeiteten Grafik: Bild (zoombar) + Teilen / Nochmal
/// bearbeiten / Verwerfen.
class _AiResultPreview extends StatelessWidget {
  const _AiResultPreview({
    required this.bytes,
    required this.name,
    required this.shareText,
    required this.onRetry,
  });

  final Uint8List bytes;
  final String name;
  final String shareText;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('KI-Vorschau')),
      backgroundColor: Colors.black,
      body: Center(
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 4,
          child: Image.memory(
            bytes,
            fit: BoxFit.contain,
            gaplessPlayback: true,
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    try {
                      await shareOrSaveImage(bytes, name, text: shareText);
                    } catch (e) {
                      messenger.showSnackBar(
                        SnackBar(content: Text('Teilen fehlgeschlagen: $e')),
                      );
                    }
                  },
                  icon: const Icon(Icons.share),
                  label: const Text('Teilen (WhatsApp)'),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.pop(context);
                        onRetry();
                      },
                      icon: const Icon(Icons.auto_awesome),
                      label: const Text('Nochmal'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                      label: const Text('Verwerfen'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Legt sein Kind mit Deckkraft + Mischmodus über das, was darunter gemalt
/// wurde (z.B. der Verlauf im Hintergrund). So „verschmilzt" ein Foto mit dem
/// Design (Ineinanderkopieren = BlendMode.overlay usw.).
class _BlendLayer extends SingleChildRenderObjectWidget {
  const _BlendLayer({
    required this.opacity,
    required this.mode,
    required Widget super.child,
  });

  final double opacity;
  final BlendMode mode;

  @override
  _BlendRender createRenderObject(BuildContext context) =>
      _BlendRender(opacity, mode);

  @override
  void updateRenderObject(BuildContext context, _BlendRender ro) {
    ro
      ..opacity = opacity
      ..mode = mode;
  }
}

class _BlendRender extends RenderProxyBox {
  _BlendRender(this._opacity, this._mode);
  double _opacity;
  BlendMode _mode;

  set opacity(double v) {
    if (v != _opacity) {
      _opacity = v;
      markNeedsPaint();
    }
  }

  set mode(BlendMode v) {
    if (v != _mode) {
      _mode = v;
      markNeedsPaint();
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final c = child;
    if (c == null) return;
    final paint = Paint()
      ..blendMode = _mode
      ..color = Color.fromRGBO(0, 0, 0, _opacity.clamp(0.0, 1.0));
    context.canvas.saveLayer(offset & size, paint);
    context.paintChild(c, offset);
    context.canvas.restore();
  }
}

/// Die eigentliche Grafik in fester logischer Größe (wird per RepaintBoundary
/// in ein PNG exportiert).
class _StartelfGraphic extends StatelessWidget {
  const _StartelfGraphic({
    required this.title,
    required this.logo,
    required this.starters,
    required this.benchNames,
    required this.mainSponsor,
    required this.barSponsors,
    required this.bgImage,
    required this.gradTop,
    required this.gradBottom,
    this.gradShape,
    this.bgPattern = 0,
    required this.overlayOpacity,
    required this.matchDate,
    required this.isHome,
    required this.opponentName,
    required this.opponentLogo,
    required this.compact,
    this.result,
    this.announcement,
    this.photoBg,
    this.bandPhotos = const [],
    this.showPhotos = false,
    this.photoController,
    this.designMode = false,
    this.infoPos = const Offset(0.5, 0.72),
    this.onInfoMove,
    this.onInfoMoveEnd,
    this.accent,
    this.logoCircle = false,
    this.bgOpacity = 1.0,
    this.bgBlend = BlendMode.srcOver,
    this.backgroundOnly = false,
    this.anim,
    this.animBase,
    this.animT,
    this.hideBackground = false,
    this.showScorers = true,
    this.posterStyle = false,
    this.posterHeadline = 'SPIELTAG',
    this.posterMain,
    this.posterBadge,
    this.posterLogoDisc = true,
    this.posterShadow = false,
    this.posterBlend = true,
    this.fupaPlayer = false,
    this.playerGlow = 0,
    this.playerMatch = 0,
    this.playerShade = 0,
    this.playerWarm = 0,
    this.playerLightDir = -2.356,
    this.playerLight = const Color(0xFF808080),
    this.posterShadowStrength = 45,
    this.posterShadowAngle = 45,
    this.posterOrder = const [],
    this.posterOverlays = const {},
    this.posterItemPos = const {},
    this.posterItemScale = const {},
    this.posterItemRot = const {},
    this.posterSelected,
    this.posterCentered = const {},
    this.onPosterAnchor,
    this.stdOffset = const {},
    this.stdHidden = const {},
    this.stdCtx,
    this.stdNatCtx,
    this.boxSize = const {},
    this.onBoxResizeStart,
    this.onBoxResizeUpdate,
    this.resultLayout = 'std',
    this.ftPhoto,
    this.ftController,
    this.onFtPhotoChanged,
    this.ftSplit = 0.56,
    this.onFtSplitDrag,
    this.editing = false,
    this.infoOverride,
    this.onPosterItemMove,
    this.onPosterGestureStart,
    this.onPosterGestureUpdate,
    this.onPosterGestureEnd,
    this.onPosterTap,
    this.onPosterWheel,
    this.onPosterLongPress,
    this.onPosterRotateTo,
    this.onBackgroundLongPress,
    this.onBackgroundTap,
    this.canvasKey,
    this.onPosterSelect,
    this.posterFont = 'standard',
    this.showMainSponsor = true,
    this.showOtherSponsors = true,
    this.mainSponsorMode = 'logo',
    this.posterTexts = const {},
    this.posterTextShadow = const {},
    this.posterTextAlign = const {},
  });

  final String title;
  final String? logo;
  final List<StartelfPlayer> starters;
  final List<String> benchNames;
  final Sponsor? mainSponsor;
  final List<Sponsor> barSponsors;
  final String? bgImage;
  final Color gradTop;
  final Color gradBottom;

  /// Verlaufsform (null = Standard des Layouts) und Splitter-Muster (0 = aus).
  final String? gradShape;
  final double bgPattern;
  final double overlayOpacity; // 0..1
  final DateTime? matchDate;
  final bool isHome;
  final String opponentName;
  final String? opponentLogo; // null = nicht anzeigen
  final bool compact;
  final ResultData? result; // gesetzt → Ergebnis statt Startelf
  final AnnouncementData? announcement; // gesetzt → Spielankündigung
  final String? photoBg; // Foto als Hintergrund (Data-URL), alle Typen
  final List<String> bandPhotos; // Fotos im Foto-Bereich oben (Data-URLs)
  final bool showPhotos; // Spielerfotos in der Ergebnis-Grafik
  final TransformationController?
  photoController; // einzelnes Band-Foto zoom/pan
  final bool designMode; // eigenes Branding-Design, nur Spiel-Infos drüber
  final Offset infoPos; // Position des Info-Blocks (0..1)
  final void Function(Offset pos)? onInfoMove; // Live-Verschieben
  final VoidCallback? onInfoMoveEnd; // Speichern nach dem Verschieben
  final Color? accent; // Akzentfarbe (Gold etc.); null = Weiß wie bisher
  final bool logoCircle; // Vereins-/Gegner-Logos auf rundem Feld (statt eckig)
  final double bgOpacity; // Deckkraft des Hintergrundbilds (0..1)
  final BlendMode bgBlend; // Mischmodus des Hintergrundbilds mit dem Verlauf
  final bool backgroundOnly; // nur die Hintergrund-Ebene (für Export)
  // Animation: Effekte je Element + Zeitpunkt (null = Standbild wie bisher).
  final GraphicAnim? anim;
  // Gesamte Animation des Designs (auch im Stillstand) – bestimmt den
  // gleichbleibenden Aufbau (z. B. Glanz-Ebene).
  final GraphicAnim? animBase;
  final double? animT;
  // Hintergrund weglassen (KI-Video liegt im Video-Export darunter).
  final bool hideBackground;
  final bool showScorers; // Torschützen-Block in der Ergebnis-Grafik zeigen
  final bool posterStyle; // Spielankündigung: Spieler-Poster statt zentriert
  final String posterHeadline; // Poster-Überschrift (SPIELTAG / HEIMSPIEL / …)
  final String? posterMain; // großes Spielerbild (Data-URL)
  final String? posterBadge; // rundes Zweit-Foto (Data-URL)
  final bool posterLogoDisc; // heller Kreis hinter den Poster-Logos
  final bool posterShadow; // Schlagschatten beim freigestellten Spieler
  final bool posterBlend; // Spielerfoto weich ins Bild einblenden
  final bool fupaPlayer; // FuPa-Foto: Spieler groß, unten bündig
  final double playerGlow; // 0..1 warmes Gegenlicht hinter dem Spieler
  final double playerMatch; // 0..1 Spieler ans Umgebungslicht angleichen
  final double playerShade; // 0..1 Licht & Schatten auf dem Spieler
  final double playerWarm; // 0..1 Wärme/Farbe nur auf dem Spieler
  final double playerLightDir; // Richtung, aus der das Licht kommt (Radiant)
  final Color playerLight; // Umgebungslicht (Hintergrund-Mittelfarbe)
  final double posterShadowStrength; // 0..100
  final double posterShadowAngle; // Richtung in Grad (0=rechts, 90=unten)
  final List<String> posterOrder; // Ebenen-Reihenfolge (hinten → vorne)
  final Map<String, String> posterOverlays; // id → Data-URL der Overlays
  final Map<String, Offset> posterItemPos; // Position je Element (0..1)
  final Map<String, double> posterItemScale; // Größe je Element
  final Map<String, double> posterItemRot; // Drehung je Element (Radiant)
  final String? posterSelected; // aktuell gewähltes Element
  // IDs, deren Position den MITTELPUNKT angibt (1:1 mit dem Finger, auch groß).
  // Alle anderen nutzen noch die alte Align-Semantik (bewegt sich bei großen
  // Elementen nur um einen Bruchteil) und werden beim Auswählen umgerechnet.
  final Set<String> posterCentered;
  // Meldet die aktuelle sichtbare Mitte (0..1) eines Elements → Umstellung auf
  // Mittelpunkt-Position ohne Sprung.
  final void Function(String id, Offset relCenter)? onPosterAnchor;
  // Ergebnis/Startelf: feste Teile (std_*) – Verschiebung (logische px) und
  // ausgeblendete Teile. Größe/Drehung kommen aus posterItemScale/-Rot.
  final Map<String, Offset> stdOffset;
  final Set<String> stdHidden;
  // Vom State gehaltene Kontexte der festen Teile (innen = mit Transform für
  // den Treffer-Test, außen = natürliche Lage für den Dreh-Griff).
  final Map<String, BuildContext>? stdCtx;
  final Map<String, BuildContext>? stdNatCtx;
  // Ziehbare Kästen: gezogene Größe (logische px) je Element.
  final Map<String, Size> boxSize;
  // Griff gepackt: [measured] = aktuelle (natürliche) Kastengröße als Start.
  final void Function(String id, Size measured)? onBoxResizeStart;
  // Griff gezogen: Finger-Delta (Canvas-px) + welche Achsen (Breite/Höhe).
  final void Function(String id, Offset delta, bool width, bool height)?
  onBoxResizeUpdate;
  final String resultLayout; // Ergebnis: 'std' | 'photo' (ENDSTAND mit Foto)
  final String? ftPhoto; // ENDSTAND: Foto oben (Data-URL)
  final TransformationController? ftController; // Ausschnitt des Fotos
  final VoidCallback? onFtPhotoChanged; // Zoom/Verschieben beendet → merken
  final double ftSplit; // ENDSTAND: Anteil des Fotos an der Höhe (0.2..0.85)
  // ENDSTAND: Trennlinie gezogen (Delta als Anteil der Gesamthöhe).
  final void Function(double deltaFraction)? onFtSplitDrag;
  final bool editing; // im Vollbild-Editor (Bedien-Griffe zeigen)
  // Designer: eigene Infozeile statt Datum/Ort (null = automatisch).
  final String? infoOverride;
  final void Function(String id, Offset pos)? onPosterItemMove;
  // Pinch/Drehen/Ziehen: Start legt das Ziel fest (null = keins) und merkt
  // Basiswerte, Update rechnet.
  final void Function(String? id)? onPosterGestureStart;
  final VoidCallback? onPosterGestureEnd;

  /// Antippen: alle Elemente am Canvas-Punkt (oberstes zuerst). Der Editor
  /// wählt daraus (nochmal an derselben Stelle tippen = darunterliegendes).
  final void Function(List<String> hits, Offset canvasPt)? onPosterTap;
  final void Function(
    String id,
    ScaleUpdateDetails details,
    double w,
    double h,
  )?
  onPosterGestureUpdate;

  /// Mausrad über einem Element (bzw. dem gewählten): [dy] < 0 = größer.
  final void Function(String id, double dy)? onPosterWheel;
  final void Function(String id)?
  onPosterLongPress; // Langdruck → Eigenschaften
  // Dreh-Griff an der Seite: setzt die Drehung absolut (Radiant) für [id].
  final void Function(String id, double angle)? onPosterRotateTo;
  final VoidCallback?
  onBackgroundLongPress; // Langdruck leere Fläche → hinzufügen
  final VoidCallback? onBackgroundTap; // Tippen leere Fläche → Auswahl aufheben
  // Für Global→Local-Umrechnung des Dreh-Griffs (Zeiger im Canvas-Koordinaten).
  final GlobalKey? canvasKey;
  final void Function(String id)? onPosterSelect;
  final String posterFont; // Schriftart der Poster-Texte
  final bool showMainSponsor; // Hauptsponsor-Element anzeigen
  final bool showOtherSponsors; // weitere Sponsoren (Logo-Reihe) anzeigen
  final String mainSponsorMode; // 'logo' | 'text' – Hauptsponsor-Darstellung
  // Eigene Textfelder: id → (Inhalt, Schriftart, Farb-Key).
  final Map<String, ({String text, String font, String color})> posterTexts;
  // Schatten-Stil je Text-Element (none/soft/strong/outline/glow).
  final Map<String, String> posterTextShadow;
  // Ausrichtung der Zeilen je Text-Element (left/center/right).
  final Map<String, String> posterTextAlign;

  /// Effektive Akzentfarbe (Weiß, wenn nichts gesetzt).
  Color get _accent => accent ?? Colors.white;

  /// Text-Farbe aus Schlüssel: weiß/schwarz/accent oder Hex (#RRGGBB).
  Color _resolveTextColor(String key) {
    switch (key) {
      case 'white':
        return Colors.white;
      case 'black':
        return Colors.black;
      case 'accent':
        return _accent;
      default:
        final s = key.replaceAll('#', '').trim();
        if (s.length == 6) {
          final v = int.tryParse(s, radix: 16);
          if (v != null) return Color(0xFF000000 | v);
        }
        return Colors.white;
    }
  }

  /// Text-Stil mit dem gewählten Schatten (Weich/Stark/Kontur/Leuchten).
  TextStyle _shadowed(String id, TextStyle s) {
    final kind = posterTextShadow[id];
    if (kind == null || kind == 'none') return s;
    final sh = textShadowsFor(kind, s.fontSize ?? 20, _brandBright);
    return s.copyWith(shadows: [...?s.shadows, ...sh]);
  }

  /// Gewählte Zeilen-Ausrichtung eines Texts (Standard: [def]).
  TextAlign _alignOf(String id, [TextAlign def = TextAlign.center]) =>
      switch (posterTextAlign[id]) {
        'left' => TextAlign.left,
        'right' => TextAlign.right,
        'center' => TextAlign.center,
        _ => def,
      };

  /// Fester Text (Titel/Überschrift/Datum) mit Schrift/Farbe-Override und
  /// Schatten; ohne Override [base] in der Poster-Schrift [defFont].
  TextStyle _styledFixed(String id, TextStyle base, {String? defFont}) {
    final o = posterTexts[id];
    var st = o == null
        ? base
        : base.copyWith(color: _resolveTextColor(o.color));
    final font = o?.font ?? defFont;
    if (font != null) st = posterFontStyle(font, st);
    return _shadowed(id, st);
  }

  /// Freier Text: bricht NUR an eigenen Zeilenumbrüchen (Enter) um, nie
  /// automatisch an der Bildbreite; lange Zeilen bleiben einzeilig (Größe
  /// über den Regler).
  // OverflowBox statt UnconstrainedBox: gleiche Wirkung, aber ohne
  // Überlauf-Warnung (gelb-schwarze Streifen im Debug-Build).
  Widget _freeText(String id, String text, TextStyle style) => OverflowBox(
    minWidth: 0,
    minHeight: 0,
    maxWidth: double.infinity,
    maxHeight: double.infinity,
    fit: OverflowBoxFit.deferToChild,
    child: Text(
      text,
      textAlign: _alignOf(id),
      softWrap: false,
      style: _shadowed(id, style),
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (backgroundOnly) {
      return _bgBase(radial: posterStyle); // nur Verlauf/Foto, ohne Inhalt
    }
    if (designMode) return _designLayout();
    if (announcement != null) {
      // Freier Editor für BEIDE Stile (Zentriert = anderes Default-Preset).
      // Auf den Grafik-Bereich beschneiden – nichts ragt nach außen.
      return ClipRect(child: _announcementPosterLayout());
    }
    // Ergebnis „Mit Foto" (ENDSTAND): eigenes Layout, gleiche Editor-Funktionen.
    if (result != null && resultLayout == 'photo') {
      return ClipRect(child: _freeOverlayWrap(_endstandLayout()));
    }
    // Ergebnis-/Startelf-Grafik: festes Layout + freie Nutzer-Elemente darüber.
    final content = _standardLayout();
    final band = [
      for (final p in bandPhotos) TeamLogo.decode(p),
    ].whereType<Uint8List>().toList();
    final base = band.isEmpty ? content : _withPhotoBand(band, content);
    return ClipRect(child: _freeOverlayWrap(base));
  }

  /// Bild mit optionalem Schlagschatten (gilt für Spieler UND Overlays).
  Widget _imageWithShadow(Uint8List bytes, {double? width, double? height}) {
    Widget mk() => SizedBox(
      width: width,
      height: height,
      child: Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true),
    );
    if (!posterShadow) return mk();
    final dist = 6 + 22 * (posterShadowStrength / 100);
    return Stack(
      children: [
        Transform.translate(
          offset: Offset(
            math.cos(posterShadowAngle * math.pi / 180) * dist,
            math.sin(posterShadowAngle * math.pi / 180) * dist,
          ),
          child: ImageFiltered(
            imageFilter: ui.ImageFilter.blur(
              sigmaX: 6 + 14 * (posterShadowStrength / 100),
              sigmaY: 6 + 14 * (posterShadowStrength / 100),
            ),
            child: Opacity(
              opacity: 0.2 + 0.55 * (posterShadowStrength / 100),
              child: ColorFiltered(
                colorFilter: const ColorFilter.mode(
                  Colors.black,
                  BlendMode.srcIn,
                ),
                child: mk(),
              ),
            ),
          ),
        ),
        mk(),
      ],
    );
  }

  /// Sichtbare Mitte eines Elements relativ zum Canvas (0..1). Drehen/Skalieren
  /// erfolgen um die Mitte, daher bleibt sie unter den Transforms gleich.
  Offset? _relCenterOf(BuildContext? ectx) {
    if (ectx == null || !ectx.mounted) return null;
    final eb = ectx.findRenderObject();
    final cb = canvasKey?.currentContext?.findRenderObject();
    if (eb is! RenderBox || cb is! RenderBox) return null;
    if (!eb.attached || !eb.hasSize || !cb.attached || !cb.hasSize) return null;
    if (cb.size.width <= 0 || cb.size.height <= 0) return null;
    final l = cb.globalToLocal(eb.localToGlobal(eb.size.center(Offset.zero)));
    return Offset(l.dx / cb.size.width, l.dy / cb.size.height);
  }

  /// Positioniert ein freies Element. Mittelpunkt-Modus ([centered]): die Mitte
  /// liegt genau bei [pos] → Verschieben folgt dem Finger 1:1, egal wie groß.
  /// Sonst alte Align-Semantik (für noch nicht umgerechnete, gespeicherte
  /// Positionen). Gleiche Widget-Struktur in beiden Modi, damit beim Umschalten
  /// nichts neu aufgebaut wird (laufender Langdruck bleibt erhalten).
  /// Element-Animation zum Zeitpunkt [animT] anwenden (Einblenden, Bewegung,
  /// Skalierung, Pulsieren, Glanz). Ohne Animation: unverändert.
  Widget _animWrap(String id, Widget child) {
    // Immer GLEICHER Aufbau (auch im Stillstand neutral): Fällt eine Hülle
    // weg (z. B. Deckkraft erreicht 100 % oder Abspielen endet), baut Flutter
    // das Element neu auf – Bilder blitzen dann kurz weg.
    final a = anim, t = animT;
    final e = a?.items[id];
    final playing = t != null && e != null;
    final st = playing
        ? animState(e, t)
        : (opacity: 1.0, offset: Offset.zero, scale: 1.0);
    var out = child;
    if (animBase?.items[id]?.shine ?? false) {
      final sh = playing ? shineAt(e, t) : null;
      double c(double v) => v.clamp(0.0, 1.0);
      out = ShaderMask(
        blendMode: BlendMode.srcATop,
        shaderCallback: (r) => LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: 0),
            Colors.white.withValues(alpha: sh == null ? 0 : 0.75),
            Colors.white.withValues(alpha: 0),
          ],
          stops: sh == null
              ? const [0.0, 0.5, 1.0]
              : [c(sh - 0.15), c(sh), c(sh + 0.15)],
        ).createShader(r),
        child: out,
      );
    }
    // Versatz relativ zur Grafikbreite (logisch immer 360).
    return Opacity(
      opacity: st.opacity.clamp(0.0, 1.0),
      child: Transform.translate(
        offset: st.offset * 360,
        child: Transform.scale(scale: st.scale, child: out),
      ),
    );
  }

  /// Text mit animierten Zahlen (Zähler) für Element [id].
  String _countStr(String id, String text) {
    final a = anim, t = animT;
    if (a == null || t == null) return text;
    return countText(text, a.items[id], t, seed: id);
  }

  Widget _placeElement({
    required Key key,
    required Offset pos,
    required bool centered,
    required double w,
    required double h,
    required Widget child,
  }) {
    return Positioned.fill(
      key: key,
      child: Transform.translate(
        offset: centered
            ? Offset((pos.dx - 0.5) * w, (pos.dy - 0.5) * h)
            : Offset.zero,
        child: Align(
          // Alte (Align-)Positionen auf den Bildrand begrenzen: Werte > 1
          // schoben Elemente (z. B. die Überschrift) aus dem Bild hinaus.
          alignment: centered
              ? Alignment.center
              : Alignment(
                  (pos.dx * 2 - 1).clamp(-1.0, 1.0),
                  (pos.dy * 2 - 1).clamp(-1.0, 1.0),
                ),
          child: _animWrap(_idOfKey(key), child),
        ),
      ),
    );
  }

  /// Element-ID aus dem Schlüssel `posterEl_<id>` bzw. `ovlEl_<id>`.
  static String _idOfKey(Key key) {
    if (key is! ValueKey<String>) return '';
    final v = key.value;
    final i = v.indexOf('_');
    return i < 0 ? v : v.substring(i + 1);
  }

  /// Liegt der Canvas-Punkt [canvasPt] (logische px) im Element [c]? Beachtet
  /// Verschiebung/Größe/Drehung (Umrechnung über die echten Transforms).
  bool _hitsCtx(BuildContext? c, Offset canvasPt) {
    if (c == null || !c.mounted) return false;
    final b = c.findRenderObject();
    final cb = canvasKey?.currentContext?.findRenderObject();
    if (b is! RenderBox || cb is! RenderBox) return false;
    if (!b.attached || !b.hasSize || !cb.attached) return false;
    final local = b.globalToLocal(cb.localToGlobal(canvasPt));
    return (Offset.zero & b.size).contains(local);
  }

  /// Feste Teile der Ergebnis-/Startelf-Grafik, oberstes zuerst (spätere im
  /// Layout liegen beim Überlappen oben).
  static const List<String> _kStdTopFirst = [
    'std_ft_sponsor_text',
    'std_ft_sponsor',
    'std_ft_sponsorbar',
    'std_ft_scorers',
    'std_ft_banner',
    'std_ft_title',
    'std_sponsorbar',
    'std_lineup',
    'std_scorers',
    'std_score',
    'std_vs',
    'std_info',
    'std_sponsor_text',
    'std_sponsor',
    'std_title',
    'std_logo',
  ];

  /// Alle festen Teile am Canvas-Punkt (oberstes zuerst).
  List<String> _stdHitsAt(Offset canvasPt) => [
    for (final id in _kStdTopFirst)
      if (!stdHidden.contains(id) && _hitsCtx(stdCtx?[id], canvasPt)) id,
  ];

  /// Canvas-Punkt aus einer globalen Position.
  Offset? _canvasPt(Offset global) {
    final cb = canvasKey?.currentContext?.findRenderObject();
    if (cb is! RenderBox || !cb.attached) return null;
    return cb.globalToLocal(global);
  }

  /// Antippen eines Elements weitergeben (alle Treffer → Editor wählt).
  void _tapAt(Offset global, String id, List<String> Function(Offset) hitsAt) {
    final p = _canvasPt(global);
    final cb = onPosterTap;
    if (p == null || cb == null) {
      onPosterSelect?.call(id);
      return;
    }
    final hs = hitsAt(p);
    cb(hs.isEmpty ? [id] : hs, p);
  }

  /// Oberstes festes Teil am Canvas-Punkt (oder null).
  String? _stdHitAt(Offset canvasPt) {
    for (final id in _kStdTopFirst) {
      if (stdHidden.contains(id)) continue;
      if (_hitsCtx(stdCtx?[id], canvasPt)) return id;
    }
    return null;
  }

  /// Festes Teil der Ergebnis-/Startelf-Grafik als frei gestaltbares Objekt:
  /// bleibt an seiner natürlichen Stelle im Layout (Startbild unverändert) und
  /// bekommt Verschiebung/Größe/Drehung obendrauf. Auswahl und Ziehen laufen
  /// über den Treffer-Test im Editor (kein eigener GestureDetector → keine
  /// Konflikte mit den Hintergrund-Gesten).
  Widget _stdEl(String id, Widget child) {
    if (stdHidden.contains(id)) {
      stdCtx?.remove(id);
      stdNatCtx?.remove(id);
      // Platz bleibt erhalten → die übrigen Teile springen nicht.
      return Visibility(
        visible: false,
        maintainSize: true,
        maintainAnimation: true,
        maintainState: true,
        child: child,
      );
    }
    final off = stdOffset[id] ?? Offset.zero;
    final scale = posterItemScale[id] ?? 1.0;
    final rot = posterItemRot[id] ?? 0.0;
    final selected = posterSelected == id;
    child = _animWrap(id, child);
    return Builder(
      builder: (nctx) {
        stdNatCtx?[id] = nctx;
        return Transform.translate(
          offset: off,
          child: Transform.rotate(
            angle: rot,
            child: Transform.scale(
              scale: scale,
              child: Builder(
                builder: (bctx) {
                  stdCtx?[id] = bctx;
                  // Rahmen nur als Vordergrund → Layout bleibt exakt gleich.
                  return DecoratedBox(
                    position: DecorationPosition.foreground,
                    decoration: selected
                        ? BoxDecoration(
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.9),
                            ),
                            borderRadius: BorderRadius.circular(4),
                          )
                        : const BoxDecoration(),
                    child: child,
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  /// Kästen, die sich in Breite/Höhe ziehen lassen.
  static const Set<String> _kResizable = {
    'std_scorers',
    'std_lineup',
    'std_sponsorbar',
    'std_ft_banner',
    'std_ft_scorers',
    'std_ft_sponsorbar',
  };

  /// Platz für einen ziehbaren Kasten. Ohne gezogene Größe: der Kasten wie
  /// bisher. Mit Größe: der Platz im Layout bleibt so groß wie der natürliche
  /// Kasten (unsichtbar) – der gezogene Kasten liegt mittig darüber und darf
  /// herausragen. So verrutscht beim Ziehen nichts anderes.
  Widget _boxSlot(String id, Widget natural, Widget Function(Size s) sized) {
    final s = boxSize[id];
    if (s == null) return _stdEl(id, natural);
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        Visibility(
          visible: false,
          maintainSize: true,
          maintainAnimation: true,
          maintainState: true,
          child: natural,
        ),
        Positioned.fill(
          child: OverflowBox(
            minWidth: 0,
            minHeight: 0,
            maxWidth: double.infinity,
            maxHeight: double.infinity,
            child: _stdEl(id, sized(s)),
          ),
        ),
      ],
    );
  }

  /// Kasten mit fester Größe [s]: nur der Kasten wächst, die Schrift bleibt
  /// gleich groß. Passt der Inhalt nicht, wird er verkleinert (nie
  /// abgeschnitten). [fillWidth]: Inhalt bekommt die volle Innenbreite (z. B.
  /// Spalten rücken auseinander), sonst behält er seine natürliche Breite.
  Widget _fixedBox(
    Size s, {
    required EdgeInsets padding,
    required Decoration decoration,
    required Widget Function(double innerWidth) content,
    bool fillWidth = true,
    Alignment alignment = Alignment.center,
  }) {
    return Container(
      width: s.width,
      height: s.height,
      padding: padding,
      decoration: decoration,
      child: LayoutBuilder(
        builder: (_, c) => FittedBox(
          fit: BoxFit.scaleDown,
          alignment: alignment,
          child: fillWidth
              ? SizedBox(width: c.maxWidth, child: content(c.maxWidth))
              : content(c.maxWidth),
        ),
      ),
    );
  }

  /// Zieh-Griffe des gewählten Kastens: rechte Kante (Breite), untere Kante
  /// (Höhe), Ecke unten rechts (beides). Lage aus dem echten Kasten (beachtet
  /// Verschiebung/Größe/Drehung).
  List<Widget> _resizeHandles(String? sel) {
    if (sel == null || !_kResizable.contains(sel)) return const [];
    final ectx = stdCtx?[sel];
    if (ectx == null || !ectx.mounted) return const [];
    final eb = ectx.findRenderObject();
    final cb = canvasKey?.currentContext?.findRenderObject();
    if (eb is! RenderBox || cb is! RenderBox) return const [];
    if (!eb.attached || !eb.hasSize || !cb.attached) return const [];
    final sz = eb.size;
    Offset toCanvas(Offset p) => cb.globalToLocal(eb.localToGlobal(p));

    Widget handle(String key, Offset at, {required bool w, required bool h}) {
      return Positioned(
        key: ValueKey('rz_$key'),
        left: at.dx - 12,
        top: at.dy - 12,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) => onBoxResizeStart?.call(sel, sz),
          onPanUpdate: (d) => onBoxResizeUpdate?.call(sel, d.delta, w, h),
          child: Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: Colors.white,
              shape: (w && h) ? BoxShape.rectangle : BoxShape.circle,
              borderRadius: (w && h) ? BorderRadius.circular(5) : null,
              border: Border.all(color: Colors.black54, width: 1.5),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 4,
                ),
              ],
            ),
            child: Icon(
              (w && h)
                  ? Icons.open_in_full
                  : (w ? Icons.swap_horiz : Icons.swap_vert),
              size: 14,
              color: Colors.black87,
            ),
          ),
        ),
      );
    }

    return [
      handle('w', toCanvas(Offset(sz.width, sz.height / 2)), w: true, h: false),
      handle('h', toCanvas(Offset(sz.width / 2, sz.height)), w: false, h: true),
      handle('wh', toCanvas(Offset(sz.width, sz.height)), w: true, h: true),
    ];
  }

  /// Sichtbare Mitte (logische px) des gewählten Elements für den Dreh-Griff.
  Offset? _selCenterPx(String sel, double w, double h) {
    if (sel.startsWith('std_')) {
      // Natürliche Lage (ohne Transforms) + aktuelle Verschiebung.
      final nat = _relCenterOf(stdNatCtx?[sel]);
      if (nat == null) return null;
      final off = stdOffset[sel] ?? Offset.zero;
      return Offset(nat.dx * w + off.dx, nat.dy * h + off.dy);
    }
    final pos =
        posterItemPos[sel] ??
        _kCenteredItemDefaults[sel] ??
        const Offset(0.5, 0.5);
    return Offset(pos.dx * w, pos.dy * h);
  }

  /// Dreh-Griff (Kreis mit Icon) an der Seite des gewählten Elements: packen und
  /// um die Mitte drehen. null, wenn nichts gewählt ist.
  Widget? _rotationHandle(String? sel, double w, double h) {
    if (sel == null) return null;
    final c = _selCenterPx(sel, w, h);
    if (c == null) return null;
    final rot = posterItemRot[sel] ?? 0.0;
    final cx = c.dx, cy = c.dy;
    // Abstand des Griffs von der Mitte: knapp ÜBER dem oberen Rand des Objekts
    // (sonst läge er bei großen Objekten mitten drin und man dreht statt zu
    // verschieben). Größe aus dem letzten Layout × Skalierung.
    var hd = 54.0;
    final ectx = stdCtx?[sel];
    if (ectx != null && ectx.mounted) {
      final b = ectx.findRenderObject();
      if (b is RenderBox && b.hasSize) {
        final s = posterItemScale[sel] ?? 1.0;
        hd = math.max(54.0, b.size.height * s / 2 + 26);
      }
    }
    var hx = cx + hd * math.sin(rot);
    var hy = cy - hd * math.cos(rot);
    // Läge der Griff außerhalb der Grafik → auf die Gegenseite (unten) legen.
    final flip = hx < 18 || hx > w - 18 || hy < 18 || hy > h - 18;
    if (flip) {
      hx = cx - hd * math.sin(rot);
      hy = cy + hd * math.cos(rot);
    }
    return Positioned(
      left: hx - 18,
      top: hy - 18,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (d) {
          final box =
              canvasKey?.currentContext?.findRenderObject() as RenderBox?;
          if (box == null) return;
          final local = box.globalToLocal(d.globalPosition);
          // Griff oben: Richtung „nach oben" = Drehung; Griff unten: Gegenrichtung.
          final ang =
              math.atan2(local.dy - cy, local.dx - cx) +
              (flip ? -math.pi / 2 : math.pi / 2);
          onPosterRotateTo?.call(sel, ang);
        },
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 4,
              ),
            ],
          ),
          child: const Icon(
            Icons.rotate_right,
            size: 20,
            color: Colors.black87,
          ),
        ),
      ),
    );
  }

  /// Legt die frei platzierbaren Nutzer-Elemente (Spielerbild, Bild-Overlays,
  /// Text) samt Gesten über ein FESTES Layout [base] (Ergebnis/Startelf). Das
  /// feste, datengetriebene Layout bleibt unverändert darunter.
  Widget _freeOverlayWrap(Widget base) {
    final mainBytes = TeamLogo.decode(posterMain);
    return LayoutBuilder(
      builder: (ctx, c) {
        final w = c.maxWidth, h = c.maxHeight;
        Widget? content(String id) {
          if (id == 'player') {
            if (mainBytes == null) return null;
            return _imageWithShadow(mainBytes, width: w * 0.6, height: h * 0.6);
          }
          if (id.startsWith('text_')) {
            final t = posterTexts[id];
            if (t == null || t.text.trim().isEmpty) return null;
            return _freeText(
              id,
              t.text,
              posterFontStyle(
                t.font,
                TextStyle(
                  color: _resolveTextColor(t.color),
                  fontSize: 34,
                  fontWeight: FontWeight.w900,
                  height: 1.0,
                ),
              ),
            );
          }
          final url = posterOverlays[id];
          if (url == null) return null;
          final bytes = TeamLogo.decode(url);
          if (bytes == null) return null;
          return _imageWithShadow(bytes, width: w * 0.4);
        }

        // Kontexte der Elemente (zum Messen der sichtbaren Mitte).
        final elCtx = <String, BuildContext>{};
        void anchor(String id) {
          if (posterCentered.contains(id)) return;
          final r = _relCenterOf(elCtx[id]);
          if (r != null) onPosterAnchor?.call(id, r);
        }

        // Alle Objekte am Punkt: freie Elemente (vorne zuerst), dann die
        // festen Teile des Layouts.
        List<String> hitsAt(Offset p) => [
          for (final id in posterOrder.reversed)
            if (_hitsCtx(elCtx[id], p)) id,
          ..._stdHitsAt(p),
        ];

        Widget el(String id, Widget child) {
          final pos =
              posterItemPos[id] ??
              _kCenteredItemDefaults[id] ??
              const Offset(0.5, 0.5);
          final scale = posterItemScale[id] ?? 1.0;
          final rot = posterItemRot[id] ?? 0.0;
          final selected = posterSelected == id;
          return _placeElement(
            key: ValueKey('ovlEl_$id'),
            pos: pos,
            centered: posterCentered.contains(id),
            w: w,
            h: h,
            child: Transform.rotate(
              angle: rot,
              child: Transform.scale(
                scale: scale,
                child: Builder(
                  builder: (bctx) {
                    elCtx[id] = bctx;
                    stdCtx?[id] = bctx; // Größe für den Dreh-Griff
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (_) => anchor(id),
                      onTapUp: (d) => _tapAt(d.globalPosition, id, hitsAt),
                      onLongPress: () => onPosterLongPress?.call(id),
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: selected
                            ? BoxDecoration(
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.9),
                                ),
                                borderRadius: BorderRadius.circular(4),
                              )
                            : null,
                        child: child,
                      ),
                    );
                  },
                ),
              ),
            ),
          );
        }

        final layers = <Widget>[];
        for (final id in posterOrder) {
          final child = content(id);
          if (child != null) layers.add(el(id, child));
        }
        final sel = posterSelected;
        // Gewähltes, noch nicht umgerechnetes Element (z. B. per Code gewählt)
        // nach dem Frame auf Mittelpunkt-Position umstellen.
        if (sel != null &&
            !sel.startsWith('std_') &&
            !posterCentered.contains(sel)) {
          WidgetsBinding.instance.addPostFrameCallback((_) => anchor(sel));
        }
        // Oberstes Objekt am Punkt: freie Elemente (vorne zuerst), dann die
        // festen Teile des Layouts.
        String? hitAt(Offset p) {
          for (final id in posterOrder.reversed) {
            if (_hitsCtx(elCtx[id], p)) return id;
          }
          return _stdHitAt(p);
        }

        // Zieh-Ebene: ein Finger auf einem Objekt → dieses wählen und direkt
        // ziehen; auf freier Fläche (oder mit zwei Fingern) wird das gewählte
        // Objekt bewegt/gepincht. Ohne Auswahl greift sie NUR über Objekten –
        // sonst bleibt z. B. das Foto im Foto-Bereich verschieb-/zoombar.
        final dragLayer = Positioned.fill(
          child: _HitWhere(
            test: (p) => sel != null || hitAt(p) != null,
            child: Listener(
              // Mausrad über einem Objekt (oder mit Auswahl) → dieses Objekt
              // skalieren statt die ganze Ansicht zu zoomen.
              onPointerSignal: (e) {
                if (e is! PointerScrollEvent || onPosterWheel == null) return;
                final target = hitAt(e.localPosition) ?? sel;
                if (target == null) return;
                GestureBinding.instance.pointerSignalResolver.register(e, (ev) {
                  if (target != sel) onPosterSelect?.call(target);
                  onPosterWheel!(
                    target,
                    (ev as PointerScrollEvent).scrollDelta.dy,
                  );
                });
              },
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onScaleStart: (d) {
                  var target = sel;
                  if (d.pointerCount < 2) {
                    // Gewähltes unter dem Finger behalten (auch wenn es unter
                    // einem anderen liegt), sonst das oberste nehmen.
                    final hs = hitsAt(d.localFocalPoint);
                    target = sel != null && hs.contains(sel)
                        ? sel
                        : (hs.isEmpty ? sel : hs.first);
                  }
                  if (target != null && target != sel) {
                    onPosterSelect?.call(target);
                  }
                  if (target != null && !target.startsWith('std_')) {
                    anchor(target);
                  }
                  onPosterGestureStart?.call(target);
                },
                onScaleUpdate: (d) =>
                    onPosterGestureUpdate?.call(sel ?? '', d, w, h),
                onScaleEnd: (_) => onPosterGestureEnd?.call(),
              ),
            ),
          ),
        );
        return Stack(
          key: canvasKey,
          fit: StackFit.expand,
          children: [
            base,
            // Hintergrund-Gesten: Tippen auf ein festes Teil = auswählen, sonst
            // Auswahl weg; Langdruck auf festes Teil = Eigenschaften, sonst
            // Hinzufügen-Menü.
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTapUp: (d) {
                  final hs = _stdHitsAt(d.localPosition);
                  if (hs.isEmpty) {
                    onBackgroundTap?.call();
                  } else if (onPosterTap != null) {
                    onPosterTap!(hs, d.localPosition);
                  } else {
                    onPosterSelect?.call(hs.first);
                  }
                },
                onLongPressStart: (d) {
                  final hit = _stdHitAt(d.localPosition);
                  if (hit != null) {
                    onPosterLongPress?.call(hit);
                  } else {
                    onBackgroundLongPress?.call();
                  }
                },
              ),
            ),
            ...layers,
            dragLayer,
            // Zieh-Griffe für Kästen (Breite/Höhe) über der Zieh-Ebene.
            ..._resizeHandles(sel),
            // ENDSTAND: Trennlinie Foto/unten hoch- und runterziehen (nur im
            // Editor und ohne Auswahl → nie im geteilten Bild).
            if (editing &&
                sel == null &&
                result != null &&
                resultLayout == 'photo' &&
                onFtSplitDrag != null) ...[
              Positioned(
                left: 0,
                right: 0,
                top: ftSplit * h - 1,
                height: 2,
                child: IgnorePointer(
                  child: ColoredBox(
                    color: Colors.white.withValues(alpha: 0.55),
                  ),
                ),
              ),
              Positioned(
                key: const ValueKey('ftSplitHandle'),
                left: w / 2 - 34,
                top: ftSplit * h - 13,
                width: 68,
                height: 26,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragUpdate: (d) =>
                      onFtSplitDrag?.call(d.delta.dy / h),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(13),
                      border: Border.all(color: Colors.black54, width: 1.5),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.3),
                          blurRadius: 4,
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.unfold_more,
                      size: 18,
                      color: Colors.black87,
                    ),
                  ),
                ),
              ),
            ],
            // Dreh-Griff (oben über allem, damit er die Geste bekommt).
            ?_rotationHandle(sel, w, h),
          ],
        );
      },
    );
  }

  /// Design-Modus: nur Hintergrund-Design + verschiebbarer Info-Block
  /// (kein eigenes Logo/Titel). Je Grafiktyp andere Infos.
  Widget _designLayout() {
    return LayoutBuilder(
      builder: (ctx, c) {
        final w = c.maxWidth, h = c.maxHeight;
        return Stack(
          fit: StackFit.expand,
          children: [
            _bgBase(),
            Align(
              alignment: Alignment(infoPos.dx * 2 - 1, infoPos.dy * 2 - 1),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanUpdate: (d) {
                  final nx = (infoPos.dx + d.delta.dx / w).clamp(0.14, 0.86);
                  final ny = (infoPos.dy + d.delta.dy / h).clamp(0.12, 0.9);
                  onInfoMove?.call(Offset(nx, ny));
                },
                onPanEnd: (_) => onInfoMoveEnd?.call(),
                child: _designInfoBlock(),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Kompakter Info-Block (über dem Design): Teams/VS + Datum bzw. Score.
  Widget _designInfoBlock() {
    final ownLogo = TeamLogo.decode(logo);
    final oppLogo = TeamLogo.decode(opponentLogo);
    final logoH = compact ? 56.0 : 70.0;

    // Heim links, Gast rechts: auswärts steht der Gegner vorn.
    final first = isHome ? ownLogo : oppLogo;
    final second = isHome ? oppLogo : ownLogo;
    Widget vs() => Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (first != null) _logoChip(first, height: logoH, circle: logoCircle),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Text(
            'VS',
            style: TextStyle(
              color: _accent,
              fontSize: 34,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        if (second != null)
          _logoChip(second, height: logoH, circle: logoCircle),
      ],
    );

    final children = <Widget>[vs(), const SizedBox(height: 12)];

    final r = result;
    final a = announcement;
    if (r != null) {
      children.add(
        Text(
          isHome
              ? _countStr('std_score', '${r.ownScore} : ${r.oppScore}')
              : _countStr('std_score', '${r.oppScore} : ${r.ownScore}'),
          style: TextStyle(
            color: _accent,
            fontSize: 56,
            fontWeight: FontWeight.w900,
            height: 1.0,
          ),
        ),
      );
    } else if (a != null && matchDate != null) {
      final d = matchDate!.toLocal();
      children.add(
        Text(
          DateFormat('EEEE, dd.MM.yyyy', 'de_DE').format(d),
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w800,
          ),
        ),
      );
      if (d.hour != 0 || d.minute != 0) {
        children.add(
          Text(
            '${DateFormat('HH:mm', 'de_DE').format(d)} Uhr',
            style: TextStyle(
              color: _accent,
              fontSize: 24,
              fontWeight: FontWeight.w900,
            ),
          ),
        );
      }
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    );
  }

  /// Foto-Bereich oben + darunter der eigentliche Inhalt (für alle Typen).
  Widget _withPhotoBand(List<Uint8List> photos, Widget content) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 46,
          child: ColoredBox(color: gradTop, child: _photoBand(photos)),
        ),
        Expanded(flex: 54, child: content),
      ],
    );
  }

  /// 1 Foto = verschieb-/zoombar; mehrere = Collage-Reihe (BoxFit.cover).
  Widget _photoBand(List<Uint8List> photos) {
    if (photos.length == 1) {
      // „contain" → das ganze Foto bleibt sichtbar (nichts abgeschnitten).
      // Zum Formatfüllen kann der Nutzer per Pinch/Drag zoomen.
      return ClipRect(
        child: InteractiveViewer(
          transformationController: photoController,
          minScale: 0.4,
          maxScale: 4,
          boundaryMargin: const EdgeInsets.all(double.infinity),
          clipBehavior: Clip.none,
          child: Image.memory(
            photos.first,
            fit: BoxFit.contain,
            gaplessPlayback: true,
          ),
        ),
      );
    }
    return Row(
      children: [
        for (var i = 0; i < photos.length; i++) ...[
          if (i > 0) const SizedBox(width: 2),
          Expanded(
            child: ClipRect(
              child: Image.memory(
                photos[i],
                fit: BoxFit.cover,
                gaplessPlayback: true,
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// Standard-Layout (Startelf bzw. Ergebnis ohne eigenen Foto-Bereich).
  Widget _standardLayout() {
    if (result == null && announcement == null) return _startelfLayout();
    final pad = compact ? 16.0 : 20.0;
    return Stack(
      fit: StackFit.expand,
      children: [
        _bgBase(),
        Padding(
          padding: EdgeInsets.all(pad),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Story: „Präsentiert von" als eigene Zeile oben rechts.
              if (!compact && _presentedByTopRow() != null) ...[
                Align(
                  alignment: Alignment.centerRight,
                  child: _presentedByTopRow()!,
                ),
                const SizedBox(height: 8),
              ],
              // Kopfleiste (Logo + Vereinsname/Überschrift; im Post-Format auch
              // der Sponsor). Jedes Teil ist ein eigenes, frei gestaltbares
              // Objekt (_stdEl) und startet an seiner Stelle im Layout.
              _header(),
              SizedBox(height: compact ? 6 : 12),
              if (announcement == null)
                Center(
                  child: _stdEl(
                    'std_info',
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: _startelfDateLine(),
                    ),
                  ),
                ),
              SizedBox(height: compact ? 7 : 16),
              _divider(),
              SizedBox(height: compact ? 8 : 18),
              if (result != null) ...[
                // Spielstand groß & fix (der Blickfang) …
                _stdEl('std_score', _scoreRow()),
                SizedBox(height: compact ? 10 : 14),
                // … darunter die Torschützen (nur wenn aktiviert). Align + lose
                // Grenzen ergeben dieselbe Größe/Lage wie zuvor, aber eine
                // Trefferfläche nur so groß wie der Block.
                Expanded(
                  child: showScorers
                      ? Align(
                          alignment: Alignment.topCenter,
                          child: _boxSlot(
                            'std_scorers',
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.topCenter,
                              child: _scorersCardsBlock(),
                            ),
                            (s) => _scorersCardsBlock(size: s),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ] else
                Expanded(
                  child: Center(
                    child: _boxSlot(
                      'std_lineup',
                      FittedBox(
                        fit: BoxFit.contain,
                        alignment: Alignment.center,
                        child: _lineupBlock(),
                      ),
                      (s) => _lineupBlock(size: s),
                    ),
                  ),
                ),
              if (barSponsors.isNotEmpty && showOtherSponsors) ...[
                SizedBox(height: compact ? 6 : 10),
                _boxSlot(
                  'std_sponsorbar',
                  _sponsorBar(),
                  (s) => _sponsorBar(size: s),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// Story-Ergebnis: schräger Balken in Vereinsfarbe hinter [child]
  /// (Überschrift, Spielstand). Im Post-Format ohne Balken.
  Widget _resultBand(Widget child) {
    if (compact || result == null) return child;
    return _slantBand(child);
  }

  /// Schräger Balken in Vereinsfarbe (Verlauf) hinter [child].
  Widget _slantBand(Widget child) {
    return ClipPath(
      clipper: const _SlantClipper(),
      child: Container(
        padding: const EdgeInsets.fromLTRB(30, 4, 34, 4),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              _brandBright.withValues(alpha: 0.35),
              _brandBright,
              _brandBright.withValues(alpha: 0.5),
            ],
          ),
        ),
        child: child,
      ),
    );
  }

  /// Kräftige Vereinsfarbe (aufgehellter Verlauf) für Balken und Rahmen.
  Color get _brandBright {
    final h = HSLColor.fromColor(gradTop);
    return h
        .withLightness(h.lightness.clamp(0.36, 0.46))
        .withSaturation(math.max(h.saturation, 0.62))
        .toColor();
  }

  /// Startelf (zentriert): Logos · „— VEREIN —" · STARTELF · Spielinfo ·
  /// Gegner-Balken · Kader-Kasten (Nr. | Name, darunter BANK) · Sponsoren.
  /// Jedes Teil bleibt ein eigenes, frei gestaltbares Objekt.
  Widget _startelfLayout() {
    final pad = compact ? 10.0 : 20.0;
    final logoBytes = TeamLogo.decode(logo);
    final logoH = compact ? 32.0 : 62.0;
    final Widget? clubLogo = logoBytes != null
        ? _logoChip(logoBytes, height: logoH, circle: logoCircle)
        : (logo != null ? TeamLogo(logoPath: logo, size: logoH) : null);
    final sponsor = mainSponsor != null && showMainSponsor
        ? ConstrainedBox(
            constraints: BoxConstraints(maxWidth: compact ? 90 : 150),
            child: _mainSponsorMark(logoH: logoH, nameSize: compact ? 16 : 20),
          )
        : null;
    final topRow = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (clubLogo != null) _stdEl('std_logo', clubLogo),
        if (clubLogo != null && sponsor != null)
          Container(
            width: 2,
            height: logoH * 0.62,
            margin: const EdgeInsets.symmetric(horizontal: 16),
            color: Colors.white.withValues(alpha: 0.75),
          ),
        if (sponsor != null) _stdEl('std_sponsor', sponsor),
      ],
    );
    final line = Expanded(
      child: Container(height: 1.5, color: Colors.white.withValues(alpha: 0.7)),
    );
    final titleBlock = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            line,
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                title.toUpperCase(),
                maxLines: 1,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: compact ? 10 : 18,
                  fontWeight: FontWeight.w800,
                  letterSpacing: compact ? 2.5 : 4.5,
                ),
              ),
            ),
            line,
          ],
        ),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            posterHeadline,
            maxLines: 1,
            softWrap: false,
            style: posterFontStyle(
              posterFont,
              TextStyle(
                color: Colors.white,
                fontSize: compact ? 36 : 66,
                fontWeight: FontWeight.w900,
                fontStyle: FontStyle.italic,
                letterSpacing: 1,
                height: 1.0,
                shadows: const [Shadow(color: Colors.black54, blurRadius: 12)],
              ),
            ),
          ),
        ),
      ],
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        _bgBase(),
        Padding(
          padding: EdgeInsets.fromLTRB(pad, pad, pad, pad * 0.8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              topRow,
              SizedBox(height: compact ? 4 : 14),
              _stdEl('std_title', titleBlock),
              SizedBox(height: compact ? 2 : 4),
              Center(
                child: _stdEl(
                  'std_info',
                  FittedBox(fit: BoxFit.scaleDown, child: _startelfDateLine()),
                ),
              ),
              if (opponentName.isNotEmpty) ...[
                SizedBox(height: compact ? 4 : 12),
                Center(
                  child: _stdEl(
                    'std_vs',
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: _startelfVsBanner(),
                    ),
                  ),
                ),
              ],
              SizedBox(height: compact ? 6 : 14),
              Expanded(
                child: Center(
                  child: _boxSlot(
                    'std_lineup',
                    FittedBox(
                      fit: BoxFit.contain,
                      alignment: Alignment.topCenter,
                      child: _startelfPanel(),
                    ),
                    (s) => _startelfPanel(size: s),
                  ),
                ),
              ),
              if (barSponsors.isNotEmpty && showOtherSponsors) ...[
                SizedBox(height: compact ? 6 : 10),
                _boxSlot(
                  'std_sponsorbar',
                  _sponsorBar(),
                  (s) => _sponsorBar(size: s),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// „HEIMSPIEL · So., 08.11.2026 · 13:15 Uhr" – zentriert, weiß.
  Widget _startelfDateLine() {
    final parts = <String>[isHome ? 'HEIMSPIEL' : 'AUSWÄRTSSPIEL'];
    if (matchDate != null) {
      final local = matchDate!.toLocal();
      parts.add(DateFormat('EEE, dd.MM.yyyy', 'de_DE').format(local));
      if (local.hour != 0 || local.minute != 0) {
        parts.add('${DateFormat('HH:mm', 'de_DE').format(local)} Uhr');
      }
    }
    final o = posterTexts['std_info'];
    final text = (o != null && o.text.trim().isNotEmpty)
        ? o.text
        : parts.join('   ·   ');
    return Text(
      text,
      softWrap: false,
      textAlign: _alignOf('std_info'),
      style: _styledFixed(
        'std_info',
        TextStyle(
          color: Colors.white.withValues(alpha: 0.95),
          fontSize: compact ? 9 : 14,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.6,
        ),
        // Ohne eigene Schrift bleibt die Standardschrift (nicht Poster-Font).
        defFont: o?.font,
      ),
    );
  }

  /// Schräger Balken in Vereinsfarbe: Gegner-Logo (weißer Kreis) + „vs …".
  Widget _startelfVsBanner() {
    final oppBytes = TeamLogo.decode(opponentLogo);
    final h = compact ? 24.0 : 42.0;
    return ClipPath(
      clipper: const _SlantClipper(),
      child: Container(
        height: h,
        padding: EdgeInsets.symmetric(horizontal: h * 1.1),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              _brandBright.withValues(alpha: 0.55),
              _brandBright,
              _brandBright.withValues(alpha: 0.55),
            ],
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (oppBytes != null) ...[
              Container(
                width: h * 0.86,
                height: h * 0.86,
                padding: EdgeInsets.all(h * 0.08),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                ),
                child: ClipOval(
                  child: Image.memory(
                    oppBytes,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                  ),
                ),
              ),
              const SizedBox(width: 12),
            ],
            Text(
              'vs ${opponentName.toUpperCase()}',
              maxLines: 1,
              style: TextStyle(
                color: Colors.white,
                fontSize: compact ? 11 : 18,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Kader-Kasten: Torwart oben, dann nach Rückennummer; „Nr. | NAME" mit
  /// Trennstrich, Torwart mit Zusatz; darunter Linie + BANK-Plakette.
  Widget _startelfPanel({Size? size}) {
    bool isKeeper(StartelfPlayer p) {
      final pos = (p.position ?? '').toLowerCase();
      return pos.contains('tor') || pos == 'tw' || pos.contains('keeper');
    }

    final keepers = [
      for (final p in starters)
        if (isKeeper(p)) p,
    ];
    final field = [
      for (final p in starters)
        if (!isKeeper(p)) p,
    ]..sort((a, b) => (a.number ?? 999).compareTo(b.number ?? 999));
    final ordered = [...keepers, ...field];
    const numStyle = TextStyle(
      color: Colors.white,
      fontSize: 26,
      fontWeight: FontWeight.w900,
      fontFeatures: [ui.FontFeature.tabularFigures()],
      height: 1.1,
    );
    const nameStyle = TextStyle(
      color: Colors.white,
      fontSize: 26,
      fontWeight: FontWeight.w900,
      letterSpacing: 0.4,
      height: 1.1,
    );
    final subStyle = TextStyle(
      color: Colors.white.withValues(alpha: 0.85),
      fontSize: 12,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.6,
      height: 1.1,
    );
    Widget row(StartelfPlayer p) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: 52,
              child: Text(
                p.number?.toString() ?? '',
                textAlign: TextAlign.center,
                style: numStyle,
              ),
            ),
            Container(
              width: 2,
              margin: const EdgeInsets.symmetric(horizontal: 14),
              color: Colors.white.withValues(alpha: 0.6),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(p.name.toUpperCase(), style: nameStyle),
                if (isKeeper(p)) Text('TORWART', style: subStyle),
              ],
            ),
          ],
        ),
      ),
    );
    // Post (1:1) ist flach: Kader in zwei Spalten → deutlich größer lesbar.
    final twoCols = compact && ordered.length > 6;
    final half = (ordered.length + 1) ~/ 2;
    Widget col(List<StartelfPlayer> list) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [for (final p in list) row(p)],
    );
    final rows = twoCols
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              col(ordered.sublist(0, half)),
              const SizedBox(width: 30),
              col(ordered.sublist(half)),
            ],
          )
        : col(ordered);
    final bench = benchNames.isEmpty
        ? null
        : Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ClipPath(
                clipper: const _SlantClipper(),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 22,
                    vertical: 8,
                  ),
                  color: _brandBright,
                  child: const Text(
                    'BANK',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                      fontStyle: FontStyle.italic,
                      letterSpacing: 1,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              SizedBox(
                width: twoCols ? 520 : 330,
                child: Text(
                  benchNames.map((n) => n.toUpperCase()).join(', '),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          );
    final inner = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: EdgeInsets.only(left: twoCols ? 0 : 24),
          child: rows,
        ),
        if (bench != null) ...[
          const SizedBox(height: 14),
          SizedBox(
            width: twoCols ? 640 : 460,
            child: Container(
              height: 1.5,
              color: Colors.white.withValues(alpha: 0.35),
            ),
          ),
          const SizedBox(height: 12),
          bench,
        ],
      ],
    );
    final pad = const EdgeInsets.fromLTRB(22, 18, 22, 18);
    final deco = BoxDecoration(
      color: Colors.black.withValues(alpha: 0.28),
      borderRadius: BorderRadius.circular(26),
      border: Border.all(color: _brandBright.withValues(alpha: 0.85), width: 2),
      boxShadow: [
        BoxShadow(
          color: _brandBright.withValues(alpha: 0.45),
          blurRadius: 18,
          spreadRadius: 1,
        ),
      ],
    );
    if (size != null) {
      return _fixedBox(
        size,
        padding: pad,
        decoration: deco,
        fillWidth: false,
        content: (_) => inner,
      );
    }
    return Container(
      constraints: const BoxConstraints(minWidth: 500),
      padding: pad,
      decoration: deco,
      child: inner,
    );
  }

  /// Hintergrund-Basis: Verlauf, optional mit eigenem Hintergrundbild + Tönung.
  /// Wird von allen Layouts genutzt.
  Widget _bgBase({bool radial = false}) {
    if (hideBackground) return const SizedBox.expand();
    final raw = _bgBaseRaw(radial: radial);
    // Gleicher Aufbau auch im Stillstand (sonst blitzt das Bild beim Wechsel).
    final a = anim, t = animT;
    final b = (a == null || t == null || a.bg == 'none')
        ? (scale: 1.0, offset: Offset.zero)
        : bgTransform(a.bg, t, a.seconds);
    return ClipRect(
      child: Transform.scale(
        scale: b.scale,
        child: FractionalTranslation(translation: b.offset, child: raw),
      ),
    );
  }

  Widget _bgBaseRaw({bool radial = false}) {
    // Hinzugefügtes Hintergrund-Foto hat Vorrang vor dem eingestellten Bild.
    final bgBytes = TeamLogo.decode(photoBg) ?? TeamLogo.decode(bgImage);
    // radial = Strahl/Vignette (heller Punkt oben-mitte → dunkel zu den Rändern),
    // wie beim Spieler-Poster; sonst klassischer Verlauf oben→unten.
    final shape = gradShape;
    final Gradient baseGradient = shape != null
        ? bgGradient(shape, gradTop, gradBottom)
        : radial
        ? RadialGradient(
            center: const Alignment(0, -0.35),
            radius: 1.2,
            colors: [gradTop, gradBottom],
          )
        : LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [gradTop, gradBottom],
          );
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(decoration: BoxDecoration(gradient: baseGradient)),
        if (bgPattern > 0) CustomPaint(painter: BgPatternPainter(bgPattern)),
        if (bgBytes != null) ...[
          if (bgOpacity < 1.0 || bgBlend != BlendMode.srcOver)
            _BlendLayer(
              opacity: bgOpacity,
              mode: bgBlend,
              child: Image.memory(
                bgBytes,
                fit: BoxFit.cover,
                gaplessPlayback: true,
              ),
            )
          else
            Image.memory(bgBytes, fit: BoxFit.cover, gaplessPlayback: true),
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  gradTop.withValues(alpha: overlayOpacity),
                  gradBottom.withValues(alpha: overlayOpacity),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// Dünne Trennlinie zwischen Kopfbereich (Logo/Spielinfo) und Spielerliste.
  Widget _divider() => Container(
    height: 2.5,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(1),
      gradient: LinearGradient(
        stops: const [0, 0.2, 0.8, 1],
        colors: [
          Colors.white.withValues(alpha: 0.1),
          Colors.white.withValues(alpha: 0.9),
          Colors.white.withValues(alpha: 0.9),
          Colors.white.withValues(alpha: 0.1),
        ],
      ),
      boxShadow: [
        BoxShadow(color: _brandBright.withValues(alpha: 0.9), blurRadius: 10),
      ],
    ),
  );

  /// Kopfleiste: Vereinslogo + „VEREIN / STARTELF" über die volle Breite
  /// (der Hauptsponsor sitzt rechts neben der Spielinfo, siehe [_infoRow]) –
  /// so wird der Text nie abgeschnitten oder winzig.
  Widget _header() {
    final logoBytes = TeamLogo.decode(logo);
    // Überschrift: wählbar wie bei der Ankündigung (Standard/Eigener Text).
    final rubric = posterHeadline;
    final logoW = logoBytes != null
        ? _logoChip(logoBytes, height: compact ? 52 : 66, circle: logoCircle)
        : (logo != null
              ? TeamLogo(logoPath: logo, size: compact ? 52 : 66)
              : null);
    // Ergebnis: ohne Vereinslogo oben (steht groß beim Spielstand).
    final showLogo = result == null && logoW != null;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (showLogo) ...[_stdEl('std_logo', logoW), const SizedBox(width: 12)],
        // Align → Objekt nur so breit wie der Text (gleiche Lage wie zuvor).
        Expanded(
          child: Align(
            alignment: result != null && !compact
                ? Alignment.center
                : Alignment.centerLeft,
            child: _stdEl(
              'std_title',
              Column(
                crossAxisAlignment: switch (_alignOf(
                  'std_title',
                  TextAlign.left,
                )) {
                  TextAlign.center => CrossAxisAlignment.center,
                  TextAlign.right => CrossAxisAlignment.end,
                  _ => CrossAxisAlignment.start,
                },
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Vereinsname immer vollständig (notfalls verkleinert, nie „…").
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      title.toUpperCase(),
                      maxLines: 1,
                      softWrap: false,
                      // Vereinsname: Standardschrift, aber Farbe + Schatten
                      // wie die Überschrift.
                      style: _shadowed(
                        'std_title',
                        TextStyle(
                          color: switch (posterTexts['std_title']) {
                            final o? => _resolveTextColor(o.color),
                            null => Colors.white,
                          },
                          fontSize: compact ? 13 : 17,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.5,
                        ),
                      ),
                    ),
                  ),
                  // Überschrift automatisch verkleinern, falls sie nicht in die
                  // Breite passt → wird NIE abgeschnitten (z.B. „ERGEBNIS").
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: _resultBand(
                      Text(
                        rubric,
                        softWrap: false,
                        textAlign: _alignOf('std_title', TextAlign.left),
                        style: _styledFixed(
                          'std_title',
                          defFont: posterFont,
                          TextStyle(
                            color: Colors.white,
                            fontSize: compact ? 36 : 46,
                            fontWeight: FontWeight.w900,
                            fontStyle: FontStyle.italic,
                            letterSpacing: 1,
                            height: 1.0,
                            shadows: const [
                              Shadow(color: Colors.black54, blurRadius: 10),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        // Post-Format (1:1): „Präsentiert von" rechts in derselben Leiste
        // (spart Höhe; die Breite reicht hier für Vereinsname + Überschrift).
        if (compact && _presentedByBlock() != null) ...[
          const SizedBox(width: 10),
          _presentedByBlock()!,
        ],
      ],
    );
  }

  /// „Präsentiert von"-Text als eigenes Objekt: Inhalt/Schrift/Farbe über
  /// [posterTexts] änderbar, sonst [fallback] im Standard-Stil [base].
  Widget _sponsorLabel(String id, TextStyle base, String fallback) {
    final o = posterTexts[id];
    final text = (o != null && o.text.trim().isNotEmpty) ? o.text : fallback;
    final style = o == null
        ? base
        : posterFontStyle(
            o.font,
            base.copyWith(color: _resolveTextColor(o.color)),
          );
    return _freeText(id, text, style);
  }

  /// Sponsor-Logo (bzw. Name im Text-Modus) des Hauptsponsors.
  Widget _mainSponsorMark({required double logoH, required double nameSize}) {
    final sponsorLogo = TeamLogo.decode(mainSponsor!.logo);
    if (sponsorLogo != null && mainSponsorMode != 'text') {
      return _logoChip(sponsorLogo, height: logoH, mode: mainSponsor!.chip);
    }
    return Text(
      mainSponsor!.name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: Colors.white,
        fontSize: nameSize,
        fontWeight: FontWeight.w900,
      ),
    );
  }

  /// „Präsentiert von" + Sponsor (Post, untereinander). Text und Logo sind
  /// ZWEI eigene Objekte ([id]_text und [id]). null = kein/aus.
  Widget? _presentedByBlock({String id = 'std_sponsor'}) {
    if (mainSponsor == null || !showMainSponsor) return null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        _stdEl(
          '${id}_text',
          _sponsorLabel(
            '${id}_text',
            TextStyle(
              color: Colors.white.withValues(alpha: 0.9),
              fontSize: compact ? 8 : 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.5,
            ),
            'PRÄSENTIERT VON',
          ),
        ),
        SizedBox(height: compact ? 4 : 5),
        _stdEl(
          id,
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: compact ? 130 : 168),
            child: _mainSponsorMark(
              logoH: compact ? 38 : 50,
              nameSize: compact ? 16 : 21,
            ),
          ),
        ),
      ],
    );
  }

  /// Story: „Präsentiert von" + Logo nebeneinander – ebenfalls zwei eigene
  /// Objekte. [scrim] = Text auf dunklem Feld (über Fotos lesbar).
  Widget? _presentedByTopRow({String id = 'std_sponsor', bool scrim = false}) {
    if (mainSponsor == null || !showMainSponsor) return null;
    Widget label = _sponsorLabel(
      '${id}_text',
      TextStyle(
        color: Colors.white.withValues(alpha: 0.9),
        fontSize: 10,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.5,
      ),
      'PRÄSENTIERT VON',
    );
    if (scrim) {
      label = Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(10),
        ),
        child: label,
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Längerer eigener Text bricht um statt die Zeile zu sprengen.
        _stdEl(
          '${id}_text',
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 150),
            child: label,
          ),
        ),
        const SizedBox(width: 10),
        _stdEl(
          id,
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 190),
            child: _mainSponsorMark(logoH: 46, nameSize: 21),
          ),
        ),
      ],
    );
  }

  Widget _lineupBlock({Size? size}) {
    final numStyle = TextStyle(
      color: _accent.withValues(alpha: 0.95),
      fontSize: 26,
      fontWeight: FontWeight.w900,
      fontFeatures: const [ui.FontFeature.tabularFigures()],
    );
    const nameStyle = TextStyle(
      color: Colors.white,
      fontSize: 27,
      fontWeight: FontWeight.w900,
      letterSpacing: 0.5,
      height: 1.05,
    );
    final posStyle = TextStyle(
      color: Colors.white.withValues(alpha: 0.72),
      fontSize: 13,
      fontWeight: FontWeight.w700,
      letterSpacing: 1,
    );
    final inner = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final p in starters)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: 46,
                  child: Text(p.number?.toString() ?? '', style: numStyle),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(p.name.toUpperCase(), style: nameStyle),
                    if (p.position != null && p.position!.isNotEmpty)
                      Text(p.position!.toUpperCase(), style: posStyle),
                  ],
                ),
              ],
            ),
          ),
        if (benchNames.isNotEmpty) ...[
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'BANK',
                style: TextStyle(
                  color: _accent.withValues(alpha: 0.95),
                  fontSize: 17,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 300,
                child: Text(
                  benchNames.map((n) => n.toUpperCase()).join(', '),
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.92),
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    height: 1.3,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
    // Dunkler Scrim, damit der Kader auf Fotos/Verlauf klar im Fokus steht.
    final pad = EdgeInsets.symmetric(
      horizontal: compact ? 14 : 18,
      vertical: compact ? 10 : 16,
    );
    final deco = BoxDecoration(
      color: Colors.black.withValues(alpha: 0.32),
      borderRadius: BorderRadius.circular(18),
    );
    // Gezogene Größe: Kasten fest, Kader behält seine Größe (mittig), wird nur
    // bei Platzmangel verkleinert.
    if (size != null) {
      return _fixedBox(
        size,
        padding: pad,
        decoration: deco,
        fillWidth: false,
        content: (_) => inner,
      );
    }
    return Container(padding: pad, decoration: deco, child: inner);
  }

  // ------------------------------------------------ ENDSTAND (Ergebnis mit Foto)

  /// Heim links / Gast rechts (wie üblich), unabhängig davon, wer „wir" sind.
  ({
    String homeName,
    String awayName,
    Uint8List? homeLogo,
    Uint8List? awayLogo,
    int homeScore,
    int awayScore,
    List<({int minute, String name, String? photo})> homeGoals,
    List<({int minute, String name, String? photo})> awayGoals,
  })
  _ftSides() {
    final r = result!;
    final own = TeamLogo.decode(logo);
    final opp = TeamLogo.decode(opponentLogo);
    return isHome
        ? (
            homeName: title,
            awayName: opponentName,
            homeLogo: own,
            awayLogo: opp,
            homeScore: r.ownScore,
            awayScore: r.oppScore,
            homeGoals: r.ownGoals,
            awayGoals: r.oppGoals,
          )
        : (
            homeName: opponentName,
            awayName: title,
            homeLogo: opp,
            awayLogo: own,
            homeScore: r.oppScore,
            awayScore: r.ownScore,
            homeGoals: r.oppGoals,
            awayGoals: r.ownGoals,
          );
  }

  /// ENDSTAND-Layout: oben das (verschieb-/zoombare) Foto, unten auf dem
  /// eingestellten Hintergrund Überschrift, Ergebnis-Balken und Torschützen.
  /// Alle Teile sind eigene Objekte (std_ft_*), die Kästen in Breite/Höhe
  /// ziehbar.
  Widget _endstandLayout() {
    final pad = compact ? 14.0 : 20.0;
    final photo = TeamLogo.decode(ftPhoto);
    final sponsorTop = _presentedByTopRow(id: 'std_ft_sponsor', scrim: true);

    final photoArea = ClipRect(
      child: photo == null
          // Platzhalter ohne Foto: der eingestellte Hintergrund (Verlauf mit
          // Form/Muster bzw. Hintergrundbild).
          ? _bgBase()
          : InteractiveViewer(
              transformationController: ftController,
              minScale: 0.5,
              maxScale: 5,
              boundaryMargin: const EdgeInsets.all(double.infinity),
              clipBehavior: Clip.none,
              onInteractionEnd: (_) => onFtPhotoChanged?.call(),
              // FittedBox statt Image(fit: cover): das Bild füllt die Fläche
              // wie bisher, wird aber NICHT auf sie zugeschnitten – beim
              // Verkleinern/Verschieben kommt der Rest des Fotos zum Vorschein.
              child: FittedBox(
                fit: BoxFit.cover,
                clipBehavior: Clip.none,
                child: Image.memory(photo, gaplessPlayback: true),
              ),
            ),
    );

    final titleW = FittedBox(
      fit: BoxFit.scaleDown,
      child: _slantBand(
        Text(
          posterHeadline,
          softWrap: false,
          textAlign: _alignOf('std_ft_title'),
          style: _styledFixed(
            'std_ft_title',
            defFont: posterFont,
            TextStyle(
              color: Colors.white,
              fontSize: compact ? 34 : 50,
              fontWeight: FontWeight.w900,
              fontStyle: FontStyle.italic,
              letterSpacing: 1,
              height: 1.0,
              shadows: [
                Shadow(
                  color: Colors.black.withValues(alpha: 0.45),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final gap = compact ? 8.0 : 14.0;
    final hasBar = barSponsors.isNotEmpty && showOtherSponsors;
    // Mindesthöhe für Überschrift + Balken (+ Sponsoren) + etwas Torschützen.
    // Ist unten weniger Platz (z. B. Trennlinie weit unten), wird der ganze
    // Block verkleinert statt überzulaufen.
    final minNeeded =
        (compact ? 42.0 : 58.0) +
        2 * gap +
        (boxSize['std_ft_banner']?.height ?? (compact ? 60.0 : 84.0)) +
        36 +
        (hasBar ? (compact ? 6 : 10) + (compact ? 26 : 32) + 22 : 0);

    final bottomContent = Padding(
      padding: EdgeInsets.fromLTRB(pad, compact ? 10 : 18, pad, pad),
      child: LayoutBuilder(
        builder: (_, c) {
          final col = _ftBottomColumn(titleW, gap, hasBar);
          if (c.maxHeight >= minNeeded) return col;
          return FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.topCenter,
            child: SizedBox(width: c.maxWidth, height: minNeeded, child: col),
          );
        },
      ),
    );
    // Ohne Foto liegt EIN durchgehender Hintergrund unter allem (sonst
    // entstünde an der Trennlinie eine Naht im Muster/Verlauf).
    final bottom = photo == null
        ? bottomContent
        : Stack(fit: StackFit.expand, children: [_bgBase(), bottomContent]);

    final split = ftSplit.clamp(0.2, 0.85);
    final topFlex = (split * 1000).round();
    // Post (1:1): Foto über die GANZE Fläche, ENDSTAND/Spielstand/Torschützen
    // liegen unten auf einem Verlauf über dem Foto (wie im Vorbild).
    if (compact) {
      return Stack(
        fit: StackFit.expand,
        children: [
          photoArea,
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: [
                      (split - 0.18).clamp(0.0, 1.0),
                      (split + 0.06).clamp(0.0, 1.0),
                      1,
                    ],
                    colors: [
                      gradBottom.withValues(alpha: 0),
                      gradBottom.withValues(alpha: 0.82),
                      gradBottom.withValues(alpha: 0.96),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(flex: topFlex, child: const SizedBox.shrink()),
              Expanded(flex: 1000 - topFlex, child: bottomContent),
            ],
          ),
          if (sponsorTop != null)
            Positioned(top: pad * 0.6, right: pad * 0.6, child: sponsorTop),
        ],
      );
    }
    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: topFlex,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (photo != null) photoArea,
              // Foto läuft unten weich in den Hintergrund aus.
              if (photo != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: compact ? 40 : 90,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [gradTop.withValues(alpha: 0), gradTop],
                        ),
                      ),
                    ),
                  ),
                ),
              // „Präsentiert von" oben rechts über dem Foto (lesbar auf Scrim).
              if (sponsorTop != null)
                Positioned(top: pad * 0.6, right: pad * 0.6, child: sponsorTop),
            ],
          ),
        ),
        Expanded(flex: 1000 - topFlex, child: bottom),
      ],
    );
    if (photo != null) return column;
    return Stack(fit: StackFit.expand, children: [_bgBase(), column]);
  }

  /// Unterer ENDSTAND-Block: Überschrift, Ergebnis-Balken, Torschützen,
  /// Sponsoren (alle als eigene, frei gestaltbare Objekte).
  Widget _ftBottomColumn(Widget titleW, double gap, bool hasBar) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(child: _stdEl('std_ft_title', titleW)),
        SizedBox(height: gap),
        // Center → Balken nur so breit wie Logos + Ergebnis (Objekt-
        // Rahmen/Griffe sitzen am Balken, nicht an der ganzen Zeile).
        Center(
          child: _boxSlot(
            'std_ft_banner',
            _ftBanner(),
            (s) => _ftBanner(size: s),
          ),
        ),
        SizedBox(height: gap),
        Expanded(
          child: Align(
            alignment: Alignment.topCenter,
            child: _boxSlot(
              'std_ft_scorers',
              LayoutBuilder(
                builder: (_, c) => FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.topCenter,
                  child: _ftScorersContent(c.maxWidth),
                ),
              ),
              (s) => _fixedBox(
                s,
                padding: const EdgeInsets.all(6),
                decoration: const BoxDecoration(),
                fillWidth: false,
                content: (w) => _ftScorersContent(w),
              ),
            ),
          ),
        ),
        if (hasBar) ...[
          SizedBox(height: compact ? 6 : 10),
          _boxSlot(
            'std_ft_sponsorbar',
            _sponsorBar(),
            (s) => _sponsorBar(size: s),
          ),
        ],
      ],
    );
  }

  /// Ergebnis-Balken: Heim-Logo · Ergebnis-Feld (Trapez) · Gast-Logo auf einer
  /// weißen Leiste – ohne Vereinsnamen (die Logos reichen). [size] = gezogene
  /// Größe (Breite = Abstand der Logos, Höhe = Höhe des Ergebnis-Felds).
  Widget _ftBanner({Size? size}) {
    final sd = _ftSides();
    final badgeH = size?.height ?? (compact ? 60.0 : 84.0);
    final pillH = badgeH / 1.6;
    final logoH = badgeH * 1.05;
    final badgeW = badgeH * 1.9;
    final gap = badgeH * 0.45;
    final width = size?.width ?? (badgeW + 2 * gap + 2 * logoH);
    Widget logoW(Uint8List? b) => b == null
        ? SizedBox(width: logoH, height: logoH)
        : Container(
            width: logoH,
            height: logoH,
            padding: EdgeInsets.all(logoH * 0.09),
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4),
                  blurRadius: 12,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: ClipOval(
              child: Image.memory(
                b,
                fit: BoxFit.contain,
                gaplessPlayback: true,
              ),
            ),
          );

    final banner = Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
        // Weiße Leiste von Logo-Mitte zu Logo-Mitte.
        Positioned(
          left: logoH / 2,
          right: logoH / 2,
          top: (badgeH - pillH) / 2,
          height: pillH,
          child: DecoratedBox(
            decoration: BoxDecoration(
              // Silbrig glänzende Leiste.
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.white,
                  const Color(0xFFD9DDE0),
                  const Color(0xFFB8BEC2),
                ],
              ),
              borderRadius: BorderRadius.circular(4),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.35),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
          ),
        ),
        // Ergebnis-Feld: schräg, in Vereinsfarbe, weiße Zahlen.
        ClipPath(
          clipper: const _SlantClipper(),
          child: Container(
            width: badgeW,
            height: badgeH,
            alignment: Alignment.center,
            padding: EdgeInsets.symmetric(horizontal: badgeW * 0.16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color.lerp(_brandBright, Colors.white, 0.15)!,
                  Color.lerp(_brandBright, Colors.black, 0.35)!,
                ],
              ),
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                '${sd.homeScore} - ${sd.awayScore}',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: badgeH * 0.62,
                  fontWeight: FontWeight.w900,
                  height: 1.0,
                  shadows: const [Shadow(color: Colors.black45, blurRadius: 8)],
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          child: Center(child: logoW(sd.homeLogo)),
        ),
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          child: Center(child: logoW(sd.awayLogo)),
        ),
      ],
    );
    return SizedBox(width: width, height: badgeH, child: banner);
  }

  /// Torschützen je Seite, je Spieler gruppiert („B. KANIA 35' 40' 54' 60'").
  /// Links Heim, rechts Gast; Spalten bis an die Ränder von [width].
  Widget _ftScorersContent(double width) {
    final sd = _ftSides();
    final home = groupScorers(sd.homeGoals);
    final away = groupScorers(sd.awayGoals);
    if (home.isEmpty && away.isEmpty) return const SizedBox.shrink();
    final labelStyle = TextStyle(
      color: Colors.white,
      fontSize: compact ? 15 : 19,
      fontWeight: FontWeight.w800,
      letterSpacing: 1,
    );
    final minStyle = TextStyle(
      color: Colors.white.withValues(alpha: 0.92),
      fontSize: compact ? 15 : 19,
      fontWeight: FontWeight.w700,
    );
    Widget line(({String label, List<int> minutes}) g) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (g.label.isNotEmpty) ...[
            Text(g.label, style: labelStyle),
            const SizedBox(width: 12),
          ] else ...[
            // Unbekannter Torschütze → Ball-Symbol statt „Gegner".
            Icon(
              Icons.sports_soccer,
              size: (minStyle.fontSize ?? 17) + 1,
              color: Colors.white,
            ),
            const SizedBox(width: 8),
          ],
          Text(g.minutes.map((m) => "$m'").join('  '), style: minStyle),
        ],
      ),
    );
    Widget col(List<({String label, List<int> minutes})> list, bool end) =>
        Column(
          crossAxisAlignment: end
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [for (final g in list) line(g)],
        );
    // Heim | Gast mittig mit Trennstrich, darüber und darunter eine
    // leuchtende Linie. Das umgebende FittedBox verkleinert bei Platzmangel.
    Widget glowLine() => Container(
      height: 1.5,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Colors.white.withValues(alpha: 0),
            Colors.white.withValues(alpha: 0.75),
            Colors.white.withValues(alpha: 0),
          ],
        ),
        boxShadow: [
          BoxShadow(color: _brandBright.withValues(alpha: 0.8), blurRadius: 8),
        ],
      ),
    );
    // Mindestens [width] breit; ist der Inhalt breiter, verkleinert das
    // umgebende FittedBox alles gleichmäßig (kein Überlauf).
    return ConstrainedBox(
      constraints: BoxConstraints(minWidth: width),
      child: IntrinsicWidth(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            glowLine(),
            SizedBox(height: compact ? 6 : 10),
            Center(
              child: IntrinsicHeight(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (home.isNotEmpty) col(home, false),
                    if (home.isNotEmpty && away.isNotEmpty)
                      Container(
                        width: 2,
                        margin: const EdgeInsets.symmetric(horizontal: 22),
                        color: Colors.white.withValues(alpha: 0.7),
                      ),
                    if (away.isNotEmpty) col(away, false),
                  ],
                ),
              ),
            ),
            SizedBox(height: compact ? 6 : 10),
            glowLine(),
          ],
        ),
      ),
    );
  }

  /// Großer, fixer Spielstand (der Blickfang): Logos + riesiger Score + Namen.
  Widget _scoreRow() {
    final r = result!;
    final ownLogo = TeamLogo.decode(logo);
    final oppLogo = TeamLogo.decode(opponentLogo);
    final d = compact ? 84.0 : 118.0;

    // Logo groß auf weißem Kreis (wie im Vorbild), zentriert.
    Widget side(Uint8List? bytes) => bytes == null
        ? SizedBox(height: d)
        : Container(
            width: d,
            height: d,
            padding: EdgeInsets.all(d * 0.09),
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: ClipOval(
              child: Image.memory(
                bytes,
                fit: BoxFit.contain,
                gaplessPlayback: true,
              ),
            ),
          );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Heim links, Gast rechts: auswärts Gegner-Logo und -Tore vorn.
        Expanded(child: Center(child: side(isHome ? ownLogo : oppLogo))),
        // Flexible + FittedBox: auch zweistellige Stände („10 : 12") passen
        // immer – verkleinern statt überlaufen.
        Flexible(
          flex: 2,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: _resultBand(
                Text(
                  isHome
                      ? _countStr('std_score', '${r.ownScore} : ${r.oppScore}')
                      : _countStr('std_score', '${r.oppScore} : ${r.ownScore}'),
                  maxLines: 1,
                  softWrap: false,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: compact ? 64 : 96,
                    fontWeight: FontWeight.w900,
                    height: 1.0,
                    shadows: [
                      Shadow(
                        color: Colors.black.withValues(alpha: 0.5),
                        blurRadius: 16,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        Expanded(child: Center(child: side(isHome ? oppLogo : ownLogo))),
      ],
    );
  }

  /// Torschützen (NUR Tore – keine Karten): je Seite „Minute' Name" + optional
  /// Spielerfoto. Lesbar auf dunklem Scrim; der FittedBox im Layout skaliert bei
  /// vielen Einträgen herunter, bei wenigen bleibt es groß.
  Widget _scorersCardsBlock({Size? size}) {
    final r = result!;
    final ownGoals = r.ownGoals;
    final oppGoals = r.oppGoals;
    if (ownGoals.isEmpty && oppGoals.isEmpty) return const SizedBox.shrink();

    Widget avatar(String? photo) {
      final bytes = TeamLogo.decode(photo);
      if (bytes == null) return const SizedBox.shrink();
      return Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.85),
            width: 1.5,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true),
      );
    }

    // ── Zeitstrahl ────────────────────────────────────────────────────────
    // Eine Linie 0'–90' (bei Verlängerung bis zur letzten Minute); eigene Tore
    // als Punkte OBERHALB (Akzentfarbe), Gegentore UNTERHALB (weiß). Liegen
    // Tore dicht beieinander, rücken die Beschriftungen eine Etage weiter weg.
    final maxMin = [
      90,
      for (final g in ownGoals) g.minute,
      for (final g in oppGoals) g.minute,
    ].reduce(math.max);
    final minuteStyle = posterFontStyle(
      posterFont,
      const TextStyle(fontSize: 21, fontWeight: FontWeight.w900, height: 1.1),
    );
    const nameStyle = TextStyle(
      color: Colors.white,
      fontSize: 12.5,
      fontWeight: FontWeight.w800,
      letterSpacing: 0.8,
      height: 1.2,
    );
    double textW(String t, TextStyle s) {
      final tp = TextPainter(
        text: TextSpan(text: t, style: s),
        textDirection: ui.TextDirection.ltr,
        maxLines: 1,
      )..layout();
      final w = tp.width;
      tp.dispose();
      return w;
    }

    final ownLogoBytes = TeamLogo.decode(logo);
    final oppLogoBytes = TeamLogo.decode(opponentLogo);
    final hasLogos = ownLogoBytes != null || oppLogoBytes != null;

    Widget timeline(double width) {
      final x0 = hasLogos ? 40.0 : 14.0;
      final x1 = width - 34.0;
      final minLeft = hasLogos ? 32.0 : 0.0;

      // Beschriftungen einer Seite platzieren (Etage je Überlappung).
      List<_TlEntry> place(
        List<({int minute, String name, String? photo})> goals,
      ) {
        final sorted = [...goals]..sort((a, b) => a.minute.compareTo(b.minute));
        final rights = <double>[];
        final out = <_TlEntry>[];
        for (final g in sorted) {
          final name = scorerShortName(g.name);
          final photo = showPhotos && TeamLogo.decode(g.photo) != null;
          final lw =
              [
                textW("${g.minute}'", minuteStyle),
                if (name.isNotEmpty) textW(name, nameStyle),
                if (photo) 30.0,
              ].reduce(math.max) +
              12;
          final cx = x0 + (x1 - x0) * g.minute.clamp(0, maxMin) / maxMin;
          final left = (cx - lw / 2)
              .clamp(minLeft, math.max(minLeft, width - lw))
              .toDouble();
          var level = 0;
          while (level < rights.length && left < rights[level] + 6) {
            level++;
          }
          if (level == rights.length) rights.add(0);
          rights[level] = left + lw;
          out.add((
            minute: g.minute,
            name: name,
            photo: photo ? g.photo : null,
            cx: cx,
            left: left,
            lw: lw,
            level: level,
          ));
        }
        return out;
      }

      final above = place(ownGoals);
      final below = place(oppGoals);
      double labelH(List<_TlEntry> s) =>
          26 +
          (s.any((e) => e.name.isNotEmpty) ? 16 : 0) +
          (s.any((e) => e.photo != null) ? 34 : 0);
      int levels(List<_TlEntry> s) =>
          s.isEmpty ? 0 : s.map((e) => e.level).reduce(math.max) + 1;
      const stem = 14.0, gap = 4.0;
      final lhA = labelH(above), lhB = labelH(below);
      final nA = levels(above), nB = levels(below);
      final hA = nA == 0 ? 22.0 : stem + nA * lhA + (nA - 1) * gap;
      final hB = nB == 0 ? 22.0 : stem + nB * lhB + (nB - 1) * gap;
      final lineY = hA + 8;
      final height = hA + 16 + hB;

      Color colorOf(bool own) => Colors.white;
      final dotColor = Color.lerp(_brandBright, Colors.white, 0.25)!;

      final stems = <Widget>[];
      final dots = <Widget>[];
      final labels = <Widget>[];
      void addSide(List<_TlEntry> side, {required bool own}) {
        final lh = own ? lhA : lhB;
        final c = colorOf(own);
        for (final e in side) {
          final off = stem + e.level * (lh + gap);
          final top = own ? lineY - off - lh : lineY + off;
          final stemTop = own ? top + lh : lineY;
          final stemH = own ? lineY - (top + lh) : top - lineY;
          stems.add(
            Positioned(
              left: e.cx - 1,
              top: stemTop,
              width: 2,
              height: stemH,
              child: ColoredBox(color: c.withValues(alpha: 0.8)),
            ),
          );
          dots.add(
            Positioned(
              left: e.cx - 7,
              top: lineY - 7,
              width: 14,
              height: 14,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(color: dotColor, width: 3),
                  boxShadow: [
                    BoxShadow(
                      color: dotColor.withValues(alpha: 0.9),
                      blurRadius: 10,
                      spreadRadius: 1,
                    ),
                  ],
                ),
              ),
            ),
          );
          final parts = <Widget>[
            if (e.photo != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: avatar(e.photo),
              ),
            Text(
              "${e.minute}'",
              maxLines: 1,
              softWrap: false,
              style: minuteStyle.copyWith(color: c),
            ),
            if (e.name.isNotEmpty)
              Text(e.name, maxLines: 1, softWrap: false, style: nameStyle),
          ];
          labels.add(
            Positioned(
              left: e.left,
              top: top,
              width: e.lw,
              height: lh,
              child: Column(
                mainAxisAlignment: own
                    ? MainAxisAlignment.end
                    : MainAxisAlignment.start,
                children: own ? parts : parts.reversed.toList(),
              ),
            ),
          );
        }
      }

      addSide(above, own: true);
      addSide(below, own: false);

      Widget miniLogo(Uint8List b) => Container(
        width: 30,
        height: 30,
        padding: const EdgeInsets.all(2),
        decoration: const BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
        ),
        child: ClipOval(child: Image.memory(b, fit: BoxFit.contain)),
      );

      final xHalf = x0 + (x1 - x0) * 45 / maxMin;
      return SizedBox(
        width: width,
        height: height,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // Linie (links kräftiger → rechts) + Halbzeit-Markierung.
            Positioned(
              left: x0,
              width: x1 - x0,
              top: lineY - 1.5,
              height: 3,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(2),
                  gradient: LinearGradient(
                    colors: [
                      dotColor.withValues(alpha: 0.35),
                      dotColor,
                      dotColor.withValues(alpha: 0.35),
                    ],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: dotColor.withValues(alpha: 0.6),
                      blurRadius: 8,
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: xHalf - 1,
              top: lineY - 6,
              width: 2,
              height: 12,
              child: ColoredBox(color: Colors.white.withValues(alpha: 0.6)),
            ),
            // Endmarke nur, wenn kein Tor kurz vor Schluss dort liegt.
            if (![...ownGoals, ...oppGoals].any((g) => g.minute >= maxMin - 6))
              Positioned(
                left: x1 + 6,
                top: lineY - 8,
                child: Text(
                  "$maxMin'",
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            if (ownLogoBytes != null && ownGoals.isNotEmpty)
              Positioned(
                left: 0,
                top: lineY - 30,
                child: miniLogo(ownLogoBytes),
              ),
            if (oppLogoBytes != null && oppGoals.isNotEmpty)
              Positioned(
                left: 0,
                top: lineY + 4,
                child: miniLogo(oppLogoBytes),
              ),
            ...stems,
            ...dots,
            ...labels,
          ],
        ),
      );
    }

    // Überschrift „⚽ TORE" zwischen zwei Linien, immer oben.
    final hLine = Expanded(
      child: Container(height: 1.5, color: Colors.white.withValues(alpha: 0.6)),
    );
    Widget header = Row(
      children: [
        hLine,
        const SizedBox(width: 14),
        const Icon(Icons.sports_soccer, size: 24, color: Colors.white),
        const SizedBox(width: 8),
        Text(
          'TORE',
          style: posterFontStyle(
            posterFont,
            const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w900,
              letterSpacing: 3,
            ),
          ),
        ),
        const SizedBox(width: 14),
        hLine,
      ],
    );
    header = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: header,
    );
    const pad = EdgeInsets.symmetric(horizontal: 18, vertical: 16);
    final deco = BoxDecoration(
      color: Colors.black.withValues(alpha: 0.25),
      borderRadius: BorderRadius.circular(24),
      border: Border.all(
        color: Color.lerp(
          _brandBright,
          Colors.white,
          0.2,
        )!.withValues(alpha: 0.9),
        width: 2,
      ),
      boxShadow: [
        BoxShadow(
          color: _brandBright.withValues(alpha: 0.5),
          blurRadius: 18,
          spreadRadius: 1,
        ),
      ],
    );
    // Gezogene Größe: Zeitstrahl so breit wie der Kasten (mind. 260, sonst
    // wird der ganze Inhalt gleichmäßig verkleinert). „TORE" bleibt oben.
    if (size != null) {
      return _fixedBox(
        size,
        padding: pad,
        decoration: deco,
        fillWidth: false,
        alignment: Alignment.topCenter,
        content: (w) => SizedBox(
          width: math.max(w, 260),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              header,
              const SizedBox(height: 12),
              timeline(math.max(w, 260)),
            ],
          ),
        ),
      );
    }

    // Feste Grundbreite; das umgebende FittedBox skaliert passend.
    return Container(
      padding: pad,
      decoration: deco,
      child: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [header, const SizedBox(height: 12), timeline(520)],
        ),
      ),
    );
  }

  /// Freier Editor für die Spielankündigung (Vorbild: Fortuna-„SPIELTAG"):
  /// Sponsor-Text oben, Logos + Überschrift + Datum/Ort, großes Spielerbild
  /// unten, optional ein rundes Zweit-Foto als Badge.
  Widget _announcementPosterLayout() {
    final a = announcement!;
    final ownLogo = TeamLogo.decode(logo);
    final oppLogo = TeamLogo.decode(opponentLogo);
    final mainBytes = TeamLogo.decode(posterMain);
    final pad = compact ? 16.0 : 22.0;
    final logoH = compact ? 46.0 : 60.0;

    // Logo entweder auf hellem Kreis (immer gut sichtbar) oder frei auf dem
    // Hintergrund wie im Vorbild (für helle/weiße Logo-Varianten).
    final logoShadow = BoxShadow(
      color: Colors.black.withValues(alpha: 0.35),
      blurRadius: 8,
      offset: const Offset(0, 2),
    );
    Widget side(Uint8List? bytes) {
      if (bytes == null) return SizedBox(height: logoH, width: logoH);
      final logoImg = Image.memory(
        bytes,
        height: logoH,
        fit: BoxFit.contain,
        gaplessPlayback: true,
      );
      if (!posterLogoDisc) {
        return DecoratedBox(
          decoration: BoxDecoration(boxShadow: [logoShadow]),
          child: logoImg,
        );
      }
      final d = logoH * 1.26;
      return Container(
        width: d,
        height: d,
        padding: EdgeInsets.all(d * 0.1),
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          boxShadow: [logoShadow],
        ),
        child: Center(child: logoImg),
      );
    }

    // Datum/Ort-Zeile „Fr. | 30. Okt. | 19:00 Uhr | ORT".
    final parts = <String>[];
    if (matchDate != null) {
      final local = matchDate!.toLocal();
      parts.add(DateFormat('EEE', 'de_DE').format(local));
      parts.add(DateFormat('dd. MMM', 'de_DE').format(local));
      if (local.hour != 0 || local.minute != 0) {
        parts.add(DateFormat('HH:mm', 'de_DE').format(local));
      }
    }
    final venue = (a.venue ?? '').trim();
    final address = (a.address ?? '').trim();
    if (venue.isNotEmpty) parts.add(venue.toUpperCase());
    if (address.isNotEmpty && address.toLowerCase() != venue.toLowerCase()) {
      parts.add(address.toUpperCase());
    }
    // Designer-Grafiken bringen ihre eigene Infozeile mit (z. B. Torschütze).
    final infoLine = infoOverride ?? parts.join(' | ');

    // Einzelne, frei verschieb- und skalierbare Elemente.
    // Hauptsponsor: Logo (bzw. Name) und „Präsentiert von" als ZWEI Objekte.
    final Widget? sponsorW = mainSponsor == null
        ? null
        : _mainSponsorMark(
            logoH: compact ? 29 : 35,
            nameSize: compact ? 14 : 17,
          );
    final Widget? sponsorTextW = mainSponsor == null
        ? null
        : _sponsorLabel(
            'sponsortext',
            TextStyle(
              color: Colors.white.withValues(alpha: 0.85),
              fontSize: compact ? 12 : 15,
              fontWeight: FontWeight.w500,
            ),
            'Präsentiert von',
          );
    final Widget? sponsorbarW = barSponsors.isEmpty
        ? null
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final s in barSponsors)
                if (TeamLogo.decode(s.logo) case final b?)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: _logoChip(
                      b,
                      height: compact ? 30 : 36,
                      mode: s.chip,
                    ),
                  ),
            ],
          );
    // Ohne Gegner (z. B. Designer: Anlass/frei) nur das eigene Logo – ohne
    // Trennstrich. Heim links, Gast rechts: auswärts steht der Gegner vorn.
    final divider = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Container(
        width: 1.5,
        height: logoH * 0.7,
        color: Colors.white.withValues(alpha: 0.5),
      ),
    );
    final Widget logosW = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: oppLogo == null
          ? [side(ownLogo)]
          : isHome
          ? [side(ownLogo), divider, side(oppLogo)]
          : [side(oppLogo), divider, side(ownLogo)],
    );
    final Widget headlineW = Text(
      posterHeadline,
      softWrap: false,
      overflow: TextOverflow.visible,
      textAlign: _alignOf('headline'),
      style: _styledFixed(
        'headline',
        const TextStyle(
          color: Colors.white,
          fontSize: 58,
          fontWeight: FontWeight.w900,
          letterSpacing: 2,
          height: 1.0,
        ),
        defFont: posterFont,
      ),
    );
    // Datum: eigener editierbarer Text (Override) ODER automatische Zeile;
    // mehrzeilig (Zeilenumbrüche via \n).
    final Widget? infoW = () {
      final o = posterTexts['info'];
      final text = (o != null && o.text.trim().isNotEmpty) ? o.text : infoLine;
      if (text.trim().isEmpty) return null;
      final col = o == null ? _accent : _resolveTextColor(o.color);
      return _freeText(
        'info',
        text,
        posterFontStyle(
          o?.font ?? posterFont,
          TextStyle(
            color: col,
            fontSize: compact ? 12 : 14,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.3,
          ),
        ),
      );
    }();
    return LayoutBuilder(
      builder: (ctx, c) {
        final w = c.maxWidth, h = c.maxHeight;

        // Spieler ans Umgebungslicht angleichen (Farbstich der Szene).
        Widget lightMatched(Widget child) {
          var out = child;
          if (playerMatch > 0) {
            out = ColorFiltered(
              colorFilter: ColorFilter.matrix(
                lightMatchMatrix(playerLight, playerMatch * 0.3),
              ),
              child: out,
            );
          }
          // Warmer, lebendiger Hautton (nur Spieler, Hintergrund bleibt).
          if (playerWarm > 0) {
            out = ColorFiltered(
              colorFilter: ColorFilter.matrix(
                buildGradeMatrix(
                  warmth: 30 * playerWarm,
                  saturation: 14 * playerWarm,
                  brightness: 5 * playerWarm,
                  contrast: 8 * playerWarm,
                ),
              ),
              child: out,
            );
          }
          if (playerShade > 0) {
            final dx = math.cos(playerLightDir), dy = math.sin(playerLightDir);
            // Führungslicht: warm (Goldton), je nach Wärme.
            final hi = Color.lerp(
              Colors.white,
              const Color(0xFFFFE2C4),
              0.2 + 0.5 * playerWarm,
            )!;
            final sh = playerShade;
            // srcATop: Licht/Schatten nur dort, wo der Spieler ist.
            out = ShaderMask(
              blendMode: BlendMode.srcATop,
              shaderCallback: (r) => LinearGradient(
                begin: Alignment(dx, dy),
                end: Alignment(-dx, -dy),
                colors: [
                  hi.withValues(alpha: 0.2 * sh),
                  hi.withValues(alpha: 0),
                  Colors.black.withValues(alpha: 0),
                  Colors.black.withValues(alpha: 0.35 * sh),
                ],
                stops: const [0, 0.42, 0.5, 1],
              ).createShader(r),
              child: out,
            );
          }
          return out;
        }

        // Bild mit optionalem Schlagschatten – gilt automatisch für JEDES Bild
        // (Spieler UND Overlays). Schatten-Silhouette (schwarz) hinter dem Bild.
        Widget imageWithShadow(
          Uint8List bytes, {
          double? width,
          double? height,
          Alignment alignment = Alignment.center,
          bool lit = false, // Hauptspieler: Licht angleichen + Leuchtkante
        }) {
          Widget raw() => SizedBox(
            width: width,
            height: height,
            child: Image.memory(
              bytes,
              fit: BoxFit.contain,
              alignment: alignment,
              gaplessPlayback: true,
            ),
          );
          Widget mk() => lit ? lightMatched(raw()) : raw();
          if (!posterShadow) return mk();
          final dist = 6 + 22 * (posterShadowStrength / 100);
          return Stack(
            children: [
              Transform.translate(
                offset: Offset(
                  math.cos(posterShadowAngle * math.pi / 180) * dist,
                  math.sin(posterShadowAngle * math.pi / 180) * dist,
                ),
                child: ImageFiltered(
                  imageFilter: ui.ImageFilter.blur(
                    sigmaX: 6 + 14 * (posterShadowStrength / 100),
                    sigmaY: 6 + 14 * (posterShadowStrength / 100),
                  ),
                  child: Opacity(
                    opacity: 0.2 + 0.55 * (posterShadowStrength / 100),
                    child: ColorFiltered(
                      colorFilter: const ColorFilter.mode(
                        Colors.black,
                        BlendMode.srcIn,
                      ),
                      child: mk(),
                    ),
                  ),
                ),
              ),
              mk(),
            ],
          );
        }

        // Rechteckiges Foto „wie vom Designer" ins Bild einblenden: randlos
        // (volle Breite), oben lang und weich auslaufend, seitlich und unten
        // sanft → Foto und Hintergrund verschmelzen, Texte liegen darüber.
        final playerInfo = mainBytes == null ? null : photoInfo(mainBytes);
        final blendPlayer =
            posterBlend && playerInfo != null && playerInfo.opaque;
        Size blendSize() {
          // Mindestens volle Breite und ~¾ der Höhe (seitlich darf es
          // anschneiden), höchstens 82 % der Höhe.
          // Querformat: einfach volle Breite.
          final a = playerInfo!.aspect;
          if (a >= 1) return Size(w, w / a);
          final ph = (w / a).clamp(h * 0.74, h * 0.82).toDouble();
          return Size(ph * a, ph);
        }

        Widget blendedPhoto(Uint8List bytes) {
          final s = blendSize();
          final fullBleed = s.width >= w - 13;
          LinearGradient fade(
            Alignment begin,
            Alignment end,
            List<double> stops,
          ) => LinearGradient(
            begin: begin,
            end: end,
            colors: const [
              Color(0x00000000),
              Color(0xFF000000),
              Color(0xFF000000),
              Color(0x00000000),
            ],
            stops: stops,
          );
          // Breiter als das Canvas → seitlich überstehen lassen (nicht
          // stauchen); sichtbar/greifbar bleibt die Canvas-Breite.
          final masked = ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (r) => fade(
              Alignment.topCenter,
              Alignment.bottomCenter,
              const [0, 0.34, 0.86, 1],
            ).createShader(r),
            child: ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (r) => fade(
                Alignment.centerLeft,
                Alignment.centerRight,
                fullBleed ? const [0, 0.07, 0.93, 1] : const [0, 0.16, 0.84, 1],
              ).createShader(r),
              child: SizedBox(
                width: s.width,
                height: s.height,
                child: Image.memory(
                  bytes,
                  fit: BoxFit.fill,
                  gaplessPlayback: true,
                ),
              ),
            ),
          );
          final vw = math.min(s.width, w - 12);
          if (vw >= s.width) return masked;
          return SizedBox(
            width: vw,
            height: s.height,
            child: OverflowBox(
              minWidth: s.width,
              maxWidth: s.width,
              minHeight: s.height,
              maxHeight: s.height,
              child: masked,
            ),
          );
        }

        // Inhalt je Element-ID (null = nicht vorhanden → wird übersprungen).
        Widget? content(String id) {
          switch (id) {
            case 'player':
              if (mainBytes == null) return null;
              if (blendPlayer) return lightMatched(blendedPhoto(mainBytes));
              // FuPa: Spieler füllt das Hochformat (volle Breite, ~95 % Höhe).
              if (fupaPlayer) {
                return imageWithShadow(
                  mainBytes,
                  width: w,
                  height: h * 0.95,
                  alignment: Alignment.bottomCenter, // Spieler steht unten
                  lit: true,
                );
              }
              return imageWithShadow(
                mainBytes,
                width: w - 2 * pad,
                height: h * 0.6,
                lit: true,
              );
            case 'sponsor':
              return showMainSponsor ? sponsorW : null;
            case 'sponsortext':
              return showMainSponsor ? sponsorTextW : null;
            case 'sponsorbar':
              return showOtherSponsors ? sponsorbarW : null;
            case 'logos':
              return logosW;
            case 'headline':
              return headlineW;
            case 'info':
              return infoW;
            default:
              if (id.startsWith('text_')) {
                final t = posterTexts[id];
                if (t == null || t.text.trim().isEmpty) return null;
                final col = _resolveTextColor(t.color);
                return _freeText(
                  id,
                  t.text,
                  posterFontStyle(
                    t.font,
                    TextStyle(
                      color: col,
                      fontSize: 34,
                      fontWeight: FontWeight.w900,
                      height: 1.0,
                    ),
                  ),
                );
              }
              final url = posterOverlays[id];
              if (url == null) return null;
              final bytes = TeamLogo.decode(url);
              if (bytes == null) return null;
              return imageWithShadow(bytes, width: w * 0.4);
          }
        }

        // Kontexte der Elemente (zum Messen der sichtbaren Mitte).
        final elCtx = <String, BuildContext>{};
        void anchor(String id) {
          if (posterCentered.contains(id)) return;
          final r = _relCenterOf(elCtx[id]);
          if (r != null) onPosterAnchor?.call(id, r);
        }

        // Weiches Licht auf der Wand hinter dem Spieler (wie ein Studio-Spot)
        // in der aufgehellten Hintergrundfarbe → trennt ihn natürlich vom
        // Hintergrund. Folgt Position und Größe des Spielers.
        Widget playerHalo() {
          final sc = posterItemScale['player'] ?? 1.0;
          final p = posterItemPos['player'];
          final Offset c;
          if (p != null && posterCentered.contains('player')) {
            c = Offset(p.dx, p.dy - 0.13 * sc);
          } else if (fupaPlayer) {
            c = const Offset(0.5, 0.4);
          } else {
            final d =
                p ?? _kPosterItemDefaults['player'] ?? const Offset(0.5, 0.6);
            c = Offset(d.dx, d.dy - 0.1);
          }
          final g = playerGlow;
          final spot = Color.lerp(
            Color.lerp(playerLight, Colors.white, 0.35)!,
            const Color(0xFFFFE2C4),
            0.15 * playerWarm,
          )!;
          return Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment(c.dx * 2 - 1, c.dy * 2 - 1),
                    radius: 1.0 * sc,
                    colors: [
                      spot.withValues(alpha: 0.6 * g),
                      spot.withValues(alpha: 0.22 * g),
                      spot.withValues(alpha: 0),
                    ],
                    stops: const [0, 0.45, 1],
                  ),
                ),
              ),
            ),
          );
        }

        // Ein frei verschieb- und skalierbares Element (tippen = auswählen).
        List<String> hitsAt(Offset p) => [
          for (final id in posterOrder.reversed)
            if (_hitsCtx(elCtx[id], p)) id,
        ];

        Widget el(String id, Widget child) {
          // Eingeblendetes Foto startet unten bündig (Unterkante = Bildrand).
          final blendDefault = id == 'player' && blendPlayer
              ? (posterCentered.contains(id)
                    ? Offset(0.5, 1 - (blendSize().height / 2 + 6) / h)
                    : const Offset(0.5, 1.0)) // Align: unten bündig
              : null;
          final pos =
              posterItemPos[id] ??
              (fupaPlayer && id == 'player'
                  ? const Offset(0.5, 1.0) // unten bündig
                  : null) ??
              blendDefault ??
              (blendPlayer ? _kBlendItemDefaults[id] : null) ??
              (posterStyle
                  ? _kPosterItemDefaults
                  : _kCenteredItemDefaults)[id] ??
              const Offset(0.5, 0.5);
          final scale = posterItemScale[id] ?? 1.0;
          final rot = posterItemRot[id] ?? 0.0;
          final selected = posterSelected == id;
          // Antippen = auswählen, Langdruck = Eigenschaften. Das VERSCHIEBEN/
          // SKALIEREN/DREHEN übernimmt eine Zieh-Ebene über allem (unten),
          // damit die Geste stabil bleibt – egal welche Größe/Ebene.
          return _placeElement(
            key: ValueKey('posterEl_$id'),
            pos: pos,
            centered: posterCentered.contains(id),
            w: w,
            h: h,
            child: Transform.rotate(
              angle: rot,
              child: Transform.scale(
                scale: scale,
                child: Builder(
                  builder: (bctx) {
                    elCtx[id] = bctx;
                    stdCtx?[id] = bctx; // Größe für den Dreh-Griff
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (_) => anchor(id),
                      onTapUp: (d) => _tapAt(d.globalPosition, id, hitsAt),
                      onLongPress: () => onPosterLongPress?.call(id),
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: selected
                            ? BoxDecoration(
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.9),
                                ),
                                borderRadius: BorderRadius.circular(4),
                              )
                            : null,
                        child: child,
                      ),
                    );
                  },
                ),
              ),
            ),
          );
        }

        // Ebenen in echter Reihenfolge (hinten → vorne).
        final layers = <Widget>[];
        for (final id in posterOrder) {
          final child = content(id);
          if (child == null) continue;
          if (id == 'player' && playerGlow > 0) layers.add(playerHalo());
          layers.add(el(id, child));
        }

        // Zieh-Ebene ganz oben: bewegt das aktuell gewählte Element. Translucent →
        // Tippen geht zu den Elementen durch (Auswahl), Ziehen bewegt das Gewählte.
        final sel = posterSelected;
        // Gewähltes, noch nicht umgerechnetes Element (z. B. per Code gewählt)
        // nach dem Frame auf Mittelpunkt-Position umstellen.
        if (sel != null && !posterCentered.contains(sel)) {
          WidgetsBinding.instance.addPostFrameCallback((_) => anchor(sel));
        }
        // Oberstes Element am Punkt (vorne zuerst).
        String? hitAt(Offset p) {
          for (final id in posterOrder.reversed) {
            if (_hitsCtx(elCtx[id], p)) return id;
          }
          return null;
        }

        // Zieh-Ebene: ein Finger auf einem Element → dieses wählen und direkt
        // ziehen; auf freier Fläche (oder mit zwei Fingern) wird das gewählte
        // Element bewegt/gepincht/gedreht. KEINE Grenze. Ohne Auswahl greift sie
        // nur über Elementen (leere Fläche → Hintergrund-Gesten).
        final dragLayer = Positioned.fill(
          child: _HitWhere(
            test: (p) => sel != null || hitAt(p) != null,
            child: Listener(
              // Mausrad über einem Objekt (oder mit Auswahl) → dieses Objekt
              // skalieren statt die ganze Ansicht zu zoomen.
              onPointerSignal: (e) {
                if (e is! PointerScrollEvent || onPosterWheel == null) return;
                final target = hitAt(e.localPosition) ?? sel;
                if (target == null) return;
                GestureBinding.instance.pointerSignalResolver.register(e, (ev) {
                  if (target != sel) onPosterSelect?.call(target);
                  onPosterWheel!(
                    target,
                    (ev as PointerScrollEvent).scrollDelta.dy,
                  );
                });
              },
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onScaleStart: (d) {
                  var target = sel;
                  if (d.pointerCount < 2) {
                    // Gewähltes unter dem Finger behalten (auch wenn es unter
                    // einem anderen liegt), sonst das oberste nehmen.
                    final hs = hitsAt(d.localFocalPoint);
                    target = sel != null && hs.contains(sel)
                        ? sel
                        : (hs.isEmpty ? sel : hs.first);
                  }
                  if (target != null && target != sel) {
                    onPosterSelect?.call(target);
                  }
                  if (target != null) anchor(target);
                  onPosterGestureStart?.call(target);
                },
                onScaleUpdate: (d) =>
                    onPosterGestureUpdate?.call(sel ?? '', d, w, h),
                onScaleEnd: (_) => onPosterGestureEnd?.call(),
              ),
            ),
          ),
        );

        return Stack(
          key: canvasKey,
          fit: StackFit.expand,
          children: [
            _bgBase(radial: true),
            // Scrim oben → Texte bleiben über Bild/Hintergrund lesbar. FuPa-Foto
            // hat keinen Text → Hintergrund (Logo!) unverfälscht zeigen.
            if (!fupaPlayer)
              Align(
                alignment: Alignment.topCenter,
                child: FractionallySizedBox(
                  widthFactor: 1,
                  heightFactor: 0.5,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.45),
                          Colors.black.withValues(alpha: 0.0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            // Hintergrund-Gesten ÜBER Hintergrundbild und Scrim (die würden sie
            // sonst abfangen): Tippen auf leere Fläche = Auswahl aufheben,
            // Langdruck = Hinzufügen/Hintergrund-Menü. Elemente liegen darüber.
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: onBackgroundTap,
                onLongPress: onBackgroundLongPress,
              ),
            ),
            ...layers,
            dragLayer,
            // Dreh-Griff (oben über allem, damit er die Geste bekommt).
            ?_rotationHandle(sel, w, h),
          ],
        );
      },
    );
  }

  Widget _sponsorBar({Size? size}) {
    const pad = EdgeInsets.symmetric(vertical: 8, horizontal: 8);
    final deco = BoxDecoration(
      color: Colors.white.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(8),
    );
    final logos = Wrap(
      alignment: WrapAlignment.center,
      runAlignment: WrapAlignment.center,
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final s in barSponsors)
          if (TeamLogo.decode(s.logo) != null)
            _logoChip(
              TeamLogo.decode(s.logo)!,
              height: compact ? 26 : 32,
              mode: s.chip,
            ),
      ],
    );
    // Gezogene Größe: Logos verteilen/umbrechen sich in der neuen Breite.
    if (size != null) {
      return _fixedBox(
        size,
        padding: pad,
        decoration: deco,
        content: (_) => logos,
      );
    }
    return Container(padding: pad, decoration: deco, child: logos);
  }

  /// Logo-Feld (siehe [LogoChip]); [mode] = Sponsor-Einstellung oder 'auto'.
  Widget _logoChip(
    Uint8List bytes, {
    required double height,
    bool circle = false,
    String mode = 'auto',
  }) => LogoChip(bytes: bytes, height: height, circle: circle, mode: mode);
}

/// Parallelogramm (schräge Seiten) für Balken und Plaketten.
class _SlantClipper extends CustomClipper<Path> {
  const _SlantClipper();

  @override
  Path getClip(Size size) {
    final d = size.height * 0.45;
    return Path()
      ..moveTo(d, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width - d, size.height)
      ..lineTo(0, size.height)
      ..close();
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

/// Lässt Treffer (Zeiger-Ereignisse) nur dort zu, wo [test] true liefert –
/// z. B. die Zieh-Ebene nur über Objekten, damit darunterliegende Gesten
/// (Foto-Zoom im Foto-Bereich, Hintergrund-Tippen) frei bleiben.
class _HitWhere extends SingleChildRenderObjectWidget {
  const _HitWhere({required this.test, super.child});

  final bool Function(Offset localPosition) test;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _HitWhereRender(test);

  @override
  void updateRenderObject(BuildContext context, _HitWhereRender renderObject) {
    renderObject.test = test;
  }
}

class _HitWhereRender extends RenderProxyBox {
  _HitWhereRender(this.test);

  bool Function(Offset localPosition) test;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!test(position)) return false;
    return super.hitTest(result, position: position);
  }
}

/// KI-Look: Deko-Ebene (PNG mit Alpha) über der ganzen Grafik.
/// [mode] 'glow' = leuchtend (aus Schwarz), 'cutout' = freigestellt (aus
/// Magenta). [theme] = Motiv-Text (für „Neu erzeugen"). [opacity] = Stärke.
class _AiLook {
  _AiLook({
    required this.dataUrl,
    required this.mode,
    required this.theme,
    this.opacity = 1.0,
  });

  final String dataUrl;
  final String mode;
  final String theme;
  double opacity;

  /// Einmal dekodiert (gleiche Bytes-Instanz → Bild-Cache greift beim Ziehen).
  late final Uint8List? bytes = TeamLogo.decode(dataUrl);

  Map<String, Object> toJson() => {
    'url': dataUrl,
    'mode': mode,
    'theme': theme,
    'op': opacity,
  };

  static _AiLook? fromJson(Object? v) {
    if (v is! Map) return null;
    final url = v['url'];
    if (url is! String || url.isEmpty) return null;
    final op = v['op'];
    return _AiLook(
      dataUrl: url,
      mode: v['mode'] == 'cutout' ? 'cutout' : 'glow',
      theme: v['theme']?.toString() ?? '',
      opacity: op is num ? op.toDouble().clamp(0.1, 1.0) : 1.0,
    );
  }
}

/// Nur für Tests: rendert die Grafik ohne Screen/State (z. B. die ENDSTAND-
/// Variante), damit Layout-Fehler im Test sichtbar werden.
@visibleForTesting
Widget debugGraphicForTest({
  required ResultData result,
  bool compact = false,
  String resultLayout = 'photo',
  Map<String, Size> boxSize = const {},
  bool isHome = false,
  String? logo,
  String? opponentLogo,
  Sponsor? mainSponsor,
  List<Sponsor> barSponsors = const [],
  String? ftPhoto,
  bool logoCircle = false,
  Map<String, ({String text, String font, String color})> posterTexts =
      const {},
  String? gradShape,
  double bgPattern = 0,
}) => _StartelfGraphic(
  posterTexts: posterTexts,
  gradShape: gradShape,
  bgPattern: bgPattern,
  title: 'Garather SV',
  logo: logo,
  starters: const [],
  benchNames: const [],
  mainSponsor: mainSponsor,
  barSponsors: barSponsors,
  ftPhoto: ftPhoto,
  logoCircle: logoCircle,
  bgImage: null,
  gradTop: const Color(0xFF0B3D2A),
  gradBottom: const Color(0xFF145A3C),
  overlayOpacity: 0.5,
  matchDate: DateTime(2026, 10, 25, 15),
  isHome: isHome,
  opponentName: 'Post SV Düsseldorf',
  opponentLogo: opponentLogo,
  compact: compact,
  result: result,
  resultLayout: resultLayout,
  posterHeadline: resultLayout == 'photo' ? 'ENDSTAND' : 'ERGEBNIS',
  boxSize: boxSize,
  canvasKey: GlobalKey(),
  stdCtx: <String, BuildContext>{},
  stdNatCtx: <String, BuildContext>{},
);
