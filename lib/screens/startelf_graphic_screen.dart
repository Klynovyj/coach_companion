import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:open_filex/open_filex.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../models/graphic_preset.dart';
import '../models/graphic_settings.dart';
import '../models/sponsor.dart';
import '../services/cloud_service.dart';
import '../services/share_service.dart';
import '../state/app_state.dart';
import '../widgets/player_picker_page.dart';
import '../widgets/team_logo.dart';
import 'photo_editor_screen.dart';

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
enum _AnnStyle { zentriert, poster }

/// Höhenanteil des großen Spielerbilds im Poster (unterer, randabfallender Teil).
/// Steuert zugleich das Zuschnitt-Seitenverhältnis (WYSIWYG).
const double _kPosterMainHeightFactor = 0.68;

/// Standard-Positionen (normiert 0..1) der frei verschiebbaren Poster-Elemente.
const Map<String, Offset> _kPosterItemDefaults = {
  'player': Offset(0.5, 0.72),
  'sponsor': Offset(0.5, 0.08),
  'logos': Offset(0.5, 0.18),
  'headline': Offset(0.5, 0.30),
  'info': Offset(0.5, 0.38),
  'sponsorbar': Offset(0.5, 0.93),
};

/// Default-Positionen für das „Zentriert"-Preset (mittig gestapelt, kein großes
/// Spielerbild im Fokus).
const Map<String, Offset> _kCenteredItemDefaults = {
  'player': Offset(0.5, 0.80),
  'sponsor': Offset(0.5, 0.18),
  'headline': Offset(0.5, 0.40),
  'logos': Offset(0.5, 0.56),
  'info': Offset(0.5, 0.72),
  'sponsorbar': Offset(0.5, 0.90),
};

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
    if (dr * dr + dg * dg + db * db > tol2) continue; // Kante → nicht überqueren
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
  });

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

  bool get isResult => result != null;
  bool get isAnnouncement => announcement != null;

  @override
  State<StartelfGraphicScreen> createState() => _StartelfGraphicScreenState();
}

class _StartelfGraphicScreenState extends State<StartelfGraphicScreen> {
  final GlobalKey _boundaryKey = GlobalKey();
  final GlobalKey _bgBoundaryKey = GlobalKey(); // nur die Hintergrund-Ebene
  bool _story = true; // true = Story 9:16, false = Post 1:1
  // Spielankündigung: Stil (zentriert/Poster), Überschrift-Modus & -Text.
  // Alles transient je Grafik (kein Speichern/Sync).
  _AnnStyle _annStyle = _AnnStyle.zentriert;
  String _annHeadMode = 'spieltag'; // 'spieltag' | 'auto' | 'custom'
  String _annHeadText = 'SPIELTAG';
  bool _posterLogoDisc = true; // heller Kreis hinter den Logos (Sichtbarkeit)
  bool _posterShadow = false; // Schlagschatten beim freigestellten Spieler
  double _posterShadowStrength = 45; // 0..100
  double _posterShadowAngle = 45; // Richtung in Grad (0=rechts, 90=unten)
  // Jede Kombination Format×Stil (Story/Post × Zentriert/Poster) ist ein EIGENES
  // Layout: Spielerbild, Overlays, Texte und Position/Größe/Reihenfolge getrennt
  // (Key `_designKey`, 4 Kombinationen). Lazy angelegt via putIfAbsent.
  String get _designKey =>
      '${_story ? 's' : 'p'}_${_annStyle == _AnnStyle.poster ? 'po' : 'ze'}';
  final Map<String, Map<String, Offset>> _posterPosF = {};
  final Map<String, Map<String, double>> _posterScaleF = {};
  final Map<String, List<String>> _posterOrderF = {};
  final Map<String, String?> _posterMainF = {};
  final Map<String, List<({String id, String dataUrl})>> _posterOverlaysF = {};
  final Map<String, List<String>> _textIdsF = {};
  final Map<String, Map<String, String>> _textContentF = {};
  final Map<String, Map<String, String>> _textFontF = {};
  final Map<String, Map<String, String>> _textColorF = {};
  int _posterOverlaySeq = 0; // eindeutige Overlay-IDs (global)
  int _textSeq = 0; // eindeutige Text-IDs (global)
  String? _posterSel; // aktuell ausgewähltes Element (für Größe-Regler)
  Map<String, Offset> get _posterPos =>
      _posterPosF.putIfAbsent(_designKey, () => {});
  Map<String, double> get _posterScale =>
      _posterScaleF.putIfAbsent(_designKey, () => {});
  List<String> get _posterOrder => _posterOrderF.putIfAbsent(
    _designKey,
    () => List<String>.from(_kPosterBaseOrder),
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
  bool _showMainSponsor = true; // Hauptsponsor anzeigen (je Grafik)
  String _mainSponsorMode = 'logo'; // 'logo' | 'text' – Hauptsponsor-Darstellung
  bool _showOtherSponsors = true; // weitere Sponsoren anzeigen (je Grafik)
  String _posterFont = 'standard'; // Schriftart der Poster-Texte
  List<Sponsor> _sponsors = [];
  GraphicSettings _settings = const GraphicSettings(id: 'local');
  bool _loading = true;
  bool _sharing = false;
  bool _aiBusy = false;
  bool _bgBusy = false; // clientseitiges Hintergrund-Entfernen läuft
  // Hinzugefügte Fotos (für alle Grafiktypen), transient. Hintergrund ODER
  // Foto-Bereich oben; mehrere möglich.
  final List<_GraphicPhoto> _photos = [];
  // Einzelnes Band-Foto: verschieben & zoomen (Pinch/Drag).
  final TransformationController _photoCtrl = TransformationController();

  /// Wirksames Hintergrund-Foto (erstes mit Platzierung „Hintergrund").
  String? get _photoBg {
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

  /// Aktuelle Poster-Überschrift aus Modus + Text.
  String get _posterHeadline {
    switch (_annHeadMode) {
      case 'auto':
        return widget.isHome ? 'HEIMSPIEL' : 'AUSWÄRTSSPIEL';
      case 'custom':
        final t = _annHeadText.trim();
        return t.isEmpty ? 'SPIELTAG' : t.toUpperCase();
      default:
        return 'SPIELTAG';
    }
  }

  // Ist der wirksame Hintergrund dunkel? → steuert die Auto-Logo-Variante.
  bool _bgDark = false;
  String? _bgDarkFor; // Für welchen Hintergrund zuletzt berechnet.

  /// Hintergrundhelligkeit bestimmen (einmal je Hintergrund). Dunkel → helles/
  /// SW-Logo, hell → farbiges Logo.
  Future<void> _refreshBgDark() async {
    final src = _photoBg ?? _settings.bgImage;
    if (src == _bgDarkFor) return;
    _bgDarkFor = src;
    bool dark = true; // Default-Verlauf (dunkelgrün) → eher dunkel.
    final bytes = TeamLogo.decode(src);
    if (bytes != null) {
      try {
        final im = img.decodeImage(bytes);
        if (im != null) {
          final small = img.copyResize(im, width: 16);
          var tot = 0.0;
          var n = 0;
          for (final p in small) {
            tot += 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
            n++;
          }
          dark = n > 0 && (tot / n) < 115;
        }
      } catch (_) {}
    }
    if (mounted && dark != _bgDark) setState(() => _bgDark = dark);
  }

  /// Effektives Vereinslogo: auf dunklem Hintergrund das dunkel-Logo (sonst
  /// Standard). Fällt auf das Team-Logo zurück.
  String? get _effectiveLogo => _bgDark
      ? (_settings.logoDark ?? _settings.logo ?? widget.teamLogo)
      : (_settings.logo ?? widget.teamLogo);

  // Logische Zeichengrößen (× pixelRatio 3 = 1080×1920 bzw. 1080×1080).
  static const double _storyW = 360, _storyH = 640;
  static const double _postW = 360, _postH = 360;

  /// Standard-Ebenenreihenfolge (hinten → vorne).
  static const List<String> _kPosterBaseOrder = [
    'player',
    'sponsor',
    'logos',
    'headline',
    'info',
    'sponsorbar',
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _photoCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    final sponsors = await state.sponsors();
    final settings = await state.graphicSettings();
    if (!mounted) return;
    setState(() {
      _sponsors = sponsors;
      _settings = settings;
      _loading = false;
    });
    _refreshBgDark();
    // Lokale Einstellung (evtl. vor Existenz der Cloud-Tabelle angelegt) in die
    // Cloud nachschieben, damit sie auf anderen Geräten erscheint.
    state.pushGraphicSettingsToCloud();
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
    final w = _story ? _storyW : _postW;
    final h = _story ? _storyH : _postH;
    switch (place) {
      case _PhotoPlace.band:
        return w / (h * 0.46);
      case _PhotoPlace.posterMain:
        return w / (h * _kPosterMainHeightFactor); // Hochformat, unterer Bereich
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
    final src = await _askPosterSource(hasExisting: _posterMain != null);
    if (src == null || !mounted) return;
    if (src == 'remove') {
      setState(() => _posterMainF[_designKey] = null);
      return;
    }
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
            maxSize: 2000, // höhere Auflösung fürs große Spielerbild
          );
    if (url == null || !mounted) return;
    setState(() => _posterMainF[_designKey] = url);
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
    final id = await Navigator.push<String?>(
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
          maxSize: 2000,
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
        builder: (_) =>
            PhotoEditorScreen(imageBytes: bytes, aspectRatio: _photoAspect(p.place)),
      ),
    );
    if (edited == null || !mounted) return;
    setState(() {
      p.dataUrl = 'data:image/jpeg;base64,${base64Encode(edited)}';
      _photoCtrl.value = Matrix4.identity();
    });
  }

  Future<void> _openCustomize() async {
    final titleCtrl = TextEditingController(text: _settings.title ?? '');
    final state = context.read<AppState>();
    var presets = await state.graphicPresets();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
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

          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom,
            ),
            child: DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.8,
              maxChildSize: 0.95,
              minChildSize: 0.5,
              builder: (ctx, scroll) => ListView(
                controller: scroll,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  const Text(
                    'Grafik anpassen',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  const SizedBox(height: 14),
                  // Titel ------------------------------------------------
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
                    label: 'Logo (hell)',
                    preview: _settings.logo,
                    onPick: () async {
                      final url = await _pickImage(asBackground: false);
                      if (url != null) apply(_settings.copyWith(logo: url));
                    },
                    onClear: _settings.logo == null
                        ? null
                        : () => apply(_settings.copyWith(clearLogo: true)),
                    clearLabel: 'Team-Logo',
                  ),
                  const SizedBox(height: 10),
                  // Logo für dunkle Hintergründe -------------------------
                  _rowWithImage(
                    label: 'Logo (dunkel)',
                    preview: _settings.logoDark,
                    onPick: () async {
                      final url = await _pickImage(asBackground: false);
                      if (url != null) apply(_settings.copyWith(logoDark: url));
                    },
                    onClear: _settings.logoDark == null
                        ? null
                        : () => apply(_settings.copyWith(clearLogoDark: true)),
                    clearLabel: 'Entfernen',
                  ),
                  const SizedBox(height: 10),
                  // Form des Logo-Hintergrunds (eckig/rund) -------------
                  Row(
                    children: [
                      const Text('Logo-Hintergrund'),
                      const SizedBox(width: 12),
                      ChoiceChip(
                        label: const Text('Eckig'),
                        selected: _settings.logoShape != 'circle',
                        onSelected: (_) =>
                            apply(_settings.copyWith(logoShape: 'rounded')),
                      ),
                      const SizedBox(width: 8),
                      ChoiceChip(
                        label: const Text('Rund'),
                        selected: _settings.logoShape == 'circle',
                        onSelected: (_) =>
                            apply(_settings.copyWith(logoShape: 'circle')),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // Hintergrundbild -------------------------------------
                  _rowWithImage(
                    label: 'Hintergrundbild',
                    preview: _settings.bgImage,
                    onPick: () async {
                      final url = await _pickImage(
                        asBackground: true,
                        edit: true,
                        aspectRatio: _photoAspect(_PhotoPlace.background),
                      );
                      if (url != null) apply(_settings.copyWith(bgImage: url));
                    },
                    onClear: _settings.bgImage == null
                        ? null
                        : () => apply(_settings.copyWith(clearBgImage: true)),
                    clearLabel: 'Entfernen',
                  ),
                  const SizedBox(height: 8),
                  // Design-Modus ----------------------------------------
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Design-Modus (eigenes Branding)'),
                    subtitle: const Text(
                      'Dein Hintergrundbild füllt alles; eigenes Logo/Titel aus, '
                      'nur Teams/Datum/Score – frei verschiebbar.',
                    ),
                    value: _settings.designMode,
                    onChanged: (v) => apply(
                      _settings.copyWith(
                        designMode: v,
                        // Beim Aktivieren Hintergrund voll zeigen.
                        overlayOpacity: v ? 20 : _settings.overlayOpacity,
                      ),
                    ),
                  ),
                  // Gegner-Logo ------------------------------------------
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Gegner-Logo anzeigen'),
                    subtitle: const Text('Logo des Gegners neben „vs …"'),
                    value: _settings.showOpponentLogo,
                    onChanged: widget.opponentLogo == null
                        ? null
                        : (v) => apply(_settings.copyWith(showOpponentLogo: v)),
                  ),
                  // Torschützen-Block (nur Ergebnis-Grafik) --------------
                  if (widget.isResult)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Torschützen anzeigen'),
                      subtitle: const Text('Liste der Tore (Spieler & Minute)'),
                      value: _settings.showScorers,
                      onChanged: (v) =>
                          apply(_settings.copyWith(showScorers: v)),
                    ),
                  // Spielerfotos (nur Ergebnis-Grafik) -------------------
                  if (widget.isResult)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Spielerfotos anzeigen'),
                      subtitle: const Text('Fotos bei den Torschützen'),
                      value: _settings.showPhotos,
                      onChanged: (v) =>
                          apply(_settings.copyWith(showPhotos: v)),
                    ),
                  const SizedBox(height: 8),
                  // Abdunkeln / Transparenz -----------------------------
                  Text(
                    _settings.bgImage == null
                        ? 'Abdunkeln (nur mit Hintergrundbild wirksam)'
                        : 'Abdunkeln / Transparenz: ${_settings.overlayOpacity}%',
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
                  const SizedBox(height: 8),
                  // Hintergrundbild: Deckkraft (Transparenz) + Mischmodus ---
                  Text('Bild-Deckkraft: ${_settings.bgOpacity}%'),
                  Slider(
                    value: _settings.bgOpacity.toDouble(),
                    min: 0,
                    max: 100,
                    divisions: 20,
                    label: '${_settings.bgOpacity}%',
                    onChanged: (v) =>
                        apply(_settings.copyWith(bgOpacity: v.round())),
                  ),
                  const SizedBox(height: 4),
                  const Text('Mischmodus (Bild ↔ Hintergrund)'),
                  const SizedBox(height: 6),
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
                  const SizedBox(height: 8),
                  // Verlaufsfarben --------------------------------------
                  const Text('Verlaufsfarbe oben'),
                  const SizedBox(height: 6),
                  _swatches(
                    selected: _settings.gradTop,
                    onPick: (hex) => apply(_settings.copyWith(gradTop: hex)),
                  ),
                  const SizedBox(height: 12),
                  const Text('Verlaufsfarbe unten'),
                  const SizedBox(height: 6),
                  _swatches(
                    selected: _settings.gradBottom,
                    onPick: (hex) => apply(_settings.copyWith(gradBottom: hex)),
                  ),
                  const SizedBox(height: 16),
                  // Presets ---------------------------------------------
                  const Text('Vorlagen'),
                  const SizedBox(height: 6),
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
                  const SizedBox(height: 10),
                  // Eigene Hintergrund-Vorlagen (kompletter Look) -----------
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: savePreset,
                      icon: const Icon(Icons.bookmark_add_outlined),
                      label: const Text('Aktuellen Look als Vorlage speichern'),
                    ),
                  ),
                  if (presets.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    const Text('Gespeicherte Vorlagen'),
                    const SizedBox(height: 6),
                    for (final p in presets)
                      Card(
                        margin: const EdgeInsets.only(bottom: 6),
                        child: ListTile(
                          dense: true,
                          contentPadding: const EdgeInsets.only(
                            left: 10,
                            right: 2,
                          ),
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
                                icon: const Icon(
                                  Icons.delete_outline,
                                  size: 20,
                                ),
                                onPressed: () => deletePreset(p),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                  const SizedBox(height: 16),
                  // Akzentfarbe (Linien, VS, Spielstand, Datum/Uhrzeit) -----
                  const Text('Akzentfarbe'),
                  const SizedBox(height: 6),
                  _swatches(
                    selected: _settings.accent ?? '#FFFFFF',
                    palette: _accentPalette,
                    onPick: (hex) => apply(
                      hex == '#FFFFFF'
                          ? _settings.copyWith(clearAccent: true)
                          : _settings.copyWith(accent: hex),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Fertig'),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    // Speichern + in die Cloud spiegeln. (state = oben gelesener AppState)
    if (!mounted) return;
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
          child: Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        if (onClear != null)
          TextButton(onPressed: onClear, child: Text(clearLabel)),
        OutlinedButton(onPressed: onPick, child: const Text('Wählen')),
      ],
    );
  }

  Widget _swatches({
    required String selected,
    required void Function(String) onPick,
    List<String>? palette,
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
      ],
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
  Future<Uint8List?> _captureGraphicPng() => _capturePng(_boundaryKey);

  /// Nur die Hintergrund-Ebene (ohne Logos/Text/Sponsoren) als PNG.
  Future<Uint8List?> _captureBackgroundPng() => _capturePng(_bgBoundaryKey);

  Future<Uint8List?> _capturePng(GlobalKey key) async {
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
    final logicalWidth = _story ? _storyW : _postW;
    // Höhere Export-Auflösung (1440 px Breite → 1440×2560 bzw. 1440×1440).
    final image = await boundary.toImage(pixelRatio: 1440 / logicalWidth);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  }

  String get _kind => widget.isAnnouncement
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
    setState(() => _aiBusy = true);
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
        aspect: _story ? '9:16' : '1:1',
      );
      if (out == null) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Die KI hat kein Bild zurückgegeben.')),
        );
        return;
      }
      if (!mounted) return;
      if (wish.mode == 'background') {
        setState(() {
          _photos.removeWhere((p) => p.place == _PhotoPlace.background);
          _photos.add(
            _GraphicPhoto(
              'data:image/png;base64,${base64Encode(out)}',
              _PhotoPlace.background,
            ),
          );
        });
        _refreshBgDark();
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'KI-Hintergrund gesetzt – teile die Grafik wie gewohnt. '
              '(Entfernen über das Foto-Menü.)',
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
          content: Text(_aiErrorMessage(e)),
          duration: const Duration(seconds: 6),
        ),
      );
    } finally {
      if (mounted) setState(() => _aiBusy = false);
    }
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
    }
  }

  /// KI-Freisteller für das GEWÄHLTE Bild (Spieler oder Overlay): entfernt den
  /// Foto-Hintergrund, damit der Hintergrund dahinter erscheint.
  Future<void> _cutoutSelected() async {
    if (_aiBusy) return;
    final src = _selectedImageDataUrl();
    if (src == null || !src.contains('base64,')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Erst ein Bild auswählen (antippen).')),
      );
      return;
    }
    setState(() => _aiBusy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final out = await CloudService.aiImage(
        images: [
          {'mime': _dataUrlMime(src), 'data': src, 'role': 'photo'},
        ],
        prompt:
            'Stelle die Person/das Motiv sauber frei und gib es auf '
            'transparentem Hintergrund (PNG mit Alpha) zurück.',
        mode: 'cutout',
        aspect: _story ? '9:16' : '1:1',
      );
      if (out == null) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Die KI hat kein Bild zurückgegeben.')),
        );
        return;
      }
      if (!mounted) return;
      setState(
        () => _setSelectedImageDataUrl(
          'data:image/png;base64,${base64Encode(out)}',
        ),
      );
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Freigestellt. Falls noch Reste bleiben: eigenes transparentes PNG '
            'nutzen.',
          ),
          duration: Duration(seconds: 5),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(_aiErrorMessage(e)),
          duration: const Duration(seconds: 6),
        ),
      );
    } finally {
      if (mounted) setState(() => _aiBusy = false);
    }
  }

  /// Einfarbigen Hintergrund des GEWÄHLTEN Bildes clientseitig entfernen (ohne
  /// KI). Nutzt [removeUniformBackground] in einem Isolate.
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
  String _aiErrorMessage(Object e) {
    final s = e.toString();
    final low = s.toLowerCase();
    if (low.contains('resource_exhausted') ||
        low.contains('prepayment credits') ||
        low.contains('quota') ||
        low.contains('"code": 402') ||
        low.contains('code: 402')) {
      return 'Gemini-Guthaben aufgebraucht – im Google AI Studio Guthaben aufladen.';
    }
    if (low.contains('api_key_invalid') ||
        low.contains('api key not valid') ||
        low.contains('unauthorized') ||
        low.contains('permission_denied')) {
      return 'Gemini-Zugang abgelehnt – API-Key im Supabase-Secret prüfen.';
    }
    if (low.contains('gemini_api_key fehlt') ||
        low.contains('secret setzen')) {
      return 'Gemini ist noch nicht eingerichtet (Secret fehlt).';
    }
    if (low.contains('nicht freigeschaltet')) {
      return 'KI ist für dich nicht freigeschaltet (Einstellungen → '
          'KI-Berechtigungen).';
    }
    if (low.contains('kein bild von der ki')) {
      return 'Die KI hat kein Bild zurückgegeben – anderen Wunsch probieren.';
    }
    if (low.contains('socketexception') ||
        low.contains('failed host lookup') ||
        low.contains('timeout') ||
        low.contains('clientexception')) {
      return 'Keine Verbindung zur KI – Internet prüfen und erneut versuchen.';
    }
    // Unbekannter Fehler: kurzen Rohhinweis mitgeben, damit die echte Ursache
    // sichtbar ist (Function-/Gemini-Meldung), statt nur „später versuchen".
    final detail = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    final snippet = detail.length > 160 ? '${detail.substring(0, 160)}…' : detail;
    return 'KI-Fehler: $snippet';
  }

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
            onPressed: () => Navigator.pop(
              ctx,
              (prompt: ctrl.text.trim(), mode: 'background'),
            ),
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
    overlayOpacity: _settings.overlayOpacity / 100,
    matchDate: widget.matchDate,
    isHome: widget.isHome,
    opponentName: widget.opponentName,
    opponentLogo: (_settings.showOpponentLogo || _settings.designMode)
        ? widget.opponentLogo
        : null,
    compact: !_story,
    result: widget.result,
    announcement: widget.announcement,
    photoBg: _photoBg,
    bandPhotos: _bandPhotos,
    showPhotos: _settings.showPhotos,
    photoController: _photoCtrl,
    designMode: _settings.designMode,
    accent: _settings.accent == null ? null : _hex(_settings.accent!),
    bgOpacity: _settings.bgOpacity / 100,
    bgBlend: _blendModeOf(_settings.bgBlend),
    logoCircle: _settings.logoShape == 'circle',
    backgroundOnly: backgroundOnly,
    showScorers: _settings.showScorers,
    infoPos: Offset(_settings.infoX, _settings.infoY),
    onInfoMove: (p) => setState(
      () => _settings = _settings.copyWith(infoX: p.dx, infoY: p.dy),
    ),
    onInfoMoveEnd: () =>
        context.read<AppState>().saveGraphicSettings(_settings),
    posterStyle: _annStyle == _AnnStyle.poster,
    posterHeadline: _posterHeadline,
    posterMain: _posterMain,
    posterBadge: _posterBadge,
    posterLogoDisc: _posterLogoDisc,
    posterShadow: _posterShadow,
    posterShadowStrength: _posterShadowStrength,
    posterShadowAngle: _posterShadowAngle,
    posterOrder: _posterOrder,
    posterOverlays: {for (final o in _posterOverlays) o.id: o.dataUrl},
    posterItemPos: _posterPos,
    posterItemScale: _posterScale,
    posterSelected: _posterSel,
    onPosterItemMove: (id, p) => setState(() => _posterPos[id] = p),
    onPosterSelect: (id) => setState(() => _posterSel = id),
    posterFont: _posterFont,
    showMainSponsor: _showMainSponsor,
    showOtherSponsors: _showOtherSponsors,
    mainSponsorMode: _mainSponsorMode,
    posterTexts: {
      for (final id in _textIds)
        id: (
          text: _textContent[id] ?? '',
          font: _textFont[id] ?? 'standard',
          color: _textColor[id] ?? 'white',
        ),
    },
  );

  /// Anzeigename eines Poster-Elements (für den Größe-Regler).
  String _posterItemLabel(String id) {
    switch (id) {
      case 'player':
        return 'Spieler';
      case 'sponsor':
        return 'Sponsor';
      case 'sponsorbar':
        return 'Sponsoren';
      case 'logos':
        return 'Logos';
      case 'headline':
        return 'Titel';
      case 'info':
        return 'Datum';
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
    final src = await _askPosterSource(allowKader: false);
    if (src == null || src == 'remove' || !mounted) return;
    final url = await _pickImage(
      asBackground: true,
      source: src == 'camera' ? ImageSource.camera : ImageSource.gallery,
      edit: true,
      keepAlpha: true,
      maxSize: 2000,
    );
    if (url == null || !mounted) return;
    final id = 'overlay_${_posterOverlaySeq++}';
    setState(() {
      _posterOverlays.add((id: id, dataUrl: url)); // nur aktuelles Format
      _posterOrder.add(id);
      _posterPos[id] = const Offset(0.5, 0.5);
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
      _posterSel = id;
    });
  }

  /// Ein Overlay ODER Textfeld wieder entfernen (aktuelles Format).
  void _removePosterItem(String id) {
    setState(() {
      _posterOverlays.removeWhere((o) => o.id == id);
      _textIds.remove(id);
      _textContent.remove(id);
      _textFont.remove(id);
      _textColor.remove(id);
      _posterOrder.remove(id);
      _posterPos.remove(id);
      _posterScale.remove(id);
      if (_posterSel == id) _posterSel = null;
    });
  }

  /// Steuerleiste für die Spielankündigung: Stil-Umschalter und – im Poster-Stil –
  /// Bilder-Buttons plus Überschrift-Auswahl.
  Widget _announcementControls() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Column(
        children: [
          SegmentedButton<_AnnStyle>(
            segments: const [
              ButtonSegment(
                value: _AnnStyle.zentriert,
                label: Text('Zentriert'),
              ),
              ButtonSegment(
                value: _AnnStyle.poster,
                label: Text('Spieler-Poster'),
              ),
            ],
            selected: {_annStyle},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() {
              // Jeder Stil ist ein eigenes Layout (eigene Bilder/Positionen) –
              // einfach umschalten, nichts zurücksetzen.
              _annStyle = s.first;
              _posterSel = null;
            }),
          ),
          ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.person, size: 18),
                label: Text(
                  _posterMain == null ? 'Spielerbild' : 'Spielerbild ✓',
                ),
                onPressed: _addPosterMain,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.add_photo_alternate, size: 18),
                    label: const Text('Bild/Grafik'),
                    onPressed: _addPosterOverlay,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.text_fields, size: 18),
                    label: const Text('Text'),
                    onPressed: _addPosterText,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: _aiBusy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.auto_fix_high, size: 18),
                    label: Text(_aiBusy ? 'KI …' : 'Freistellen (KI)'),
                    onPressed: (_selectedImageDataUrl() == null || _aiBusy)
                        ? null
                        : _cutoutSelected,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: _bgBusy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.format_color_reset, size: 18),
                    label: Text(_bgBusy ? 'Entferne …' : 'Hintergrund weg'),
                    onPressed: (_selectedImageDataUrl() == null || _bgBusy)
                        ? null
                        : _removeBgSelected,
                  ),
                ),
              ],
            ),
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Text(
                'Freistellen/Hintergrund wirkt auf das GEWÄHLTE Bild (Spieler '
                'oder Overlay – antippen). „Hintergrund weg" geht ohne KI '
                '(Studio-/weißer Grund); fertig freigestelltes PNG geht auch.',
                style: TextStyle(fontSize: 10.5, color: Colors.grey),
              ),
            ),
            const SizedBox(height: 4),
            Theme(
              data: Theme.of(
                context,
              ).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                title: const Text(
                  'Überschrift, Schrift, Sponsoren & Schatten',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 6),
                children: [
                  Wrap(
                    spacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      const Text(
                        'Überschrift:',
                        style: TextStyle(fontSize: 12),
                      ),
                      ChoiceChip(
                        label: const Text('SPIELTAG'),
                        selected: _annHeadMode == 'spieltag',
                        onSelected: (_) =>
                            setState(() => _annHeadMode = 'spieltag'),
                      ),
                ChoiceChip(
                  label: const Text('Heim/Auswärts'),
                  selected: _annHeadMode == 'auto',
                  onSelected: (_) => setState(() => _annHeadMode = 'auto'),
                ),
                ChoiceChip(
                  label: const Text('Eigener'),
                  selected: _annHeadMode == 'custom',
                  onSelected: (_) => setState(() => _annHeadMode = 'custom'),
                ),
              ],
            ),
            if (_annHeadMode == 'custom')
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: TextFormField(
                  initialValue: _annHeadText,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    hintText: 'z. B. DERBY, TOPSPIEL',
                  ),
                  onChanged: (v) => setState(() => _annHeadText = v),
                ),
              ),
            const SizedBox(height: 2),
            Row(
              children: [
                const Text('Schrift:', style: TextStyle(fontSize: 12)),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    isDense: true,
                    value: _posterFont,
                    items: [
                      for (final e in _kPosterFonts.entries)
                        DropdownMenuItem(value: e.key, child: Text(e.value)),
                    ],
                    onChanged: (v) =>
                        setState(() => _posterFont = v ?? 'standard'),
                  ),
                ),
              ],
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'Hauptsponsor anzeigen',
                style: TextStyle(fontSize: 13),
              ),
              value: _showMainSponsor,
              onChanged: (v) => setState(() => _showMainSponsor = v),
            ),
            if (_showMainSponsor)
              Row(
                children: [
                  const Text('Hauptsponsor:', style: TextStyle(fontSize: 12)),
                  const SizedBox(width: 8),
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
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'Weitere Sponsoren anzeigen',
                style: TextStyle(fontSize: 13),
              ),
              value: _showOtherSponsors,
              onChanged: (v) => setState(() => _showOtherSponsors = v),
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'Logos auf hellem Kreis',
                style: TextStyle(fontSize: 13),
              ),
              value: _posterLogoDisc,
              onChanged: (v) => setState(() => _posterLogoDisc = v),
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'Schatten (alle Bilder)',
                style: TextStyle(fontSize: 13),
              ),
              subtitle: const Text(
                'Gilt für Spieler und alle Overlays; am besten freigestellt',
                style: TextStyle(fontSize: 10.5),
              ),
              value: _posterShadow,
              onChanged: (v) => setState(() => _posterShadow = v),
            ),
            if (_posterShadow) ...[
              Row(
                children: [
                  const SizedBox(
                    width: 52,
                    child: Text('Stärke', style: TextStyle(fontSize: 12)),
                  ),
                  Expanded(
                    child: Slider(
                      value: _posterShadowStrength,
                      min: 0,
                      max: 100,
                      onChanged: (v) =>
                          setState(() => _posterShadowStrength = v),
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  const SizedBox(
                    width: 52,
                    child: Text('Winkel', style: TextStyle(fontSize: 12)),
                  ),
                  Expanded(
                    child: Slider(
                      value: _posterShadowAngle,
                      min: 0,
                      max: 360,
                      divisions: 72,
                      label: '${_posterShadowAngle.round()}°',
                      onChanged: (v) =>
                          setState(() => _posterShadowAngle = v),
                    ),
                  ),
                ],
              ),
            ],
                ],
              ),
            ),
            if (_posterSel != null)
              Row(
                children: [
                  SizedBox(
                    width: 52,
                    child: Text(
                      _posterItemLabel(_posterSel!),
                      style: const TextStyle(fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Expanded(
                    child: Slider(
                      value: _posterScale[_posterSel!] ?? 1.0,
                      min: 0.4,
                      max: 3.0,
                      onChanged: (v) =>
                          setState(() => _posterScale[_posterSel!] = v),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Eine Ebene nach hinten',
                    icon: const Icon(Icons.flip_to_back, size: 18),
                    onPressed: () => _reorderPoster(_posterSel!, -1),
                  ),
                  IconButton(
                    tooltip: 'Eine Ebene nach vorne',
                    icon: const Icon(Icons.flip_to_front, size: 18),
                    onPressed: () => _reorderPoster(_posterSel!, 1),
                  ),
                  if (_posterSel!.startsWith('overlay_') ||
                      _posterSel!.startsWith('text_'))
                    IconButton(
                      tooltip: 'Entfernen',
                      icon: const Icon(
                        Icons.delete_outline,
                        size: 18,
                        color: Colors.red,
                      ),
                      onPressed: () => _removePosterItem(_posterSel!),
                    ),
                  IconButton(
                    tooltip: 'Auswahl aufheben',
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => setState(() => _posterSel = null),
                  ),
                ],
              ),
            // Editor für ein eigenes Textfeld (Inhalt/Schriftart/Farbe).
            if (_posterSel != null && _posterSel!.startsWith('text_')) ...[
              TextFormField(
                key: ValueKey('txt_${_posterSel!}'),
                initialValue: _textContent[_posterSel!] ?? '',
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  hintText: 'Text eingeben',
                ),
                onChanged: (v) =>
                    setState(() => _textContent[_posterSel!] = v),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  const Text('Schrift:', style: TextStyle(fontSize: 12)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      isDense: true,
                      value: _textFont[_posterSel!] ?? 'standard',
                      items: [
                        for (final e in _kPosterFonts.entries)
                          DropdownMenuItem(value: e.key, child: Text(e.value)),
                      ],
                      onChanged: (v) => setState(
                        () => _textFont[_posterSel!] = v ?? 'standard',
                      ),
                    ),
                  ),
                ],
              ),
              Wrap(
                spacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('Farbe:', style: TextStyle(fontSize: 12)),
                  for (final e in _kTextColors.entries)
                    ChoiceChip(
                      label: Text(e.value),
                      selected: (_textColor[_posterSel!] ?? 'white') == e.key,
                      onSelected: (_) =>
                          setState(() => _textColor[_posterSel!] = e.key),
                    ),
                ],
              ),
            ],
            const Text(
              'Tipp: Element antippen = auswählen, ziehen = verschieben, '
              'Größe-Regler = skalieren, Vorne/Hinten = Ebene tauschen. '
              '„Bild/Grafik" und „Text" legen eigene Elemente dazu. Story 9:16 '
              'und Post 1:1 werden getrennt eingestellt.',
              style: TextStyle(fontSize: 10.5, color: Colors.grey),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final w = _story ? _storyW : _postW;
    final h = _story ? _storyH : _postH;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.isAnnouncement
              ? 'Spielankündigung'
              : widget.isResult
              ? 'Ergebnis-Grafik'
              : 'Startelf-Grafik',
        ),
        actions: [
          IconButton(
            tooltip: 'Fotos / Bilder',
            icon: Icon(
              _photos.isNotEmpty
                  ? Icons.add_a_photo
                  : Icons.add_a_photo_outlined,
            ),
            onPressed: _managePhotos,
          ),
          IconButton(
            tooltip: 'Grafik anpassen',
            icon: const Icon(Icons.tune),
            onPressed: _openCustomize,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('Story 9:16')),
                ButtonSegment(value: false, label: Text('Post 1:1')),
              ],
              selected: {_story},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() => _story = s.first),
            ),
          ),
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: FittedBox(
                  fit: BoxFit.contain,
                  child: SizedBox(
                    width: w,
                    height: h,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // Verdeckte Hintergrund-Ebene (nur Verlauf/Foto) für
                        // „Nur Hintergrund speichern".
                        RepaintBoundary(
                          key: _bgBoundaryKey,
                          child: _graphic(backgroundOnly: true),
                        ),
                        RepaintBoundary(
                          key: _boundaryKey,
                          child: _graphic(),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (_settings.designMode)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.open_with,
                    size: 15,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Info-Block ziehen zum Platzieren',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                ],
              ),
            ),
          if (_bandPhotos.length == 1 && !_settings.designMode)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.open_with,
                    size: 15,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Foto ziehen & zoomen (Finger)',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                ],
              ),
            ),
          // Bedienung UNTER der Vorschau in einem scrollbaren Panel fester
          // Höhe → die Vorschau oben bleibt groß und sichtbar.
          if (widget.isAnnouncement)
            DecoratedBox(
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(color: Theme.of(context).dividerColor),
                ),
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.42,
                ),
                child: SingleChildScrollView(child: _announcementControls()),
              ),
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // KI-Bearbeitung nur, wenn der Admin die Grafik-KI (Gemini)
                  // für diesen Nutzer freigeschaltet hat.
                  if (context.watch<AppState>().canAiImage) ...[
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: (_sharing || _aiBusy) ? null : _aiEdit,
                        icon: _aiBusy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.auto_awesome),
                        label: Text(
                          _aiBusy ? 'KI gestaltet …' : 'Mit KI gestalten',
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: (_sharing || _aiBusy) ? null : _saveImage,
                          icon: const Icon(Icons.download),
                          label: const Text('Bild speichern'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: (_sharing || _aiBusy)
                              ? null
                              : _saveBackground,
                          icon: const Icon(Icons.wallpaper_outlined),
                          label: const Text('Nur Hintergrund'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: (_sharing || _aiBusy) ? null : _share,
                      icon: _sharing
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.share),
                      label: const Text('Teilen (WhatsApp)'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
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

// Akzentfarben für Highlights (erste = Weiß = „kein Akzent").
const _accentPalette = <String>[
  '#FFFFFF', // kein Akzent (Weiß wie bisher)
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
          child: Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true),
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
    this.showScorers = true,
    this.posterStyle = false,
    this.posterHeadline = 'SPIELTAG',
    this.posterMain,
    this.posterBadge,
    this.posterLogoDisc = true,
    this.posterShadow = false,
    this.posterShadowStrength = 45,
    this.posterShadowAngle = 45,
    this.posterOrder = const [],
    this.posterOverlays = const {},
    this.posterItemPos = const {},
    this.posterItemScale = const {},
    this.posterSelected,
    this.onPosterItemMove,
    this.onPosterSelect,
    this.posterFont = 'standard',
    this.showMainSponsor = true,
    this.showOtherSponsors = true,
    this.mainSponsorMode = 'logo',
    this.posterTexts = const {},
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
  final TransformationController? photoController; // einzelnes Band-Foto zoom/pan
  final bool designMode; // eigenes Branding-Design, nur Spiel-Infos drüber
  final Offset infoPos; // Position des Info-Blocks (0..1)
  final void Function(Offset pos)? onInfoMove; // Live-Verschieben
  final VoidCallback? onInfoMoveEnd; // Speichern nach dem Verschieben
  final Color? accent; // Akzentfarbe (Gold etc.); null = Weiß wie bisher
  final bool logoCircle; // Vereins-/Gegner-Logos auf rundem Feld (statt eckig)
  final double bgOpacity; // Deckkraft des Hintergrundbilds (0..1)
  final BlendMode bgBlend; // Mischmodus des Hintergrundbilds mit dem Verlauf
  final bool backgroundOnly; // nur die Hintergrund-Ebene (für Export)
  final bool showScorers; // Torschützen-Block in der Ergebnis-Grafik zeigen
  final bool posterStyle; // Spielankündigung: Spieler-Poster statt zentriert
  final String posterHeadline; // Poster-Überschrift (SPIELTAG / HEIMSPIEL / …)
  final String? posterMain; // großes Spielerbild (Data-URL)
  final String? posterBadge; // rundes Zweit-Foto (Data-URL)
  final bool posterLogoDisc; // heller Kreis hinter den Poster-Logos
  final bool posterShadow; // Schlagschatten beim freigestellten Spieler
  final double posterShadowStrength; // 0..100
  final double posterShadowAngle; // Richtung in Grad (0=rechts, 90=unten)
  final List<String> posterOrder; // Ebenen-Reihenfolge (hinten → vorne)
  final Map<String, String> posterOverlays; // id → Data-URL der Overlays
  final Map<String, Offset> posterItemPos; // Position je Element (0..1)
  final Map<String, double> posterItemScale; // Größe je Element
  final String? posterSelected; // aktuell gewähltes Element
  final void Function(String id, Offset pos)? onPosterItemMove;
  final void Function(String id)? onPosterSelect;
  final String posterFont; // Schriftart der Poster-Texte
  final bool showMainSponsor; // Hauptsponsor-Element anzeigen
  final bool showOtherSponsors; // weitere Sponsoren (Logo-Reihe) anzeigen
  final String mainSponsorMode; // 'logo' | 'text' – Hauptsponsor-Darstellung
  // Eigene Textfelder: id → (Inhalt, Schriftart, Farb-Key).
  final Map<String, ({String text, String font, String color})> posterTexts;

  /// Effektive Akzentfarbe (Weiß, wenn nichts gesetzt).
  Color get _accent => accent ?? Colors.white;

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
    final content = _standardLayout();
    final band = [
      for (final p in bandPhotos) TeamLogo.decode(p),
    ].whereType<Uint8List>().toList();
    if (band.isEmpty) return content;
    return _withPhotoBand(band, content);
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

    Widget vs() => Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (ownLogo != null)
          _logoChip(ownLogo, height: logoH, circle: logoCircle),
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
        if (oppLogo != null)
          _logoChip(oppLogo, height: logoH, circle: logoCircle),
      ],
    );

    final children = <Widget>[vs(), const SizedBox(height: 12)];

    final r = result;
    final a = announcement;
    if (r != null) {
      children.add(
        Text(
          '${r.ownScore} : ${r.oppScore}',
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
              // Kompakte Kopfleiste (Logo + Titel + Sponsor in EINER Zeile).
              _header(),
              SizedBox(height: compact ? 6 : 12),
              if (announcement == null) _matchInfo(),
              SizedBox(height: compact ? 7 : 18),
              _divider(),
              SizedBox(height: compact ? 7 : 16),
              if (result != null) ...[
                // Spielstand groß & fix (der Blickfang) …
                _scoreRow(),
                SizedBox(height: compact ? 10 : 14),
                // … darunter die Torschützen (nur wenn aktiviert).
                Expanded(
                  child: showScorers
                      ? FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.topCenter,
                          child: _scorersCardsBlock(),
                        )
                      : const SizedBox.shrink(),
                ),
              ] else
                Expanded(
                  child: Center(
                    child: FittedBox(
                      fit: BoxFit.contain,
                      alignment: Alignment.center,
                      child: _lineupBlock(),
                    ),
                  ),
                ),
              if (barSponsors.isNotEmpty) ...[
                SizedBox(height: compact ? 6 : 10),
                _sponsorBar(),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// Hintergrund-Basis: Verlauf, optional mit eigenem Hintergrundbild + Tönung.
  /// Wird von allen Layouts genutzt.
  Widget _bgBase({bool radial = false}) {
    // Hinzugefügtes Hintergrund-Foto hat Vorrang vor dem eingestellten Bild.
    final bgBytes = TeamLogo.decode(photoBg) ?? TeamLogo.decode(bgImage);
    // radial = Strahl/Vignette (heller Punkt oben-mitte → dunkel zu den Rändern),
    // wie beim Spieler-Poster; sonst klassischer Verlauf oben→unten.
    final Gradient baseGradient = radial
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
    height: 1.5,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(1),
      gradient: LinearGradient(
        colors: [
          _accent.withValues(alpha: 0.55),
          _accent.withValues(alpha: 0.08),
        ],
      ),
    ),
  );

  /// Kombinierte Kopfleiste: links Vereinslogo + „VEREIN / STARTELF", rechts
  /// „präsentiert von [Sponsor]". Spart Höhe → mehr Platz für den Kader.
  Widget _header() {
    final logoBytes = TeamLogo.decode(logo);
    final sponsorLogo = mainSponsor == null
        ? null
        : TeamLogo.decode(mainSponsor!.logo);
    final rubric = announcement != null
        ? 'SPIELTAG'
        : (result != null ? 'ERGEBNIS' : 'STARTELF');
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (logoBytes != null) ...[
          _logoChip(logoBytes, height: compact ? 52 : 66, circle: logoCircle),
          const SizedBox(width: 12),
        ] else if (logo != null) ...[
          TeamLogo(logoPath: logo, size: compact ? 52 : 66),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.9),
                  fontSize: compact ? 12 : 15,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
              ),
              Text(
                rubric,
                maxLines: 1,
                style: TextStyle(
                  color: _accent,
                  fontSize: compact ? 26 : 32,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.5,
                  height: 1.0,
                ),
              ),
            ],
          ),
        ),
        // „präsentiert von [Sponsor]" rechts in derselben Leiste.
        if (mainSponsor != null) ...[
          const SizedBox(width: 10),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                'PRÄSENTIERT VON',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.8),
                  fontSize: compact ? 7 : 9,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.5,
                ),
              ),
              SizedBox(height: compact ? 3 : 4),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: compact ? 118 : 150),
                child: sponsorLogo != null
                    ? _logoChip(sponsorLogo, height: compact ? 30 : 40)
                    : Text(
                        mainSponsor!.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: compact ? 14 : 18,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// Spielinfo-Zeile: Heim/Auswärts, Datum und darunter der Gegner („vs …")
  /// mit optionalem Gegner-Logo.
  Widget _matchInfo() {
    final line1 = <String>[isHome ? 'HEIMSPIEL' : 'AUSWÄRTSSPIEL'];
    if (matchDate != null) {
      final local = matchDate!.toLocal();
      line1.add(DateFormat('EEE, dd.MM.yyyy', 'de_DE').format(local));
      // Anstoßzeit anhängen, falls eine Uhrzeit gesetzt ist (nicht 00:00).
      if (local.hour != 0 || local.minute != 0) {
        line1.add('${DateFormat('HH:mm', 'de_DE').format(local)} Uhr');
      }
    }
    final oppBytes = TeamLogo.decode(opponentLogo);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          line1.join('  ·  '),
          style: TextStyle(
            color: _accent.withValues(alpha: 0.85),
            fontSize: compact ? 10 : 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1,
          ),
        ),
        // „vs GEGNER" nur bei Startelf/Spieltag – in der Ergebnis-Grafik steht
        // der Gegner ohnehin groß mit Logo + Spielstand darunter.
        if (result == null && opponentName.isNotEmpty) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              if (oppBytes != null) ...[
                _logoChip(oppBytes, height: compact ? 20 : 24, circle: logoCircle),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Text(
                  'vs ${opponentName.toUpperCase()}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: compact ? 13 : 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _lineupBlock() {
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
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 14 : 18,
        vertical: compact ? 10 : 16,
      ),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.32),
        borderRadius: BorderRadius.circular(18),
      ),
      child: inner,
    );
  }

  /// Großer, fixer Spielstand (der Blickfang): Logos + riesiger Score + Namen.
  Widget _scoreRow() {
    final r = result!;
    final ownLogo = TeamLogo.decode(logo);
    final oppLogo = TeamLogo.decode(opponentLogo);
    final logoH = compact ? 60.0 : 78.0;

    // Nur noch das Logo (Vereinsname entfällt – das Logo genügt), zentriert.
    Widget side(Uint8List? bytes) => bytes != null
        ? _logoChip(bytes, height: logoH, circle: logoCircle)
        : SizedBox(height: logoH);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(child: Center(child: side(ownLogo))),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Text(
            '${r.ownScore} : ${r.oppScore}',
            style: TextStyle(
              color: _accent,
              fontSize: compact ? 52 : 68,
              fontWeight: FontWeight.w900,
              height: 1.0,
            ),
          ),
        ),
        Expanded(child: Center(child: side(oppLogo))),
      ],
    );
  }

  /// Torschützen (NUR Tore – keine Karten): je Seite „Minute' Name" + optional
  /// Spielerfoto. Lesbar auf dunklem Scrim; der FittedBox im Layout skaliert bei
  /// vielen Einträgen herunter, bei wenigen bleibt es groß.
  Widget _scorersCardsBlock() {
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

    Widget line(
      ({int minute, String name, String? photo}) g, {
      required bool end,
    }) {
      final showPhoto = showPhotos && TeamLogo.decode(g.photo) != null;
      final children = <Widget>[
        if (showPhoto) ...[avatar(g.photo), const SizedBox(width: 8)],
        Flexible(
          child: Text(
            "${g.minute}'  ${g.name}",
            textAlign: end ? TextAlign.right : TextAlign.left,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 19,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ];
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: end
              ? MainAxisAlignment.end
              : MainAxisAlignment.start,
          children: end ? children.reversed.toList() : children,
        ),
      );
    }

    Widget col(
      List<({int minute, String name, String? photo})> goals, {
      required bool end,
    }) => Column(
      crossAxisAlignment: end
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [for (final g in goals) line(g, end: end)],
    );

    return Container(
      constraints: const BoxConstraints(maxWidth: 360),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.34),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.sports_soccer, size: 16, color: _accent),
              const SizedBox(width: 6),
              Text(
                'TORE',
                style: TextStyle(
                  color: _accent,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: col(ownGoals, end: false)),
              const SizedBox(width: 16),
              Expanded(child: col(oppGoals, end: true)),
            ],
          ),
        ],
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
    final infoLine = parts.join(' | ');

    // Einzelne, frei verschieb- und skalierbare Elemente.
    final Widget? sponsorW = mainSponsor == null
        ? null
        : (mainSponsorMode == 'text'
              ? _presentedByText(mainSponsor!.name)
              : _presentedBy(mainSponsor!));
    final Widget? sponsorbarW = barSponsors.isEmpty
        ? null
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final s in barSponsors)
                if (TeamLogo.decode(s.logo) case final b?)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Container(
                      padding: const EdgeInsets.all(5),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Image.memory(
                        b,
                        height: compact ? 22 : 28,
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                      ),
                    ),
                  ),
            ],
          );
    final Widget logosW = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        side(ownLogo),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Container(
            width: 1.5,
            height: logoH * 0.7,
            color: Colors.white.withValues(alpha: 0.5),
          ),
        ),
        side(oppLogo),
      ],
    );
    final Widget headlineW = Text(
      posterHeadline,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.visible,
      textAlign: TextAlign.center,
      style: posterFontStyle(
        posterFont,
        const TextStyle(
          color: Colors.white,
          fontSize: 58,
          fontWeight: FontWeight.w900,
          letterSpacing: 2,
          height: 1.0,
        ),
      ),
    );
    final Widget? infoW = infoLine.isEmpty
        ? null
        : Text(
            infoLine,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.visible,
            textAlign: TextAlign.center,
            style: posterFontStyle(
              posterFont,
              TextStyle(
                color: _accent,
                fontSize: compact ? 12 : 14,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.3,
              ),
            ),
          );
    return LayoutBuilder(
      builder: (ctx, c) {
        final w = c.maxWidth, h = c.maxHeight;

        // Bild mit optionalem Schlagschatten – gilt automatisch für JEDES Bild
        // (Spieler UND Overlays). Schatten-Silhouette (schwarz) hinter dem Bild.
        Widget imageWithShadow(Uint8List bytes, {double? width, double? height}) {
          Widget mk() => SizedBox(
            width: width,
            height: height,
            child: Image.memory(
              bytes,
              fit: BoxFit.contain,
              gaplessPlayback: true,
            ),
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

        // Inhalt je Element-ID (null = nicht vorhanden → wird übersprungen).
        Widget? content(String id) {
          switch (id) {
            case 'player':
              if (mainBytes == null) return null;
              return imageWithShadow(
                mainBytes,
                width: w - 2 * pad,
                height: h * 0.6,
              );
            case 'sponsor':
              return showMainSponsor ? sponsorW : null;
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
                final col = t.color == 'accent'
                    ? _accent
                    : (t.color == 'black' ? Colors.black : Colors.white);
                return Text(
                  t.text,
                  textAlign: TextAlign.center,
                  style: posterFontStyle(
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

        // Ein frei verschieb- und skalierbares Element (tippen = auswählen).
        Widget el(String id, Widget child) {
          final pos =
              posterItemPos[id] ??
              (posterStyle ? _kPosterItemDefaults : _kCenteredItemDefaults)[id] ??
              const Offset(0.5, 0.5);
          final scale = posterItemScale[id] ?? 1.0;
          final selected = posterSelected == id;
          // Antippen = auswählen. Das VERSCHIEBEN übernimmt eine Zieh-Ebene über
          // allem (unten), damit die Geste stabil bleibt – egal welche Größe/Ebene.
          return Align(
            key: ValueKey('posterEl_$id'),
            alignment: Alignment(pos.dx * 2 - 1, pos.dy * 2 - 1),
            child: Transform.scale(
              scale: scale,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (_) => onPosterSelect?.call(id),
                child: Container(
                  padding: const EdgeInsets.all(2),
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
              ),
            ),
          );
        }

        // Ebenen in echter Reihenfolge (hinten → vorne).
        final layers = <Widget>[];
        for (final id in posterOrder) {
          final child = content(id);
          if (child != null) layers.add(el(id, child));
        }

        // Zieh-Ebene ganz oben: bewegt das aktuell gewählte Element. Translucent →
        // Tippen geht zu den Elementen durch (Auswahl), Ziehen bewegt das Gewählte.
        final sel = posterSelected;
        final Widget? dragLayer = sel == null
            ? null
            : Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onPanUpdate: (d) {
                    final cur =
                        posterItemPos[sel] ??
                        (posterStyle
                            ? _kPosterItemDefaults
                            : _kCenteredItemDefaults)[sel] ??
                        const Offset(0.5, 0.5);
                    // KEINE Grenze – frei platzierbar, auch ganz außerhalb.
                    // (Solange ausgewählt, kann man es wieder zurückziehen.)
                    onPosterItemMove?.call(
                      sel,
                      Offset(cur.dx + d.delta.dx / w, cur.dy + d.delta.dy / h),
                    );
                  },
                ),
              );

        return Stack(
          fit: StackFit.expand,
          children: [
            _bgBase(radial: true),
            // Scrim oben → Texte bleiben über Bild/Hintergrund lesbar.
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
            ...layers,
            ?dragLayer,
          ],
        );
      },
    );
  }

  /// Hauptsponsor: „Präsentiert von" + Logo NEBENEINANDER (inline, weißer Chip)
  /// falls Logo vorhanden, sonst als Text.
  Widget _presentedBy(Sponsor s) {
    final logoBytes = TeamLogo.decode(s.logo);
    if (logoBytes == null) return _presentedByText(s.name);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          'Präsentiert von ',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.85),
            fontSize: compact ? 12 : 15,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(width: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(5),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Image.memory(
            logoBytes,
            height: compact ? 22 : 28,
            fit: BoxFit.contain,
            gaplessPlayback: true,
          ),
        ),
      ],
    );
  }

  /// Hauptsponsor NUR als Text („Präsentiert von NAME"), ohne Logo.
  Widget _presentedByText(String name) {
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: 'Präsentiert von ',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.85),
              fontSize: compact ? 12 : 15,
              fontWeight: FontWeight.w500,
            ),
          ),
          TextSpan(
            text: name.toUpperCase(),
            style: posterFontStyle(
              posterFont,
              const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.5,
              ),
            ),
          ),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
    );
  }

  Widget _sponsorBar() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final s in barSponsors)
            if (TeamLogo.decode(s.logo) != null)
              _logoChip(TeamLogo.decode(s.logo)!, height: compact ? 26 : 32),
        ],
      ),
    );
  }

  Widget _logoChip(Uint8List bytes, {required double height, bool circle = false}) {
    // Leichter 3D-/Erhebungs-Effekt: Schlagschatten unten.
    final shadow = [
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.55),
        blurRadius: 12,
        offset: const Offset(0, 5),
      ),
    ];
    if (circle) {
      // Rundes weißes Feld (quadratisch, Logo zentriert).
      return Container(
        width: height,
        height: height,
        padding: const EdgeInsets.all(6),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          boxShadow: shadow,
        ),
        child: Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true),
      );
    }
    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
        boxShadow: shadow,
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.9),
          width: 0.5,
        ),
      ),
      child: Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true),
    );
  }
}
