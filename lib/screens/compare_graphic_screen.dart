import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/compare_design.dart';
import '../models/designer_data.dart';
import '../models/graphic_settings.dart';
import '../models/player.dart';
import '../models/sponsor.dart';
import '../services/player_photos.dart';
import '../services/share_service.dart';
import '../services/svg_png.dart';
import '../state/app_state.dart';
import '../widgets/player_picker_page.dart';
import '../widgets/team_logo.dart';
import '../widgets/text_look.dart';
import 'photo_editor_screen.dart';
import '../widgets/bg_pattern.dart';
import '../widgets/color_picker_dialog.dart';
import '../widgets/logo_chip.dart';
import 'startelf_graphic_screen.dart'
    show
        kGradientPalette,
        kGradientPresets,
        normalizeImageBytes,
        posterFontStyle;

/// Logische Breite der Grafik; Export in 1080 px Breite.
const double _kW = 360;
const double _kExportWidth = 1080;

/// Rohpixel (RGBA) → JPEG-Data-URL fürs Vorschaubild (läuft im Isolate).
String _rgbaToJpegDataUrl(Map<String, Object> a) {
  final px = a['px'] as Uint8List;
  final im = img.Image.fromBytes(
    width: a['w'] as int,
    height: a['h'] as int,
    bytes: px.buffer,
    bytesOffset: px.offsetInBytes,
    numChannels: 4,
  );
  return 'data:image/jpeg;base64,${base64Encode(img.encodeJpg(im, quality: 80))}';
}

/// Designer-Vorlage „Vergleich": zwei Fotos nebeneinander – erst links, dann
/// rechts – auf austauschbarem Hintergrund (eigenes Bild oder Standard in
/// Vereinsfarben). Rahmen und Beschriftung zeichnet die App (abschaltbar,
/// falls sie schon im Hintergrundbild stecken).
class CompareGraphicScreen extends StatefulWidget {
  const CompareGraphicScreen({
    super.key,
    required this.designer,
    this.isNew = false,
  });

  final DesignerData designer;

  /// Neu angelegt → direkt nacheinander Foto links und rechts wählen.
  final bool isNew;

  @override
  State<CompareGraphicScreen> createState() => _CompareGraphicScreenState();
}

class _CompareGraphicScreenState extends State<CompareGraphicScreen> {
  late final AppState _app = context.read<AppState>();
  final _boundaryKey = GlobalKey();

  CompareDesign _design = CompareDesign();
  GraphicSettings? _settings;
  List<Sponsor> _sponsors = [];
  bool _loaded = false;
  bool _dirty = false;
  bool _exporting = false;
  bool _busy = false;
  late String _title = widget.designer.title;

  Timer? _saveTimer;
  String? _lastSaved;
  String? _thumb;
  DateTime _thumbAt = DateTime.fromMillisecondsSinceEpoch(0);

  // Bild-Cache: dieselbe Bytes-Instanz je URL → kein Flackern beim Ziehen.
  final Map<String, Uint8List> _bytes = {};
  final Map<String, Size> _sizes = {};
  final Set<String> _sizing = {};

  // Gesten (Ausschnitt verschieben/zoomen).
  Offset? _lastFocal;
  double _startZoom = 1;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _flushSave();
    super.dispose();
  }

  // ---------------------------------------------------------------- Laden

  Future<void> _load() async {
    final settings = await _app.graphicSettings();
    final sponsors = await _app.sponsors();
    final json = await _app.loadAnnouncementDesign(widget.designer.id);
    if (!mounted) return;
    setState(() {
      _settings = settings;
      _sponsors = sponsors.where((e) => e.enabled).toList();
      _apply(json);
      _loaded = true;
    });
    if (widget.isNew && (json == null || json.isEmpty)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _startFlow());
    } else {
      // Neuere Fassung von einem anderen Gerät im Hintergrund holen.
      unawaited(_refreshFromCloud(json));
    }
  }

  void _apply(String? json) {
    if (json == null || json.isEmpty) return;
    try {
      final m = jsonDecode(json);
      if (m is Map) {
        _design = CompareDesign.fromJson(m['compare']);
        _thumb = null;
        _lastSaved = json;
      }
    } catch (_) {}
  }

  Future<void> _refreshFromCloud(String? local) async {
    try {
      await _app.refreshAnnouncementDesign(widget.designer.id);
      final json = await _app.loadAnnouncementDesign(widget.designer.id);
      if (!mounted || _dirty || json == null || json == local) return;
      setState(() => _apply(json));
    } catch (_) {}
  }

  /// Neues Design: erst Foto links, dann Foto rechts wählen.
  Future<void> _startFlow() async {
    await _pickPhoto(0);
    if (!mounted) return;
    await _pickPhoto(1);
  }

  // ------------------------------------------------------------ Speichern

  void _changed() {
    _dirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), _flushSave);
  }

  void _flushSave() {
    _saveTimer?.cancel();
    if (!_loaded) return;
    final String data;
    try {
      data = jsonEncode({
        'designer': widget.designer.copyWith(title: _title).toJson(),
        'compare': _design.toJson(),
      });
    } catch (_) {
      return;
    }
    if (data == _lastSaved) return;
    _lastSaved = data;
    unawaited(
      _app.saveAnnouncementDesign(
        widget.designer.id,
        widget.designer.matchId,
        data,
        title: _title,
        kind: 'compare',
        thumb: _thumb,
      ),
    );
    if (mounted &&
        DateTime.now().difference(_thumbAt) > const Duration(seconds: 5)) {
      unawaited(_refreshThumb());
    }
  }

  /// Vorschaubild (~220 px) für „Meine Designs" auffrischen und mitspeichern.
  Future<void> _refreshThumb() async {
    _thumbAt = DateTime.now();
    try {
      final boundary =
          _boundaryKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) return;
      final image = await boundary.toImage(pixelRatio: 220 / _kW);
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return;
      final url = await compute(_rgbaToJpegDataUrl, <String, Object>{
        'w': image.width,
        'h': image.height,
        'px': data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      });
      if (url == _thumb) return;
      _thumb = url;
      _lastSaved = null; // erneut speichern, jetzt mit Vorschau
      _flushSave();
    } catch (_) {
      // Vorschau ist optional.
    }
  }

  Future<void> _leave() async {
    if (_dirty || _thumb == null) {
      _thumbAt = DateTime.fromMillisecondsSinceEpoch(0);
      await _refreshThumb();
    }
    _flushSave();
    if (mounted) Navigator.pop(context);
  }

  // --------------------------------------------------------------- Bilder

  Uint8List? _bytesOf(String? url) {
    if (url == null) return null;
    final c = _bytes[url];
    if (c != null) return c;
    final b = TeamLogo.decode(url);
    if (b != null) _bytes[url] = b;
    return b;
  }

  Size? _sizeOf(String? url) {
    if (url == null) return null;
    final s = _sizes[url];
    if (s != null) return s;
    final b = _bytesOf(url);
    if (b != null && _sizing.add(url)) {
      decodeImageFromList(b).then((im) {
        if (!mounted) return;
        setState(
          () => _sizes[url] = Size(im.width.toDouble(), im.height.toDouble()),
        );
        im.dispose();
      }, onError: (_) {});
    }
    return null;
  }

  Color _hex(String? h, Color def) => h == null ? def : hexColor(h);

  Color get _gradTop =>
      _hex(_settings?.gradTop, hexColor(GraphicSettings.defaultGradTop));
  Color get _gradBottom =>
      _hex(_settings?.gradBottom, hexColor(GraphicSettings.defaultGradBottom));

  Color get _clubColor => _hex(_settings?.gradTop, const Color(0xFF0E3325));

  // ---------------------------------------------------------- Auswahl Foto

  String _sideName(int i) => i == 0 ? 'links' : 'rechts';

  Future<String?> _askSource(String title) => showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library),
            title: const Text('Aus Galerie'),
            onTap: () => Navigator.pop(ctx, 'gallery'),
          ),
          if (Platform.isAndroid || Platform.isIOS)
            ListTile(
              leading: const Icon(Icons.photo_camera),
              title: const Text('Foto aufnehmen'),
              onTap: () => Navigator.pop(ctx, 'camera'),
            ),
          ListTile(
            leading: const Icon(Icons.photo),
            title: const Text('Google Fotos'),
            subtitle: Text(
              Platform.isAndroid
                  ? 'Im Foto-Picker auf Google Fotos wechseln'
                  : 'Öffnet Google Fotos im Browser zum Herunterladen',
            ),
            onTap: () => Navigator.pop(ctx, 'google'),
          ),
          ListTile(
            leading: const Icon(Icons.groups),
            title: const Text('Kader-Foto'),
            subtitle: const Text('Gespeichertes Spielerfoto'),
            onTap: () => Navigator.pop(ctx, 'kader'),
          ),
          ListTile(
            leading: const Icon(Icons.portrait),
            title: const Text('FuPa-Foto'),
            subtitle: const Text('Spielerbild von FuPa (960×1200)'),
            onTap: () => Navigator.pop(ctx, 'fupa'),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );

  /// Foto aus Galerie/Kamera laden und als JPEG-data:-URL liefern.
  Future<String?> _pickFromDevice(
    ImageSource source, {
    int maxSize = 1600,
    bool keepAlpha = false,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final file = await ImagePicker().pickImage(source: source);
      if (file == null) return null;
      final raw = await file.readAsBytes();
      final bytes = await compute(normalizeImageBytes, <String, dynamic>{
        'data': raw,
        'keepAlpha': keepAlpha,
        'maxSize': maxSize,
      });
      return _toDataUrl(bytes);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Bild konnte nicht geladen werden: $e')),
      );
      return null;
    }
  }

  String _toDataUrl(Uint8List bytes) {
    final png =
        bytes.length > 4 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47;
    return 'data:image/${png ? 'png' : 'jpeg'};base64,${base64Encode(bytes)}';
  }

  /// Google Fotos: Android = System-Picker (dort Google Fotos wählbar);
  /// Desktop = im Browser öffnen, Hinweis zeigen.
  Future<String?> _resolveGoogle(String src) async {
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

  Future<Player?> _pickPlayer(String title) async {
    final team = _app.ownTeam;
    if (team == null) return null;
    final players = await _app.playersOf(team.id, onlyActive: true);
    if (!mounted) return null;
    if (players.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Kein Kader vorhanden.')));
      return null;
    }
    players.sort((a, b) => a.fullName.compareTo(b.fullName));
    final id = await Navigator.push<String?>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            PlayerPickerPage(players: players, allowNone: false, title: title),
      ),
    );
    if (id == null || id == kPlayerPickNone) return null;
    for (final p in players) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// Foto für Seite [i] wählen (Quelle abfragen).
  Future<void> _pickPhoto(int i) async {
    final src0 = await _askSource('Foto ${_sideName(i)}');
    if (src0 == null || !mounted) return;
    final src = await _resolveGoogle(src0);
    if (src == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    String? url;
    switch (src) {
      case 'gallery':
      case 'camera':
        url = await _pickFromDevice(
          src == 'camera' ? ImageSource.camera : ImageSource.gallery,
        );
      case 'kader':
        final p = await _pickPlayer('Kader-Foto ${_sideName(i)}');
        if (p == null) return;
        url = p.photoPath;
        if (url == null) {
          messenger.showSnackBar(
            SnackBar(content: Text('${p.fullName} hat kein Kader-Foto.')),
          );
          return;
        }
      case 'fupa':
        final p = await _pickPlayer('FuPa-Foto ${_sideName(i)}');
        if (p == null || !mounted) return;
        setState(() => _busy = true);
        try {
          url =
              await _app.playerPhoto(p.id, PlayerPhotoSlot.fupa) ??
              await _app.fetchFupaOriginalPhoto(p);
        } catch (_) {
          url = null;
        } finally {
          if (mounted) setState(() => _busy = false);
        }
        if (url == null) {
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                'Kein FuPa-Foto für ${p.fullName} gefunden '
                '(FuPa-Verknüpfung im Kader prüfen).',
              ),
            ),
          );
          return;
        }
    }
    if (url == null || !mounted) return;
    final side = _design.side(i);
    setState(() {
      side.photo = url;
      side.resetCrop();
    });
    _changed();
  }

  /// Foto im Editor bearbeiten (Zuschnitt, Drehen, Helligkeit …).
  Future<void> _editPhoto(int i) async {
    final side = _design.side(i);
    final bytes = _bytesOf(side.photo);
    if (bytes == null) return;
    final edited = await Navigator.push<Uint8List?>(
      context,
      MaterialPageRoute(
        builder: (_) => PhotoEditorScreen(imageBytes: bytes, maxSize: 1600),
      ),
    );
    if (edited == null || !mounted) return;
    final norm = await compute(normalizeImageBytes, <String, dynamic>{
      'data': edited,
      'keepAlpha': false,
      'maxSize': 1600,
    });
    if (!mounted) return;
    setState(() {
      side.photo = _toDataUrl(norm);
      side.resetCrop();
    });
    _changed();
  }

  // ---------------------------------------------------------------- Menüs

  /// Bild aus einer Datei wählen – auch SVG (wird scharf in PNG umgewandelt).
  Future<String?> _pickFile({
    int maxSize = 1600,
    bool keepAlpha = false,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const [
          'png',
          'jpg',
          'jpeg',
          'webp',
          'gif',
          'bmp',
          'svg',
        ],
        withData: true,
      );
      final f = res?.files.firstOrNull;
      if (f == null) return null;
      var bytes = f.bytes;
      if (bytes == null && f.path != null) {
        bytes = await File(f.path!).readAsBytes();
      }
      if (bytes == null) return null;
      if ((f.extension ?? '').toLowerCase() == 'svg' || looksLikeSvg(bytes)) {
        final png = await svgToPng(bytes, maxSize: maxSize.toDouble());
        if (png == null) {
          messenger.showSnackBar(
            const SnackBar(
              content: Text('Das SVG konnte nicht gelesen werden.'),
            ),
          );
          return null;
        }
        return _toDataUrl(png);
      }
      final norm = await compute(normalizeImageBytes, <String, dynamic>{
        'data': bytes,
        'keepAlpha': keepAlpha,
        'maxSize': maxSize,
      });
      return _toDataUrl(norm);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Bild konnte nicht geladen werden: $e')),
      );
      return null;
    }
  }

  /// Zoom-Zeile: − / Regler / + (für Fotos, Logos, Sponsoren).
  Widget _zoomRow(
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged,
  ) {
    double clampV(double v) => v.clamp(min, max).toDouble();
    return Row(
      children: [
        const SizedBox(
          width: 44,
          child: Text('Zoom', style: TextStyle(fontSize: 13)),
        ),
        IconButton(
          tooltip: 'Kleiner',
          icon: const Icon(Icons.remove_circle_outline),
          onPressed: () => onChanged(clampV(value / 1.1)),
        ),
        Expanded(
          child: Slider(
            value: clampV(value),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
        IconButton(
          tooltip: 'Größer',
          icon: const Icon(Icons.add_circle_outline),
          onPressed: () => onChanged(clampV(value * 1.1)),
        ),
        SizedBox(
          width: 40,
          child: Text(
            '${(value * 100).round()}%',
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ],
    );
  }

  /// Sponsoren mit Logo, die auf der Grafik erscheinen (Auswahl je Design).
  List<Sponsor> get _shownSponsors {
    final ids = _design.sponsorIds;
    return [
      for (final s in _sponsors)
        if (s.logo != null && (ids == null || ids.contains(s.id))) s,
    ];
  }

  Future<void> _sponsorMenu() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      barrierColor: Colors.black12,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.55,
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          void upd(VoidCallback fn) {
            setState(fn);
            setSheet(() {});
            _changed();
          }

          final withLogo = _sponsors.where((s) => s.logo != null).toList();
          return SafeArea(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'Sponsoren-Leiste',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text(
                    Platform.isAndroid || Platform.isIOS
                        ? 'Auf der Grafik ziehen = verschieben, zwei Finger = '
                              'zoomen'
                        : 'Auf der Grafik ziehen = verschieben, Mausrad = zoomen',
                  ),
                  value: _design.sponsors,
                  onChanged: (v) => upd(() => _design.sponsors = v),
                ),
                if (_design.sponsors) ...[
                  _zoomRow(
                    _design.sponsorZoom,
                    0.3,
                    3,
                    (v) => upd(() => _design.sponsorZoom = v),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      icon: const Icon(Icons.restart_alt),
                      label: const Text('Größe & Lage zurücksetzen'),
                      onPressed: () => upd(() {
                        _design.sponsorZoom = 1;
                        _design.sponsorDx = 0;
                        _design.sponsorDy = 0;
                      }),
                    ),
                  ),
                  const Divider(),
                  if (withLogo.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text('Noch keine Sponsoren mit Logo.'),
                    ),
                  for (final s in withLogo)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      secondary: SizedBox(
                        width: 56,
                        height: 32,
                        child: Image.memory(
                          _bytesOf(s.logo)!,
                          fit: BoxFit.contain,
                        ),
                      ),
                      title: Text(s.name.isEmpty ? 'Sponsor' : s.name),
                      subtitle: s.isMain ? const Text('Hauptsponsor') : null,
                      value:
                          _design.sponsorIds == null ||
                          _design.sponsorIds!.contains(s.id),
                      onChanged: (v) => upd(() {
                        final ids =
                            _design.sponsorIds ??
                            withLogo.map((e) => e.id).toList();
                        _design.sponsorIds = [
                          for (final e in withLogo)
                            if (e.id == s.id ? v == true : ids.contains(e.id))
                              e.id,
                        ];
                      }),
                    ),
                ],
                const SizedBox(height: 4),
                OutlinedButton.icon(
                  icon: const Icon(Icons.add_business_outlined),
                  label: const Text('Neuen Sponsor anlegen'),
                  onPressed: () async {
                    await _addSponsor();
                    setSheet(() {});
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Neuen Sponsor anlegen (Name + Logo, auch SVG) – landet in der
  /// Sponsorenliste des Teams und direkt auf dieser Grafik.
  Future<void> _addSponsor() async {
    final nameCtrl = TextEditingController();
    String? logo;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Neuer Sponsor'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              if (logo != null)
                SizedBox(
                  height: 70,
                  child: Image.memory(_bytesOf(logo)!, fit: BoxFit.contain),
                ),
              OutlinedButton.icon(
                icon: const Icon(Icons.image_outlined),
                label: Text(
                  logo == null
                      ? 'Logo wählen (PNG, JPG, SVG …)'
                      : 'Anderes Logo',
                ),
                onPressed: () async {
                  final url = await _pickFile(maxSize: 900, keepAlpha: true);
                  if (url != null) setD(() => logo = url);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () {
                if (nameCtrl.text.trim().isEmpty || logo == null) return;
                Navigator.pop(ctx, true);
              },
              child: const Text('Anlegen'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    final s = await _app.addSponsor(nameCtrl.text, logo: logo);
    final list = await _app.sponsors();
    if (!mounted) return;
    setState(() {
      _sponsors = list.where((e) => e.enabled).toList();
      _design.sponsors = true;
      final ids = _design.sponsorIds;
      if (ids != null && !ids.contains(s.id)) ids.add(s.id);
    });
    _changed();
  }

  /// Sponsoren-Leiste (unten), verschieb- und zoombar.
  Widget? _sponsorBar(double W, double H) {
    if (!_design.sponsors) return null;
    final list = _shownSponsors;
    if (list.isEmpty) return null;
    final barH = 0.055 * H;
    final cy = (0.955 + _design.sponsorDy) * H;
    void zoomBy(double f) {
      setState(
        () => _design.sponsorZoom = (_design.sponsorZoom * f).clamp(0.3, 3.0),
      );
      _changed();
    }

    return Positioned(
      left: 0,
      width: W,
      top: cy - barH / 2,
      height: barH,
      child: Transform.translate(
        offset: Offset(_design.sponsorDx * W, 0),
        child: Transform.scale(
          scale: _design.sponsorZoom,
          child: Center(
            child: Listener(
              onPointerSignal: (e) {
                if (e is PointerScrollEvent) {
                  zoomBy(e.scrollDelta.dy < 0 ? 1.08 : 0.926);
                }
              },
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _sponsorMenu,
                onScaleStart: (d) {
                  _lastFocal = d.focalPoint;
                  _startZoom = _design.sponsorZoom;
                },
                onScaleUpdate: (d) {
                  final last = _lastFocal;
                  _lastFocal = d.focalPoint;
                  if (last == null) return;
                  // Globale Verschiebung → Grafik-Koordinaten.
                  final box =
                      _boundaryKey.currentContext?.findRenderObject()
                          as RenderBox?;
                  final scr = box?.getTransformTo(null).getMaxScaleOnAxis();
                  final k = scr == null || scr == 0 ? 1.0 : 1 / scr;
                  final delta = (d.focalPoint - last) * k;
                  setState(() {
                    if (d.pointerCount >= 2) {
                      _design.sponsorZoom = (_startZoom * d.scale).clamp(
                        0.3,
                        3.0,
                      );
                    }
                    _design.sponsorDx = (_design.sponsorDx + delta.dx / W)
                        .clamp(-0.5, 0.5);
                    _design.sponsorDy = (_design.sponsorDy + delta.dy / H)
                        .clamp(-0.95, 0.04);
                  });
                },
                onScaleEnd: (_) {
                  _lastFocal = null;
                  _changed();
                },
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: W * 0.94),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var k = 0; k < list.length; k++) ...[
                          if (k > 0) SizedBox(width: barH * 0.35),
                          LogoChip(
                            bytes: _bytesOf(list[k].logo)!,
                            height: barH,
                            mode: list[k].chip,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _sideMenu(int i) async {
    final side = _design.side(i);
    if (side.photo == null) return _pickPhoto(i);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      barrierColor: Colors.black12,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Foto ${_sideName(i)}',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        Platform.isAndroid || Platform.isIOS
                            ? 'Im Bild ziehen = verschieben, mit zwei Fingern zoomen.'
                            : 'Im Bild ziehen = verschieben, Mausrad = zoomen.',
                        style: Theme.of(ctx).textTheme.bodySmall,
                      ),
                      _zoomRow(side.zoom, 0.3, 5, (v) {
                        _setPhotoZoom(i, v);
                        setSheet(() {});
                      }),
                    ],
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.swap_horiz),
                  title: const Text('Anderes Foto wählen'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _pickPhoto(i);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.tune),
                  title: const Text('Bearbeiten'),
                  subtitle: const Text('Zuschneiden, drehen, Helligkeit'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _editPhoto(i);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.center_focus_strong),
                  title: const Text('Ausschnitt zurücksetzen'),
                  onTap: () {
                    Navigator.pop(ctx);
                    setState(side.resetCrop);
                    _changed();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.compare_arrows),
                  title: const Text('Fotos tauschen (links ↔ rechts)'),
                  onTap: () {
                    Navigator.pop(ctx);
                    setState(_design.swapSides);
                    _changed();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.delete_outline, color: Colors.red),
                  title: const Text(
                    'Foto entfernen',
                    style: TextStyle(color: Colors.red),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    setState(() {
                      side.photo = null;
                      side.resetCrop();
                    });
                    _changed();
                  },
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Foto-Zoom setzen (Ausschnitt bleibt gültig).
  void _setPhotoZoom(int i, double z) {
    final side = _design.side(i);
    side.zoom = z.clamp(0.3, 5.0);
    final size = _sizeOf(side.photo);
    final g = _design.current;
    final h = _kW / compareAspect(_design.format);
    if (size != null) {
      _pan(side, Offset.zero, g.widthOf(i) * _kW, g.height * h, size);
    } else {
      setState(() {});
    }
    _changed();
  }

  /// Team-Grafik-Einstellungen ändern (Verlaufsfarben gelten teamweit).
  Future<void> _applySettings(GraphicSettings s) async {
    setState(() => _settings = s);
    _thumbAt = DateTime.fromMillisecondsSinceEpoch(0);
    _changed();
    try {
      await _app.saveGraphicSettings(s);
    } catch (_) {}
  }

  Widget _swatchRow(
    BuildContext ctx,
    String selected,
    ValueChanged<String> onPick,
  ) {
    Widget box(Widget child, bool sel, VoidCallback onTap) => GestureDetector(
      onTap: onTap,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: sel ? Theme.of(ctx).colorScheme.primary : Colors.black26,
            width: sel ? 3 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: child,
      ),
    );
    final inPalette = kGradientPalette.any(
      (h) => h.toUpperCase() == selected.toUpperCase(),
    );
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final hex in kGradientPalette)
          box(
            ColoredBox(color: hexColor(hex)),
            hex.toUpperCase() == selected.toUpperCase(),
            () => onPick(hex),
          ),
        box(
          inPalette
              ? const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: SweepGradient(
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
                  ),
                )
              : ColoredBox(
                  color: hexColor(selected),
                  child: const Icon(
                    Icons.colorize,
                    size: 16,
                    color: Colors.white,
                  ),
                ),
          !inPalette,
          () async {
            final hex = await showHsvColorPicker(ctx, selected);
            if (hex != null) onPick(hex);
          },
        ),
      ],
    );
  }

  Future<void> _backgroundMenu() async {
    final fmt = compareFormatLabel(_design.format);
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      barrierColor: Colors.black12,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.55,
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          void upd(VoidCallback fn) {
            setState(fn);
            setSheet(() {});
            _changed();
          }

          Future<void> setColors(GraphicSettings s) async {
            await _applySettings(s);
            setSheet(() {});
          }

          final s = _settings ?? GraphicSettings(id: 'local');
          final has = _design.backgrounds[_design.format] != null;
          Widget head(String t) => Padding(
            padding: const EdgeInsets.only(top: 14, bottom: 6),
            child: Text(t, style: const TextStyle(fontWeight: FontWeight.bold)),
          );
          return SafeArea(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              children: [
                const Text(
                  'Hintergrund',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
                if (has)
                  Text(
                    'Eigenes Bild aktiv ($fmt). Der Verlauf liegt nur als '
                    'Tönung darüber (Regler unten).',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                head('Verlauf'),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final (k, label, icon) in const [
                      ('linear', 'Oben → unten', Icons.gradient),
                      ('radial', 'Strahl', Icons.flare),
                      ('diagonal', 'Diagonal', Icons.call_made),
                    ])
                      ChoiceChip(
                        avatar: Icon(icon, size: 18),
                        label: Text(label),
                        selected: _design.gradShape == k,
                        onSelected: (_) => upd(() => _design.gradShape = k),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                const Text('Farbe oben'),
                const SizedBox(height: 6),
                _swatchRow(
                  ctx,
                  s.gradTop,
                  (h) => setColors(s.copyWith(gradTop: h)),
                ),
                const SizedBox(height: 10),
                const Text('Farbe unten'),
                const SizedBox(height: 6),
                _swatchRow(
                  ctx,
                  s.gradBottom,
                  (h) => setColors(s.copyWith(gradBottom: h)),
                ),
                const SizedBox(height: 10),
                const Text('Vorlagen'),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final p in kGradientPresets)
                      ActionChip(
                        avatar: Container(
                          width: 18,
                          height: 18,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(4),
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [hexColor(p.$2), hexColor(p.$3)],
                            ),
                          ),
                        ),
                        label: Text(p.$1),
                        onPressed: () => setColors(
                          s.copyWith(
                            gradTop: p.$2,
                            gradBottom: p.$3,
                            accent: p.$4,
                            clearAccent: p.$4 == null,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Die Verlaufsfarben gelten teamweit – auch für Spieltag, '
                  'Startelf und Ergebnis.',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Muster (Splitter)'),
                  value: _design.pattern,
                  onChanged: (v) => upd(() => _design.pattern = v),
                ),
                if (_design.pattern)
                  _slider(
                    'Stärke',
                    _design.patternStrength,
                    0.1,
                    1.5,
                    (v) => upd(() => _design.patternStrength = v),
                    percent: true,
                  ),
                const Divider(height: 24),
                const Text(
                  'Eigenes Bild',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                Text(
                  'Hat das Bild schon zwei Foto-Felder (z. B. schwarze '
                  'Rahmen), werden die Fotos automatisch eingepasst.',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                if (has)
                  _slider(
                    'Verlauf darüber',
                    _design.tint,
                    0,
                    1,
                    (v) => upd(() => _design.tint = v),
                    percent: true,
                  ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.wallpaper),
                  title: Text(has ? 'Anderes Bild wählen' : 'Bild wählen'),
                  subtitle: const Text(
                    'Für alle Formate ohne eigenes Bild · PNG, JPG, SVG …',
                  ),
                  onTap: () => Navigator.pop(ctx, 'all'),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.crop_portrait),
                  title: Text('Bild nur für $fmt'),
                  onTap: () => Navigator.pop(ctx, 'one'),
                ),
                if (has)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.gradient),
                    title: const Text('Bild entfernen → Verlauf'),
                    subtitle: Text('Für $fmt'),
                    onTap: () => Navigator.pop(ctx, 'default'),
                  ),
              ],
            ),
          );
        },
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'default') {
      setState(() {
        _design.setBackground(null, allFormats: false);
        _design.geom[_design.format] = CompareGeom.defaults(_design.format);
        _design.frames = true;
        _design.labels = true;
      });
      _changed();
      return;
    }
    final url = await _pickFile(maxSize: 1920);
    if (url == null || !mounted) return;
    final before = Map<String, String>.of(_design.backgrounds);
    setState(() => _design.setBackground(url, allFormats: choice == 'all'));
    _changed();
    // Foto-Felder im Bild suchen – für jedes Format, das das Bild bekam.
    await _detectFrames([
      for (final f in kCompareFormats)
        if (_design.backgrounds[f] == url && before[f] != url) f,
    ]);
  }

  /// Foto-Felder im Hintergrund der Formate [formats] erkennen und die Fotos
  /// darin einpassen (mit Rückfrage, ob eigene Rahmen/Texte ausgehen).
  Future<void> _detectFrames(
    List<String> formats, {
    bool manual = false,
  }) async {
    final found = <String, List<double>>{};
    setState(() => _busy = true);
    try {
      for (final f in formats) {
        final bytes = _bytesOf(_design.backgrounds[f]);
        if (bytes == null) continue;
        final r = await compute(detectCompareFrames, <String, Object>{
          'data': bytes,
          'aspect': compareAspect(f),
        });
        if (r != null) found[f] = r;
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    if (found.isEmpty) {
      if (manual || formats.contains(_design.format)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Keine Foto-Felder im Bild erkannt – Lage unter „Rahmen & Lage" '
              'anpassen.',
            ),
          ),
        );
      }
      return;
    }
    var hideFrames = _design.frames;
    var hideLabels = _design.labels;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Foto-Felder erkannt'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Die Fotos werden genau in die zwei Felder des Hintergrunds '
                'gesetzt (${found.keys.map(compareFormatLabel).join(', ')}).',
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: hideFrames,
                onChanged: (v) => setD(() => hideFrames = v ?? false),
                title: const Text('Eigene Rahmen ausblenden'),
                subtitle: const Text('Die Rahmen stecken schon im Bild'),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: hideLabels,
                onChanged: (v) => setD(() => hideLabels = v ?? false),
                title: const Text('Eigene Beschriftung ausblenden'),
                subtitle: const Text('z. B. Jahreszahlen stehen schon im Bild'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Nicht einpassen'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Einpassen'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      for (final e in found.entries) {
        final v = e.value;
        _design
            .geomOf(e.key)
            .applyDetected((v[0], v[1], v[2], v[3]), (v[4], v[5], v[6], v[7]));
      }
      if (hideFrames) _design.frames = false;
      if (hideLabels) _design.labels = false;
      _design.left.resetCrop();
      _design.right.resetCrop();
    });
    _changed();
  }

  Future<void> _logoMenu(int i) async {
    final side = _design.side(i);
    final clubLogo = _app.ownTeam?.logoPath;
    final hasOpp = _opponentLogos().isNotEmpty;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      barrierColor: Colors.black12,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Über dem Foto ${_sideName(i)}',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      if (side.hasTop) ...[
                        const SizedBox(height: 2),
                        Text(
                          Platform.isAndroid || Platform.isIOS
                              ? 'Im Feld ziehen = verschieben, mit zwei Fingern '
                                    'größer/kleiner.'
                              : 'Im Feld ziehen = verschieben, Mausrad = '
                                    'größer/kleiner.',
                          style: Theme.of(ctx).textTheme.bodySmall,
                        ),
                        _zoomRow(side.logoZoom, 0.3, 3, (v) {
                          setState(() => side.logoZoom = v);
                          setSheet(() {});
                          _changed();
                        }),
                      ],
                    ],
                  ),
                ),
                if (clubLogo != null)
                  ListTile(
                    leading: const Icon(Icons.shield_outlined),
                    title: const Text('Vereinslogo'),
                    onTap: () => Navigator.pop(ctx, 'club'),
                  ),
                if (hasOpp)
                  ListTile(
                    leading: const Icon(Icons.groups_2_outlined),
                    title: const Text('Gegner-Logo'),
                    subtitle: const Text('Aus deinen Spielen'),
                    onTap: () => Navigator.pop(ctx, 'opp'),
                  ),
                ListTile(
                  leading: const Icon(Icons.photo_library),
                  title: const Text('Bild/Logo aus Datei'),
                  subtitle: const Text('PNG, JPG, SVG … (Transparenz bleibt)'),
                  onTap: () => Navigator.pop(ctx, 'gallery'),
                ),
                ListTile(
                  leading: const Icon(Icons.text_fields),
                  title: Text(
                    side.logoText != null
                        ? 'Text bearbeiten'
                        : 'Text statt Bild',
                  ),
                  subtitle: const Text('z. B. „SAISON 13/14"'),
                  onTap: () => Navigator.pop(ctx, 'text'),
                ),
                if (side.hasTop) ...[
                  ListTile(
                    leading: const Icon(Icons.center_focus_strong),
                    title: const Text('Größe & Lage zurücksetzen'),
                    onTap: () => Navigator.pop(ctx, 'reset'),
                  ),
                  ListTile(
                    leading: const Icon(
                      Icons.delete_outline,
                      color: Colors.red,
                    ),
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
        ),
      ),
    );
    if (choice == null || !mounted) return;
    switch (choice) {
      case 'reset':
        setState(side.resetLogoPos);
        _changed();
        return;
      case 'remove':
        setState(() {
          side.logo = null;
          side.logoText = null;
          side.resetLogoPos();
        });
        _changed();
        return;
      case 'text':
        await _editTopText(i);
        return;
    }
    String? url;
    if (choice == 'club') {
      url = clubLogo;
    } else if (choice == 'opp') {
      url = await _pickOpponentLogo();
    } else if (choice == 'gallery') {
      url = await _pickFile(maxSize: 900, keepAlpha: true);
    }
    if (url == null || !mounted) return;
    setState(() {
      side.logo = url;
      side.logoText = null;
      side.resetLogoPos();
    });
    _changed();
  }

  /// Gegner-Logos aus den Spielen (je Verein einmal, alphabetisch).
  List<(String, String)> _opponentLogos() {
    final seen = <String>{};
    final out = <(String, String)>[];
    for (final m in _app.matches) {
      final logo = m.opponentLogoPath;
      final name = m.opponentName.trim();
      if (logo == null || logo.isEmpty || name.isEmpty) continue;
      if (!seen.add(name.toLowerCase())) continue;
      if (_bytesOf(logo) == null) continue;
      out.add((name, logo));
    }
    out.sort((a, b) => a.$1.toLowerCase().compareTo(b.$1.toLowerCase()));
    return out;
  }

  Future<String?> _pickOpponentLogo() {
    final logos = _opponentLogos();
    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.7,
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Gegner-Logo wählen',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ),
            ),
            Expanded(
              child: GridView.extent(
                maxCrossAxisExtent: 110,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 0.85,
                children: [
                  for (final (name, logo) in logos)
                    InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => Navigator.pop(ctx, logo),
                      child: Column(
                        children: [
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.all(6),
                              child: Image.memory(
                                _bytesOf(logo)!,
                                fit: BoxFit.contain,
                              ),
                            ),
                          ),
                          Text(
                            name,
                            maxLines: 2,
                            textAlign: TextAlign.center,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  TextLook get _topLook => _design.topLook == null
      ? const TextLook()
      : TextLook.fromJson(_design.topLook!);

  /// Text über dem Foto [i] eingeben (statt eines Bildes).
  Future<void> _editTopText(int i) async {
    final side = _design.side(i);
    final ctrl = TextEditingController(text: side.logoText ?? '');
    final t = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Text über dem Foto ${_sideName(i)}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              maxLines: null,
              decoration: const InputDecoration(
                hintText: 'z. B. SAISON 13/14',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Zeilenumbruch nur mit Enter. Schrift, Farbe und Schatten '
              'gelten für beide Seiten.',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.text_format),
              label: const Text('Schrift, Farbe, Schatten, Ausrichtung'),
              onPressed: () => showTextLookSheet(
                context,
                title: 'Text über den Fotos',
                initial: _topLook,
                palette: _palette,
                onChanged: (l) {
                  setState(
                    () => _design.topLook = l.isDefault ? null : l.toJson(),
                  );
                  _changed();
                },
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('Übernehmen'),
          ),
        ],
      ),
    );
    if (t == null || !mounted) return;
    setState(() {
      if (t.trim().isEmpty) {
        side.logoText = null;
      } else {
        if (side.logoText == null) side.resetLogoPos();
        side.logoText = t;
        side.logo = null;
      }
    });
    _changed();
  }

  /// Feld über dem Foto [i]: Bild/Logo oder Text, verschieb- und zoombar.
  /// Leer → Platzhalter (nur im Editor und nur beim Standard-Hintergrund).
  Widget? _topSlot(int i, CompareGeom g, double W, double H, double top) {
    if (g.logoHeight <= 0) return null;
    final side = _design.side(i);
    final bw = g.widthOf(i) * W;
    final bh = g.logoHeight * H;
    final showPlaceholder =
        !side.hasTop &&
        !_exporting &&
        _design.backgrounds[_design.format] == null;
    if (!side.hasTop && !showPlaceholder) return null;
    Widget content;
    if (!side.hasTop) {
      content = Container(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.35),
            width: 0.8,
          ),
          borderRadius: BorderRadius.circular(4),
        ),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.add_photo_alternate_outlined,
              color: Colors.white.withValues(alpha: 0.7),
              size: math.min(26, bh * 0.35),
            ),
            if (bh > 50)
              Text(
                'Logo ${_sideName(i)}',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 11,
                ),
              ),
          ],
        ),
      );
    } else {
      final Widget inner;
      if (side.logoText != null) {
        final look = _topLook;
        final fs = bh * 0.34;
        var base = TextStyle(
          color: Colors.white,
          fontSize: fs,
          fontWeight: FontWeight.w700,
          height: 1.05,
          shadows: look.shadow == null
              ? textShadowsFor('soft', fs, _clubColor)
              : null,
        );
        if (look.font == null) base = posterFontStyle('barlow', base);
        inner = Center(
          child: OverflowBox(
            minWidth: 0,
            minHeight: 0,
            maxWidth: double.infinity,
            maxHeight: double.infinity,
            fit: OverflowBoxFit.deferToChild,
            child: Text(
              side.logoText!,
              softWrap: false,
              textAlign: look.textAlign(TextAlign.center),
              style: look.apply(base, glow: _clubColor),
            ),
          ),
        );
      } else {
        inner = Image.memory(
          _bytesOf(side.logo)!,
          fit: BoxFit.contain,
          gaplessPlayback: true,
        );
      }
      content = Transform.translate(
        offset: Offset(side.logoDx * bw, side.logoDy * bh),
        child: Transform.scale(scale: side.logoZoom, child: inner),
      );
    }
    void zoomBy(double f) {
      setState(() => side.logoZoom = (side.logoZoom * f).clamp(0.3, 3.0));
      _changed();
    }

    return Positioned(
      left: g.frameLeft(i) * W,
      width: bw,
      top: math.max(0, top - bh - 0.012 * H),
      height: bh,
      child: Listener(
        onPointerSignal: (e) {
          if (e is PointerScrollEvent && side.hasTop) {
            zoomBy(e.scrollDelta.dy < 0 ? 1.08 : 0.926);
          }
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _logoMenu(i),
          onScaleStart: (d) {
            _lastFocal = d.localFocalPoint;
            _startZoom = side.logoZoom;
          },
          onScaleUpdate: (d) {
            if (!side.hasTop) return;
            final last = _lastFocal;
            _lastFocal = d.localFocalPoint;
            if (last == null) return;
            final delta = d.localFocalPoint - last;
            setState(() {
              if (d.pointerCount >= 2) {
                side.logoZoom = (_startZoom * d.scale).clamp(0.3, 3.0);
              }
              side.logoDx = (side.logoDx + delta.dx / bw).clamp(-0.6, 0.6);
              side.logoDy = (side.logoDy + delta.dy / bh).clamp(-0.6, 0.6);
            });
          },
          onScaleEnd: (_) {
            _lastFocal = null;
            _changed();
          },
          child: content,
        ),
      ),
    );
  }

  Future<void> _logosMenu() async {
    final i = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Über den Fotos (Logo, Bild oder Text)',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ),
            ),
            for (final i in [0, 1])
              ListTile(
                leading: _design.side(i).logo == null
                    ? Icon(
                        _design.side(i).logoText != null
                            ? Icons.text_fields
                            : Icons.add_photo_alternate_outlined,
                      )
                    : SizedBox(
                        width: 40,
                        height: 40,
                        child: Image.memory(
                          _bytesOf(_design.side(i).logo)!,
                          fit: BoxFit.contain,
                        ),
                      ),
                title: Text('Über dem Foto ${_sideName(i)}'),
                onTap: () => Navigator.pop(ctx, i),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (i != null && mounted) await _logoMenu(i);
  }

  List<(String, Color)> get _palette => [
    ('Weiß', Colors.white),
    ('Gold', const Color(0xFFD4AF37)),
    ('Vereinsfarbe', _clubColor),
    ('Schwarz', Colors.black),
    ('Rot', const Color(0xFFD32F2F)),
  ];

  TextLook get _labelLook => _design.labelLook == null
      ? const TextLook()
      : TextLook.fromJson(_design.labelLook!);

  Future<void> _labelsMenu() async {
    final lc = TextEditingController(text: _design.left.label);
    final rc = TextEditingController(text: _design.right.label);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      barrierColor: Colors.black12,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          void upd(VoidCallback fn) {
            setState(fn);
            setSheet(() {});
            _changed();
          }

          final g = _design.current;
          return SafeArea(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                16,
                0,
                16,
                12 + MediaQuery.of(ctx).viewInsets.bottom,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        'Beschriftung unter den Fotos',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      subtitle: const Text(
                        'Ausschalten, wenn sie schon im Hintergrund steht',
                      ),
                      value: _design.labels,
                      onChanged: (v) => upd(() => _design.labels = v),
                    ),
                    if (_design.labels) ...[
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: lc,
                              maxLines: null,
                              decoration: const InputDecoration(
                                labelText: 'Links',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              onChanged: (v) =>
                                  upd(() => _design.left.label = v),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              controller: rc,
                              maxLines: null,
                              decoration: const InputDecoration(
                                labelText: 'Rechts',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              onChanged: (v) =>
                                  upd(() => _design.right.label = v),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      _slider(
                        'Größe',
                        _design.labelSize,
                        0.4,
                        2.0,
                        (v) => upd(() => _design.labelSize = v),
                        percent: true,
                      ),
                      _slider(
                        'Abstand',
                        g.labelGap,
                        0,
                        0.12,
                        (v) => upd(() => g.labelGap = v),
                      ),
                      const SizedBox(height: 4),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.text_format),
                        label: const Text(
                          'Schrift, Farbe, Schatten, Ausrichtung',
                        ),
                        onPressed: () => showTextLookSheet(
                          context,
                          title: 'Beschriftung',
                          initial: _labelLook,
                          palette: _palette,
                          onChanged: (l) {
                            setState(
                              () => _design.labelLook = l.isDefault
                                  ? null
                                  : l.toJson(),
                            );
                            _changed();
                          },
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _slider(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged, {
    bool percent = false,
  }) => Row(
    children: [
      SizedBox(
        width: 96,
        child: Text(label, style: const TextStyle(fontSize: 13)),
      ),
      Expanded(
        child: Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          onChanged: onChanged,
        ),
      ),
      SizedBox(
        width: 44,
        child: Text(
          percent
              ? '${(value * 100).round()}%'
              : (value * 100).toStringAsFixed(1),
          textAlign: TextAlign.right,
          style: const TextStyle(fontSize: 12),
        ),
      ),
    ],
  );

  Future<void> _frameMenu() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      barrierColor: Colors.black12,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.5,
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          void upd(VoidCallback fn) {
            setState(fn);
            setSheet(() {});
            _changed();
          }

          final g = _design.current;
          final colors = <(String, Color)>[
            ('Weiß', Colors.white),
            ('Gold', const Color(0xFFD4AF37)),
            ('Vereinsfarbe', _clubColor),
            ('Schwarz', Colors.black),
          ];
          String hexOf(Color c) =>
              '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
          return SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              shrinkWrap: true,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'Rahmen um die Fotos',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: const Text(
                    'Ausschalten, wenn er schon im Hintergrund steckt',
                  ),
                  value: _design.frames,
                  onChanged: (v) => upd(() => _design.frames = v),
                ),
                if (_design.frames) ...[
                  Wrap(
                    spacing: 10,
                    children: [
                      for (final (name, c) in colors)
                        Tooltip(
                          message: name,
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: () =>
                                upd(() => _design.frameColor = hexOf(c)),
                            child: Container(
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(
                                color: c,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color:
                                      _design.frameColor.toUpperCase() ==
                                          hexOf(c)
                                      ? Theme.of(ctx).colorScheme.primary
                                      : Colors.grey,
                                  width:
                                      _design.frameColor.toUpperCase() ==
                                          hexOf(c)
                                      ? 3
                                      : 1,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  _slider(
                    'Stärke',
                    _design.frameWidth / 6,
                    0.05,
                    1,
                    (v) => upd(() => _design.frameWidth = v * 6),
                    percent: true,
                  ),
                ],
                const Divider(height: 20),
                Text(
                  'Lage der Fotos (${compareFormatLabel(_design.format)})',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                _slider('Oben', g.top, 0, 0.6, (v) => upd(() => g.top = v)),
                _slider(
                  'Höhe',
                  g.height,
                  0.2,
                  0.95,
                  (v) => upd(() => g.height = v),
                ),
                _slider(
                  'Rand außen',
                  g.margin,
                  0,
                  0.2,
                  (v) => upd(() {
                    g.clearExact();
                    g.margin = v;
                  }),
                ),
                _slider(
                  'Abstand Mitte',
                  g.gap,
                  0,
                  0.2,
                  (v) => upd(() {
                    g.clearExact();
                    g.gap = v;
                  }),
                ),
                _slider(
                  'Bild oben',
                  g.logoHeight,
                  0,
                  0.35,
                  (v) => upd(() => g.logoHeight = v),
                ),
                Wrap(
                  spacing: 4,
                  children: [
                    if (_design.backgrounds[_design.format] != null)
                      TextButton.icon(
                        icon: const Icon(Icons.auto_fix_high),
                        label: const Text('Felder im Bild erkennen'),
                        onPressed: () {
                          Navigator.pop(ctx);
                          _detectFrames([_design.format], manual: true);
                        },
                      ),
                    TextButton.icon(
                      icon: const Icon(Icons.restart_alt),
                      label: const Text('Lage zurücksetzen'),
                      onPressed: () => upd(
                        () => _design.geom[_design.format] =
                            CompareGeom.defaults(_design.format),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _rename() async {
    final ctrl = TextEditingController(text: _title);
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
    setState(() => _title = t.trim());
    _changed();
  }

  // --------------------------------------------------------------- Export

  Future<Uint8List?> _capturePng() async {
    setState(() => _exporting = true);
    try {
      await WidgetsBinding.instance.endOfFrame;
      final boundary =
          _boundaryKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) return null;
      final image = await boundary.toImage(pixelRatio: _kExportWidth / _kW);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _share() async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final bytes = await _capturePng();
      if (bytes == null) return;
      final path = await shareOrSaveImage(
        bytes,
        'Vergleich_$_title',
        text: _title,
      );
      if (path != null) {
        messenger.showSnackBar(
          SnackBar(
            content: Text('Als Bild gespeichert und geöffnet:\n$path'),
            duration: const Duration(seconds: 6),
          ),
        );
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Teilen fehlgeschlagen: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveImage() async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final bytes = await _capturePng();
      if (bytes == null) return;
      final path = await saveImage(bytes, 'Vergleich_$_title');
      messenger.showSnackBar(
        SnackBar(
          content: Text('Gespeichert:\n$path'),
          duration: const Duration(seconds: 6),
        ),
      );
      try {
        await OpenFilex.open(path);
      } catch (_) {}
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Speichern fehlgeschlagen: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ----------------------------------------------------------------- Grafik

  void _onScale(int i, ScaleUpdateDetails d, double fw, double fh) {
    final side = _design.side(i);
    final size = _sizeOf(side.photo);
    final last = _lastFocal;
    _lastFocal = d.localFocalPoint;
    if (size == null || last == null) return;
    if (d.pointerCount >= 2) {
      side.zoom = (_startZoom * d.scale).clamp(0.3, 5.0);
    }
    _pan(side, d.localFocalPoint - last, fw, fh, size);
  }

  void _pan(CompareSide side, Offset delta, double fw, double fh, Size size) {
    final r = compareCoverRect(
      fw: fw,
      fh: fh,
      iw: size.width,
      ih: size.height,
      zoom: side.zoom,
    );
    final ox = (r.$3 - fw) / 2;
    final oy = (r.$4 - fh) / 2;
    setState(() {
      // ox/oy < 0: Bild kleiner als der Rahmen → innerhalb verschieben.
      side.dx = ox.abs() > 0.5 ? (side.dx - delta.dx / ox).clamp(-1.0, 1.0) : 0;
      side.dy = oy.abs() > 0.5 ? (side.dy - delta.dy / oy).clamp(-1.0, 1.0) : 0;
    });
  }

  Widget _photo(int i, double fw, double fh) {
    final side = _design.side(i);
    final bytes = _bytesOf(side.photo);
    if (bytes == null) {
      if (_exporting) return const SizedBox.expand();
      return Container(
        color: Colors.white.withValues(alpha: 0.06),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.add_photo_alternate_outlined,
              color: Colors.white70,
              size: 34,
            ),
            const SizedBox(height: 6),
            Text(
              'Foto ${_sideName(i)}\nwählen',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ],
        ),
      );
    }
    final size = _sizeOf(side.photo);
    if (size == null) {
      return Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true);
    }
    final r = compareCoverRect(
      fw: fw,
      fh: fh,
      iw: size.width,
      ih: size.height,
      zoom: side.zoom,
      dx: side.dx,
      dy: side.dy,
    );
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: r.$1,
          top: r.$2,
          width: r.$3,
          height: r.$4,
          child: Image.memory(
            bytes,
            fit: BoxFit.fill,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
          ),
        ),
      ],
    );
  }

  TextStyle get _labelStyle {
    final look = _labelLook;
    var base = TextStyle(
      color: Colors.white,
      fontSize: _kW * 0.085 * _design.labelSize,
      fontWeight: FontWeight.w700,
      height: 1.05,
      shadows: look.shadow == null
          ? textShadowsFor('soft', _kW * 0.085 * _design.labelSize, _clubColor)
          : null,
    );
    if (look.font == null) base = posterFontStyle('barlow', base);
    return look.apply(base, glow: _clubColor);
  }

  Widget _graphic(double W, double H) {
    final g = _design.current;
    final bg = _bytesOf(_design.backgrounds[_design.format]);
    final fh = g.height * H;
    final top = g.top * H;
    final look = _labelLook;
    final labelStyle = _labelStyle;
    final frameColor = _hex(_design.frameColor, Colors.white);
    return SizedBox(
      width: W,
      height: H,
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          Positioned.fill(
            child: bg != null
                ? Image.memory(bg, fit: BoxFit.cover, gaplessPlayback: true)
                : Stack(
                    fit: StackFit.expand,
                    children: [
                      DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: bgGradient(
                            _design.gradShape,
                            _gradTop,
                            _gradBottom,
                          ),
                        ),
                      ),
                      if (_design.pattern)
                        CustomPaint(
                          painter: BgPatternPainter(_design.patternStrength),
                        ),
                    ],
                  ),
          ),
          // Verlauf als Tönung über dem eigenen Bild.
          if (bg != null && _design.tint > 0)
            Positioned.fill(
              child: IgnorePointer(
                child: Opacity(
                  opacity: _design.tint.clamp(0.0, 1.0),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: bgGradient(
                        _design.gradShape,
                        _gradTop,
                        _gradBottom,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          for (final i in [0, 1]) ...[
            // Bild/Text über dem Foto (z. B. Logo).
            ?_topSlot(i, g, W, H, top),
            // Foto im Rahmen.
            Positioned(
              left: g.frameLeft(i) * W,
              top: top,
              width: g.widthOf(i) * W,
              height: fh,
              child: Listener(
                onPointerSignal: (e) {
                  if (e is! PointerScrollEvent) return;
                  final side = _design.side(i);
                  final size = _sizeOf(side.photo);
                  if (size == null) return;
                  side.zoom =
                      (side.zoom * (e.scrollDelta.dy < 0 ? 1.08 : 0.926)).clamp(
                        0.3,
                        5.0,
                      );
                  _pan(side, Offset.zero, g.widthOf(i) * W, fh, size);
                  _changed();
                },
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _sideMenu(i),
                  onScaleStart: (d) {
                    _lastFocal = d.localFocalPoint;
                    _startZoom = _design.side(i).zoom;
                  },
                  onScaleUpdate: (d) => _onScale(i, d, g.widthOf(i) * W, fh),
                  onScaleEnd: (_) {
                    _lastFocal = null;
                    _changed();
                  },
                  child: Container(
                    decoration: _design.frames
                        ? BoxDecoration(
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.55),
                                blurRadius: 14,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          )
                        : null,
                    foregroundDecoration: _design.frames
                        ? BoxDecoration(
                            border: Border.all(
                              color: frameColor,
                              width: _design.frameWidth,
                            ),
                          )
                        : null,
                    child: ClipRect(child: _photo(i, g.widthOf(i) * W, fh)),
                  ),
                ),
              ),
            ),
            // Beschriftung.
            if (_design.labels && _design.side(i).label.trim().isNotEmpty)
              Positioned(
                left: g.frameLeft(i) * W,
                width: g.widthOf(i) * W,
                top: top + fh + g.labelGap * H,
                child: GestureDetector(
                  onTap: _labelsMenu,
                  child: Text(
                    _design.side(i).label,
                    textAlign: look.textAlign(TextAlign.center),
                    softWrap: false,
                    overflow: TextOverflow.visible,
                    style: labelStyle,
                  ),
                ),
              ),
          ],
          // Sponsoren-Leiste (unten, verschieb- und zoombar).
          ?_sponsorBar(W, H),
        ],
      ),
    );
  }

  Widget _tool(IconData icon, String label, VoidCallback onTap) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 2),
    child: InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: _busy ? null : onTap,
      child: SizedBox(
        width: 78,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon),
              const SizedBox(height: 3),
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 2,
                style: const TextStyle(fontSize: 11, height: 1.1),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final aspect = compareAspect(_design.format);
    final h = _kW / aspect;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_title, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(
              tooltip: 'Teilen',
              icon: _busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.share),
              onPressed: _loaded && !_busy ? _share : null,
            ),
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'save') _saveImage();
                if (v == 'rename') _rename();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'save',
                  child: ListTile(
                    leading: Icon(Icons.download),
                    title: Text('Als Bild speichern'),
                  ),
                ),
                PopupMenuItem(
                  value: 'rename',
                  child: ListTile(
                    leading: Icon(Icons.edit),
                    title: Text('Umbenennen'),
                  ),
                ),
              ],
            ),
          ],
        ),
        body: !_loaded
            ? const Center(child: CircularProgressIndicator())
            : SafeArea(
                child: Column(
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Center(
                          child: AspectRatio(
                            aspectRatio: aspect,
                            child: FittedBox(
                              child: RepaintBoundary(
                                key: _boundaryKey,
                                child: _graphic(_kW, h),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: SegmentedButton<String>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(value: 'f', label: Text('4:5')),
                          ButtonSegment(value: 's', label: Text('Story')),
                          ButtonSegment(value: 'p', label: Text('1:1')),
                        ],
                        selected: {_design.format},
                        onSelectionChanged: (s) {
                          setState(() => _design.format = s.first);
                          _changed();
                        },
                      ),
                    ),
                    const SizedBox(height: 4),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Row(
                        children: [
                          _tool(
                            Icons.looks_one_outlined,
                            'Foto links',
                            () => _sideMenu(0),
                          ),
                          _tool(
                            Icons.looks_two_outlined,
                            'Foto rechts',
                            () => _sideMenu(1),
                          ),
                          _tool(
                            Icons.wallpaper,
                            'Hinter-\ngrund',
                            _backgroundMenu,
                          ),
                          _tool(Icons.title, 'Beschrif-\ntung', _labelsMenu),
                          _tool(
                            Icons.crop_square,
                            'Rahmen &\nLage',
                            _frameMenu,
                          ),
                          _tool(
                            Icons.add_photo_alternate_outlined,
                            'Bilder\noben',
                            _logosMenu,
                          ),
                          _tool(
                            Icons.handshake_outlined,
                            'Sponsoren',
                            _sponsorMenu,
                          ),
                          _tool(Icons.compare_arrows, 'Fotos\ntauschen', () {
                            setState(_design.swapSides);
                            _changed();
                          }),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                  ],
                ),
              ),
      ),
    );
  }
}
