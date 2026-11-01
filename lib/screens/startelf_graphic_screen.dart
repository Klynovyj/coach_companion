import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:open_filex/open_filex.dart';
import 'package:provider/provider.dart';

import '../models/graphic_settings.dart';
import '../models/sponsor.dart';
import '../services/cloud_service.dart';
import '../services/share_service.dart';
import '../state/app_state.dart';
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
enum _PhotoPlace { background, band }

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

  bool get isResult => result != null;
  bool get isAnnouncement => announcement != null;

  @override
  State<StartelfGraphicScreen> createState() => _StartelfGraphicScreenState();
}

class _StartelfGraphicScreenState extends State<StartelfGraphicScreen> {
  final GlobalKey _boundaryKey = GlobalKey();
  bool _story = true; // true = Story 9:16, false = Post 1:1
  List<Sponsor> _sponsors = [];
  GraphicSettings _settings = const GraphicSettings(id: 'local');
  bool _loading = true;
  bool _sharing = false;
  bool _aiBusy = false;
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

  Future<String?> _pickImage({
    required bool asBackground,
    ImageSource source = ImageSource.gallery,
    bool edit = false,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final file = await ImagePicker().pickImage(
        source: source,
        maxWidth: asBackground ? 1600 : 600,
        maxHeight: asBackground ? 2400 : 600,
        imageQuality: asBackground ? 85 : 90,
      );
      if (file == null) return null;
      var bytes = await file.readAsBytes();
      // Vor dem Übernehmen bearbeiten (zuschneiden/drehen/Helligkeit/Kontrast).
      if (edit && mounted) {
        final edited = await Navigator.push<Uint8List?>(
          context,
          MaterialPageRoute(
            builder: (_) => PhotoEditorScreen(imageBytes: bytes),
          ),
        );
        if (edited == null) return null; // Abbruch im Editor
        bytes = edited;
      }
      final mime = asBackground ? 'image/jpeg' : 'image/png';
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
    final url = await _pickImage(asBackground: true, source: source, edit: true);
    if (url == null || !mounted) return;
    final place = await _askPlacement();
    if (place == null) return;
    setState(() {
      _photos.add(_GraphicPhoto(url, place));
      _photoCtrl.value = Matrix4.identity();
    });
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
      MaterialPageRoute(builder: (_) => PhotoEditorScreen(imageBytes: bytes)),
    );
    if (edited == null || !mounted) return;
    setState(() {
      p.dataUrl = 'data:image/jpeg;base64,${base64Encode(edited)}';
      _photoCtrl.value = Matrix4.identity();
    });
  }

  Future<void> _openCustomize() async {
    final titleCtrl = TextEditingController(text: _settings.title ?? '');
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
                  const SizedBox(height: 12),
                  // Hintergrundbild -------------------------------------
                  _rowWithImage(
                    label: 'Hintergrundbild',
                    preview: _settings.bgImage,
                    onPick: () async {
                      final url = await _pickImage(
                        asBackground: true,
                        edit: true,
                      );
                      if (url != null) apply(_settings.copyWith(bgImage: url));
                    },
                    onClear: _settings.bgImage == null
                        ? null
                        : () => apply(_settings.copyWith(clearBgImage: true)),
                    clearLabel: 'Entfernen',
                  ),
                  const SizedBox(height: 8),
                  // Hintergrund-Design (Vorlage) -------------------------
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Design-Vorlage (ohne eigenes Hintergrundbild)',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(ctx).hintColor,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    children: [
                      ChoiceChip(
                        label: const Text('Kein Design'),
                        selected: _settings.bgPreset == null,
                        onSelected: (_) =>
                            apply(_settings.copyWith(clearBgPreset: true)),
                      ),
                      ChoiceChip(
                        label: const Text('Streifen'),
                        selected: _settings.bgPreset == 'stripes',
                        onSelected: (_) =>
                            apply(_settings.copyWith(bgPreset: 'stripes')),
                      ),
                    ],
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
                  // Spielerfotos (nur Ergebnis-Grafik) -------------------
                  if (widget.isResult)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Spielerfotos anzeigen'),
                      subtitle: const Text('Fotos bei Torschützen & Karten'),
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
    // Speichern + in die Cloud spiegeln.
    if (!mounted) return;
    final state = context.read<AppState>();
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

  /// Die aktuell angezeigte Grafik als PNG-Bytes aufnehmen (1080 px breit).
  Future<Uint8List?> _captureGraphicPng() async {
    final boundary =
        _boundaryKey.currentContext?.findRenderObject()
            as RenderRepaintBoundary?;
    if (boundary == null) return null;
    final logicalWidth = _story ? _storyW : _postW;
    final image = await boundary.toImage(pixelRatio: 1080 / logicalWidth);
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
                  child: RepaintBoundary(
                    key: _boundaryKey,
                    child: SizedBox(
                      width: w,
                      height: h,
                      child: _StartelfGraphic(
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
                        opponentLogo:
                            (_settings.showOpponentLogo || _settings.designMode)
                            ? widget.opponentLogo
                            : null,
                        compact: !_story,
                        result: widget.result,
                        announcement: widget.announcement,
                        photoBg: _photoBg,
                        bandPhotos: _bandPhotos,
                        showPhotos: _settings.showPhotos,
                        bgPreset: _settings.bgPreset,
                        photoController: _photoCtrl,
                        designMode: _settings.designMode,
                        accent: _settings.accent == null
                            ? null
                            : _hex(_settings.accent!),
                        infoPos: Offset(_settings.infoX, _settings.infoY),
                        onInfoMove: (p) => setState(
                          () => _settings = _settings.copyWith(
                            infoX: p.dx,
                            infoY: p.dy,
                          ),
                        ),
                        onInfoMoveEnd: () =>
                            context.read<AppState>().saveGraphicSettings(
                              _settings,
                            ),
                      ),
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
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: (_sharing || _aiBusy) ? null : _saveImage,
                      icon: const Icon(Icons.download),
                      label: const Text('Bild speichern'),
                    ),
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

/// Eingebautes Hintergrund-Design „Streifen": diagonale, halbtransparente helle
/// Streifen im oberen Bereich (Farbe folgt dem gewählten Verlauf).
class _StripesPainter extends CustomPainter {
  _StripesPainter(this.base);
  final Color base;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final band = h * 0.34;
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, w, band));
    final light = Color.lerp(base, Colors.white, 0.7) ?? Colors.white;
    final a = Paint()..color = Colors.white.withValues(alpha: 0.10);
    final b = Paint()..color = light.withValues(alpha: 0.16);
    final stripeW = w * 0.05;
    final skew = band; // ~45°
    var x = -skew;
    var i = 0;
    while (x < w + skew) {
      final p = (i % 2 == 0) ? a : b;
      final path = Path()
        ..moveTo(x, band)
        ..lineTo(x + stripeW, band)
        ..lineTo(x + stripeW + skew, 0)
        ..lineTo(x + skew, 0)
        ..close();
      canvas.drawPath(path, p);
      x += stripeW * 1.6;
      i++;
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _StripesPainter old) => old.base != base;
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
    this.bgPreset,
    this.photoController,
    this.designMode = false,
    this.infoPos = const Offset(0.5, 0.72),
    this.onInfoMove,
    this.onInfoMoveEnd,
    this.accent,
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
  final String? bgPreset; // eingebautes Hintergrund-Design ('stripes')
  final TransformationController? photoController; // einzelnes Band-Foto zoom/pan
  final bool designMode; // eigenes Branding-Design, nur Spiel-Infos drüber
  final Offset infoPos; // Position des Info-Blocks (0..1)
  final void Function(Offset pos)? onInfoMove; // Live-Verschieben
  final VoidCallback? onInfoMoveEnd; // Speichern nach dem Verschieben
  final Color? accent; // Akzentfarbe (Gold etc.); null = Weiß wie bisher

  /// Effektive Akzentfarbe (Weiß, wenn nichts gesetzt).
  Color get _accent => accent ?? Colors.white;

  @override
  Widget build(BuildContext context) {
    if (designMode) return _designLayout();
    final content = announcement != null
        ? _announcementLayout()
        : _standardLayout();
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
        if (ownLogo != null) _logoChip(ownLogo, height: logoH),
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
        if (oppLogo != null) _logoChip(oppLogo, height: logoH),
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
      return ClipRect(
        child: InteractiveViewer(
          transformationController: photoController,
          minScale: 0.4,
          maxScale: 4,
          boundaryMargin: const EdgeInsets.all(double.infinity),
          clipBehavior: Clip.none,
          child: Image.memory(
            photos.first,
            fit: BoxFit.cover,
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
              _header(),
              if (mainSponsor != null) ...[
                SizedBox(height: compact ? 8 : 12),
                _presentedBy(mainSponsor!),
              ],
              SizedBox(height: compact ? 8 : 10),
              if (announcement == null) _matchInfo(),
              SizedBox(height: compact ? 12 : 18),
              _divider(),
              SizedBox(height: compact ? 12 : 16),
              if (result != null) ...[
                // Spielstand groß & fix (der Blickfang) …
                _scoreRow(),
                SizedBox(height: compact ? 10 : 14),
                // … darunter skalieren nur Torschützen/Karten mit.
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.topCenter,
                    child: _scorersCardsBlock(),
                  ),
                ),
              ] else
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.topCenter,
                    child: _lineupBlock(),
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

  /// Hintergrund-Basis: Verlauf + (eigenes Bild mit Tönung) ODER eingebautes
  /// Design (Streifen). Wird von allen Layouts genutzt.
  Widget _bgBase() {
    // Hinzugefügtes Hintergrund-Foto hat Vorrang vor dem eingestellten Bild.
    final bgBytes = TeamLogo.decode(photoBg) ?? TeamLogo.decode(bgImage);
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [gradTop, gradBottom],
            ),
          ),
        ),
        if (bgBytes != null) ...[
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
        ] else if (bgPreset == 'stripes')
          CustomPaint(painter: _StripesPainter(gradTop)),
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

  Widget _header() {
    return Row(
      children: [
        if (logo != null) ...[
          TeamLogo(logoPath: logo, size: compact ? 34 : 44),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.9),
                  fontSize: compact ? 13 : 15,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
              ),
              Text(
                announcement != null
                    ? 'SPIELTAG'
                    : (result != null ? 'ERGEBNIS' : 'STARTELF'),
                style: TextStyle(
                  color: _accent,
                  fontSize: 30,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.5,
                  height: 1.0,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Hauptsponsor als zentraler Blickfang: kleines „PRÄSENTIERT VON" darüber,
  /// darunter das Logo groß & mittig (ohne Logo der Name groß).
  Widget _presentedBy(Sponsor s) {
    final logoBytes = TeamLogo.decode(s.logo);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          'PRÄSENTIERT VON',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.8),
            fontSize: compact ? 10 : 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 2,
          ),
        ),
        SizedBox(height: compact ? 5 : 7),
        if (logoBytes != null)
          _logoChip(logoBytes, height: compact ? 38 : 50)
        else
          Text(
            s.name,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontSize: compact ? 22 : 28,
              fontWeight: FontWeight.w900,
            ),
          ),
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
        if (opponentName.isNotEmpty) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              if (oppBytes != null) ...[
                _logoChip(oppBytes, height: compact ? 20 : 24),
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
      color: Colors.white.withValues(alpha: 0.85),
      fontSize: 20,
      fontWeight: FontWeight.w800,
      fontFeatures: const [ui.FontFeature.tabularFigures()],
    );
    const nameStyle = TextStyle(
      color: Colors.white,
      fontSize: 21,
      fontWeight: FontWeight.w800,
      letterSpacing: 0.5,
      height: 1.05,
    );
    final posStyle = TextStyle(
      color: Colors.white.withValues(alpha: 0.7),
      fontSize: 11,
      fontWeight: FontWeight.w700,
      letterSpacing: 1,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final p in starters)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: 38,
                  child: Text(p.number?.toString() ?? '', style: numStyle),
                ),
                const SizedBox(width: 10),
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
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'BANK',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.9),
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 260,
                child: Text(
                  benchNames.map((n) => n.toUpperCase()).join(', '),
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.92),
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    height: 1.3,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// Großer, fixer Spielstand (der Blickfang): Logos + riesiger Score + Namen.
  Widget _scoreRow() {
    final r = result!;
    final ownLogo = TeamLogo.decode(logo);
    final oppLogo = TeamLogo.decode(opponentLogo);
    final logoH = compact ? 60.0 : 78.0;

    Widget side(Uint8List? bytes, String name) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (bytes != null)
          _logoChip(bytes, height: logoH)
        else
          SizedBox(height: logoH),
        const SizedBox(height: 8),
        SizedBox(
          width: 130,
          child: Text(
            name.toUpperCase(),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w800,
              height: 1.1,
            ),
          ),
        ),
      ],
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(child: side(ownLogo, title)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text(
            '${r.ownScore} : ${r.oppScore}',
            style: TextStyle(
              color: _accent,
              fontSize: compact ? 48 : 64,
              fontWeight: FontWeight.w900,
              height: 1.0,
            ),
          ),
        ),
        Expanded(
          child: side(oppLogo, opponentName.isEmpty ? 'Gegner' : opponentName),
        ),
      ],
    );
  }

  /// Torschützen + Karten (je Seite). Skaliert bei vielen Einträgen kleiner.
  Widget _scorersCardsBlock() {
    final r = result!;
    String mark(String k) => k == 'rot'
        ? '🟥'
        : (k == 'gelbrot' ? '🟧' : '🟨');
    final ownGoals = [
      for (final g in r.ownGoals)
        (text: "${g.minute}' ${g.name}", photo: g.photo),
    ];
    final oppGoals = [
      for (final g in r.oppGoals)
        (text: "${g.minute}' ${g.name}", photo: g.photo),
    ];
    final ownCards = [
      for (final c in r.ownCards)
        (text: "${mark(c.kind)} ${c.minute}' ${c.name}", photo: c.photo),
    ];
    final oppCards = [
      for (final c in r.oppCards)
        (text: "${mark(c.kind)} ${c.minute}' ${c.name}", photo: c.photo),
    ];

    Widget avatar(String? photo) {
      final bytes = TeamLogo.decode(photo);
      if (bytes == null) return const SizedBox.shrink();
      return Container(
        width: 20,
        height: 20,
        decoration: const BoxDecoration(shape: BoxShape.circle),
        clipBehavior: Clip.antiAlias,
        child: Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true),
      );
    }

    Widget section(
      String heading,
      List<({String text, String? photo})> left,
      List<({String text, String? photo})> right,
    ) {
      if (left.isEmpty && right.isEmpty) return const SizedBox.shrink();
      Widget line(({String text, String? photo}) e, {required bool end}) {
        final txt = Flexible(
          child: Text(
            e.text,
            textAlign: end ? TextAlign.right : TextAlign.left,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        );
        final children = <Widget>[
          if (showPhotos && e.photo != null) ...[
            avatar(e.photo),
            const SizedBox(width: 6),
          ],
          txt,
        ];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: end
                ? MainAxisAlignment.end
                : MainAxisAlignment.start,
            children: end ? children.reversed.toList() : children,
          ),
        );
      }

      Widget col(List<({String text, String? photo})> lines,
              {required bool end}) =>
          Column(
            crossAxisAlignment: end
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [for (final e in lines) line(e, end: end)],
          );
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 16),
          Text(
            heading,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.7),
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: col(left, end: false)),
              const SizedBox(width: 12),
              Expanded(child: col(right, end: true)),
            ],
          ),
        ],
      );
    }

    return SizedBox(
      width: 320,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          section('TORE', ownGoals, oppGoals),
          section('KARTEN', ownCards, oppCards),
        ],
      ),
    );
  }

  /// Spielankündigungs-Grafik: Titel (POKALSPIEL/SPIELTAG) + große Logos „VS" +
  /// Datum/Uhrzeit/Spielstätte/Adresse mit Icons.
  /// Pille „HEIMSPIEL" / „AUSWÄRTSSPIEL" mit Icon (Akzentfarbe).
  Widget _homeAwayBadge() {
    final label = isHome ? 'HEIMSPIEL' : 'AUSWÄRTSSPIEL';
    final icon = isHome ? Icons.home_rounded : Icons.flight_takeoff_rounded;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: _accent.withValues(alpha: 0.9), width: 1.5),
        color: _accent.withValues(alpha: 0.12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: _accent, size: 17),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              color: _accent,
              fontSize: 15,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _announcementLayout() {
    final a = announcement!;
    final ownLogo = TeamLogo.decode(logo);
    final oppLogo = TeamLogo.decode(opponentLogo);
    final pad = compact ? 18.0 : 26.0;
    final logoH = compact ? 72.0 : 92.0;

    Widget side(Uint8List? bytes) => bytes != null
        ? _logoChip(bytes, height: logoH)
        : SizedBox(height: logoH, width: logoH);

    Widget nameText(String n) => Text(
      n.toUpperCase(),
      textAlign: TextAlign.center,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 16,
        fontWeight: FontWeight.w800,
        height: 1.1,
      ),
    );

    // Datum/Uhrzeit stehen im Fokus → groesser als Spielstaette/Adresse.
    Widget infoRow(IconData icon, String text, {bool big = false}) => Padding(
      padding: EdgeInsets.symmetric(vertical: big ? 5 : 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: big ? 28 : 22),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white,
                fontSize: big ? 24 : 17,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );

    final rows = <Widget>[];
    if (matchDate != null) {
      final local = matchDate!.toLocal();
      rows.add(
        infoRow(
          Icons.event,
          DateFormat('EEEE, dd.MM.yyyy', 'de_DE').format(local),
          big: true,
        ),
      );
      if (local.hour != 0 || local.minute != 0) {
        rows.add(
          infoRow(
            Icons.schedule,
            '${DateFormat('HH:mm', 'de_DE').format(local)} Uhr',
            big: true,
          ),
        );
      }
    }
    if ((a.venue ?? '').trim().isNotEmpty) {
      rows.add(infoRow(Icons.place, a.venue!.trim()));
    }
    if ((a.address ?? '').trim().isNotEmpty) {
      rows.add(infoRow(Icons.map_outlined, a.address!.trim()));
    }

    final titleWord = a.isCup ? 'POKALSPIEL' : 'SPIELTAG';

    // Zentraler Inhalt (Sponsor → Titel → Logos → Namen → Info). Liegt in einer
    // FittedBox mit fester Breite, damit er immer in die Grafik passt und die
    // Adresse unten nie abgeschnitten wird (egal ob Story oder Post).
    final central = SizedBox(
      width: 320,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (mainSponsor != null) ...[
            _presentedBy(mainSponsor!),
            SizedBox(height: compact ? 14 : 18),
          ],
          Text(
            titleWord,
            maxLines: 1,
            softWrap: false,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _accent,
              fontSize: 52,
              fontWeight: FontWeight.w900,
              letterSpacing: 2,
              height: 1.0,
            ),
          ),
          if ((a.matchday ?? '').trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '${a.matchday!.trim()}. SPIELTAG',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.85),
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.5,
                ),
              ),
            ),
          SizedBox(height: compact ? 12 : 16),
          _homeAwayBadge(),
          SizedBox(height: compact ? 16 : 22),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: Center(child: side(ownLogo))),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(
                  'VS',
                  style: TextStyle(
                    color: _accent,
                    fontSize: compact ? 34 : 44,
                    fontWeight: FontWeight.w900,
                    height: 1.0,
                  ),
                ),
              ),
              Expanded(child: Center(child: side(oppLogo))),
            ],
          ),
          SizedBox(height: compact ? 8 : 12),
          Row(
            children: [
              Expanded(child: nameText(title)),
              const SizedBox(width: 56),
              Expanded(
                child: nameText(
                  opponentName.isEmpty ? 'Gegner' : opponentName,
                ),
              ),
            ],
          ),
          SizedBox(height: compact ? 20 : 28),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: rows,
          ),
        ],
      ),
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        _bgBase(),
        Padding(
          padding: EdgeInsets.all(pad),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.center,
                  child: central,
                ),
              ),
              if (barSponsors.isNotEmpty) ...[
                SizedBox(height: compact ? 8 : 12),
                _sponsorBar(),
              ],
            ],
          ),
        ),
      ],
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

  Widget _logoChip(Uint8List bytes, {required double height}) {
    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true),
    );
  }
}
