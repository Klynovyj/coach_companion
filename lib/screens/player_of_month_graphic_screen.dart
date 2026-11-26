import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../models/editor_helpers.dart';
import '../models/graphic_settings.dart';
import '../models/honor_layout.dart';
import '../models/player.dart';
import '../models/player_stat.dart';
import '../models/sponsor.dart';
import '../services/fupa/fupa_dtos.dart';
import '../services/player_photos.dart';
import '../services/share_service.dart';
import '../state/app_state.dart';
import '../widgets/bg_pattern.dart';
import '../widgets/logo_chip.dart';
import '../widgets/team_logo.dart';
import '../widgets/ai_look.dart';
import '../widgets/text_look.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'photo_crop_screen.dart';

/// Ausgabeformate für den Spieler des Monats.
enum _Fmt { post, story, urkunde }

extension _FmtX on _Fmt {
  String get label => switch (this) {
    _Fmt.post => 'Post 1:1',
    _Fmt.story => 'Story 9:16',
    _Fmt.urkunde => 'Urkunde A4',
  };

  // Logische Zeichengröße (Breite×Höhe) und Export-Zielbreite in Pixeln.
  Size get logical => switch (this) {
    _Fmt.post => const Size(360, 360),
    _Fmt.story => const Size(360, 640),
    _Fmt.urkunde => const Size(420, 594), // A4-Verhältnis 210:297
  };

  double get targetWidth => switch (this) {
    _Fmt.post => 1350, // 1350×1350
    _Fmt.story => 1350, // 1350×2400
    _Fmt.urkunde => 2480, // ≈2480×3508 (A4 @ 300 dpi)
  };

  String get fileSuffix => switch (this) {
    _Fmt.post => 'Post',
    _Fmt.story => 'Story',
    _Fmt.urkunde => 'Urkunde-A4',
  };
}

const _greenDark = Color(0xFF0E3D28);
const _gold = Color(0xFFC9A24B);
const _ink = Color(0xFF1F2A24);

/// Erzeugt die teilbaren Grafiken zum „Spieler des Monats": moderne
/// Social-Grafik (Instagram Post 1:1 / Story 9:16) und klassische DIN-A4-
/// Urkunde zum Drucken. Enthält Monatsnote, Monats-Ereignisse (live getrackt),
/// FuPa-Saison und die Sponsoren-Leiste. Logo/Titel/Farben sind über „Grafik
/// anpassen" einstellbar (teamweit, dieselben Einstellungen wie die
/// Startelf-Grafik). Export per RepaintBoundary → PNG über das System-Teilen-
/// Menü (Handy, inkl. Instagram) bzw. Download (Desktop).
class PlayerOfMonthGraphicScreen extends StatefulWidget {
  const PlayerOfMonthGraphicScreen({
    super.key,
    required this.player,
    required this.teamName,
    required this.teamLogo,
    this.yearMonth,
    this.avg,
    this.ratedCount = 0,
    this.defaultOccasion = 'Spieler des Monats',
    this.defaultSubtitle,
  });

  final Player player;
  final String teamName;
  final String? teamLogo;

  /// Monat (YYYY-MM) für Monatsdaten/Ø-Note; null = Anlass-Modus ohne Monat.
  final String? yearMonth;
  final double? avg;
  final int ratedCount;

  /// Vorbelegter Anlass-Titel (Eyebrow) und Untertitel.
  final String defaultOccasion;
  final String? defaultSubtitle;

  @override
  State<PlayerOfMonthGraphicScreen> createState() =>
      _PlayerOfMonthGraphicScreenState();
}

class _PlayerOfMonthGraphicScreenState
    extends State<PlayerOfMonthGraphicScreen> {
  final GlobalKey _boundaryKey = GlobalKey();
  _Fmt _fmt = _Fmt.post;
  bool _loading = true;
  bool _sharing = false;

  List<Sponsor> _sponsors = [];
  PlayerMonthStats _month = const PlayerMonthStats();
  PlayerMonthStats _total = const PlayerMonthStats();
  PlayerStat? _fupa;
  FupaClubCareer? _fupaCareer; // FuPa-Laufbahn + aufgelöster Verein
  bool _fupaLoading = true; // Laufbahn wird (nach dem Hauptladen) geholt
  StateSetter? _sheetSetState; // damit das offene Sheet nachladen kann
  GraphicSettings _settings = const GraphicSettings(id: 'local');

  // Anlass (Eyebrow) + Untertitel – editierbar.
  late final String _occasion = widget.defaultOccasion;
  late final String _subtitle =
      widget.defaultSubtitle ?? (widget.yearMonth != null ? _monthLabel : '');

  bool get _hasMonth => widget.yearMonth != null;
  bool get _hasRating => widget.avg != null;

  // Welche Datenquellen auf der Grafik/Urkunde erscheinen (umschaltbar).
  late bool _showRating = _hasRating; // Bewertungen (Ø-Note)
  late bool _showMonth = _hasMonth; // meine Monatsdaten (live getrackt)
  late bool _showTotal = !_hasMonth; // Gesamt (alle getrackten Spiele)
  bool _showFupa = true; // FuPa-Saison
  late bool _showFupaClub = !_hasMonth; // FuPa gesamt (Verein)
  /// Vereins-Gesamtwerte (offizielle Spiele; FuPa führt keine Freundschafts-
  /// spiele in der Laufbahn). Null ohne Daten.
  FupaClubTotal? get _fupaClub {
    final c = _fupaCareer;
    if (c == null) return null;
    final t = c.total();
    final adj = FupaClubTotal(
      clubName: t.clubName,
      seasons: t.seasons,
      matches: math.max(0, t.matches + _adjMatches),
      goals: math.max(0, t.goals + _adjGoals),
      assists: math.max(0, t.assists + _adjAssists),
    );
    return adj.hasAny ? adj : null;
  }

  // ------------------------------------------------ Korrektur (+1/−1) je Spieler
  /// Manuelle Korrektur der FuPa-Vereinswerte (z.B. 99 → 100 Spiele für die
  /// Urkunde zum 100. Spiel). Je Spieler auf dem Gerät gespeichert.
  int _adjMatches = 0;
  int _adjGoals = 0;
  int _adjAssists = 0;
  bool get _hasAdj => _adjMatches != 0 || _adjGoals != 0 || _adjAssists != 0;
  String get _adjPref => 'honor_adj_${widget.player.id}';

  Future<void> _loadAdj() async {
    try {
      final p = await SharedPreferences.getInstance();
      final m = jsonDecode(p.getString(_adjPref) ?? '{}');
      if (m is! Map || !mounted) return;
      setState(() {
        _adjMatches = (m['m'] as num?)?.toInt() ?? 0;
        _adjGoals = (m['g'] as num?)?.toInt() ?? 0;
        _adjAssists = (m['a'] as num?)?.toInt() ?? 0;
      });
      _sheetSetState?.call(() {});
    } catch (_) {}
  }

  Future<void> _saveAdj() async {
    try {
      final p = await SharedPreferences.getInstance();
      if (!_hasAdj) {
        await p.remove(_adjPref);
      } else {
        await p.setString(
          _adjPref,
          jsonEncode({'m': _adjMatches, 'g': _adjGoals, 'a': _adjAssists}),
        );
      }
    } catch (_) {}
  }

  // ------------------------------------------------------ Sponsoren an/aus
  /// Sponsoren-Leiste auf Ehrungs-Grafik/Urkunde (gerätweit gespeichert).
  bool _showSponsors = true;
  static const _sponsorPref = 'honor_show_sponsors';

  Future<void> _loadShowSponsors() async {
    try {
      final p = await SharedPreferences.getInstance();
      final v = p.getBool(_sponsorPref);
      if (v != null && mounted) setState(() => _showSponsors = v);
    } catch (_) {}
  }

  Future<void> _saveShowSponsors() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_sponsorPref, _showSponsors);
    } catch (_) {}
  }

  /// KI-Look (Deko-Ebene) je Format, auf dem Gerät je Spieler gespeichert.
  final Map<_Fmt, AiLookData> _aiLooks = {};
  bool _lookBusy = false;

  Future<File> _lookFile(_Fmt f) async {
    final dir = await getApplicationDocumentsDirectory();
    final safe = widget.player.id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return File('${dir.path}/ai_looks/pom_${safe}_${f.name}.json');
  }

  Future<void> _loadAiLooks() async {
    for (final f in _Fmt.values) {
      try {
        final file = await _lookFile(f);
        if (!file.existsSync()) continue;
        final l = AiLookData.fromJson(jsonDecode(await file.readAsString()));
        if (l != null && mounted) setState(() => _aiLooks[f] = l);
      } catch (_) {}
    }
  }

  Future<void> _saveAiLook(_Fmt f) async {
    try {
      final file = await _lookFile(f);
      final l = _aiLooks[f];
      if (l == null) {
        if (file.existsSync()) await file.delete();
        return;
      }
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(l.toJson()));
    } catch (_) {}
  }

  /// Leinwand je Format (Seitenverhältnis wie die Grafik).
  (int, int, String) get _lookCanvas => switch (_fmt) {
    _Fmt.post => (1024, 1024, '1:1'),
    _Fmt.story => (576, 1024, '9:16'),
    _Fmt.urkunde => (724, 1024, '3:4'),
  };

  Future<void> _createAiLook({
    required String theme,
    required String mode,
  }) async {
    if (_lookBusy) return;
    final fmt = _fmt;
    setState(() => _lookBusy = true);
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(
        content: Text('KI gestaltet den Look …'),
        duration: Duration(seconds: 3),
      ),
    );
    try {
      final (w, h, aspect) = _lookCanvas;
      final png = await generateAiLookPng(
        theme: theme,
        mode: mode,
        width: w,
        height: h,
        aspect: aspect,
        gradTop: _settings.gradTop,
        gradBottom: _settings.gradBottom,
      );
      if (!mounted) return;
      if (png == null) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Die KI hat kein Bild zurückgegeben.')),
        );
        return;
      }
      setState(
        () => _aiLooks[fmt] = AiLookData(
          dataUrl: 'data:image/png;base64,${base64Encode(png)}',
          mode: mode,
          theme: theme,
          opacity: _aiLooks[fmt]?.opacity ?? 1.0,
        ),
      );
      _saveAiLook(fmt);
      _sheetSetState?.call(() {});
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(aiErrorMessage(e)),
          duration: const Duration(seconds: 6),
        ),
      );
    } finally {
      if (mounted) setState(() => _lookBusy = false);
      _sheetSetState?.call(() {});
    }
  }

  Future<void> _openAiLookDialog({AiLookData? current}) async {
    final urkunde = _fmt == _Fmt.urkunde;
    final res = await showAiLookDialog(
      context,
      theme: current?.theme,
      mode: current?.mode ?? 'glow',
      presets: {...kAiLookHonorPresets, ...kAiLookPresets},
      // Auf weißem Papier wäre „Leuchtend" kaum sichtbar.
      fixedMode: urkunde ? 'cutout' : null,
      fixedModeHint: urkunde
          ? 'Urkunde: Darstellung „Freigestellt" (auf weißem Papier sichtbar).'
          : null,
    );
    if (res == null || !mounted) return;
    await _createAiLook(theme: res.theme, mode: res.mode);
  }

  /// Abschnitt „KI-Look" im Menü „Grafik anpassen" (für das aktive Format).
  Widget _aiLookSection(void Function(VoidCallback) setSheet) {
    final look = _aiLooks[_fmt];
    final allowed = context.read<AppState>().canAiImage;
    void upd(VoidCallback fn) {
      setState(fn);
      setSheet(() {});
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            const Icon(Icons.auto_awesome, size: 18),
            const SizedBox(width: 6),
            Text(
              'KI-Look (${_fmt.label})',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          'Deko über der Grafik (z. B. Goldglanz, Konfetti) – Texte, Foto und '
          'Werte bleiben unverändert. Gilt je Format.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 6),
        if (!allowed)
          Text(
            'KI ist für dich nicht freigeschaltet (Einstellungen → '
            'KI-Berechtigungen).',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          )
        else if (look == null)
          OutlinedButton.icon(
            icon: _lookBusy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_awesome, size: 18),
            label: Text(_lookBusy ? 'KI gestaltet …' : 'KI-Look erstellen'),
            onPressed: _lookBusy ? null : () => _openAiLookDialog(),
          )
        else ...[
          Text(
            'Aktiv: ${aiLookName(look.theme, {...kAiLookHonorPresets, ...kAiLookPresets})} · '
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
                  onChangeEnd: (_) => _saveAiLook(_fmt),
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
                icon: _lookBusy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh, size: 18),
                label: const Text('Neu erzeugen'),
                onPressed: _lookBusy
                    ? null
                    : () => _createAiLook(theme: look.theme, mode: look.mode),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.edit, size: 18),
                label: const Text('Ändern'),
                onPressed: _lookBusy
                    ? null
                    : () => _openAiLookDialog(current: look),
              ),
              TextButton.icon(
                icon: const Icon(Icons.delete_outline, color: Colors.red),
                label: const Text(
                  'Entfernen',
                  style: TextStyle(color: Colors.red),
                ),
                onPressed: () {
                  upd(() => _aiLooks.remove(_fmt));
                  _saveAiLook(_fmt);
                },
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// Gestaltung der Texte (Schrift/Farbe/Schatten/Ausrichtung) je Text:
  /// team · occasion · subtitle · honor. Auf dem Gerät gespeichert.
  Map<String, TextLook> _looks = {};
  static const _looksPref = 'pom_text_looks';
  static const _cropPref = 'pom_photo_crop';

  /// Ausschnitt des runden Spielerfotos (Zoom 0.5 … 4, Verschiebung als
  /// Anteil des Durchmessers) – je Spieler gespeichert, gilt in allen Formaten.
  ({double z, double dx, double dy}) _crop = (z: 1.0, dx: 0.0, dy: 0.0);
  double _cropZ0 = 1.0;

  Future<void> _loadCrop() async {
    try {
      final p = await SharedPreferences.getInstance();
      final m = jsonDecode(p.getString(_cropPref) ?? '{}');
      final v = m is Map ? m[widget.player.id] : null;
      if (v is List && v.length == 3 && mounted) {
        setState(
          () => _crop = (
            z: (v[0] as num).toDouble().clamp(0.5, 4.0),
            dx: (v[1] as num).toDouble().clamp(-1.0, 1.0),
            dy: (v[2] as num).toDouble().clamp(-1.0, 1.0),
          ),
        );
      }
    } catch (_) {}
  }

  Future<void> _saveCrop() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = jsonDecode(p.getString(_cropPref) ?? '{}');
      final m = raw is Map
          ? Map<String, Object?>.from(raw)
          : <String, Object?>{};
      m[widget.player.id] = [_crop.z, _crop.dx, _crop.dy];
      await p.setString(_cropPref, jsonEncode(m));
    } catch (_) {}
  }

  void _setCrop({double? z, double? dx, double? dy, bool save = true}) {
    setState(
      () => _crop = (
        z: (z ?? _crop.z).clamp(0.5, 4.0),
        dx: (dx ?? _crop.dx).clamp(-1.0, 1.0),
        dy: (dy ?? _crop.dy).clamp(-1.0, 1.0),
      ),
    );
    if (save) _saveCrop();
  }

  /// Abschnitt „Spielerfoto-Ausschnitt" im Menü „Grafik anpassen".
  Widget _cropSection(void Function(VoidCallback) setSheet) {
    void z(double f) {
      _setCrop(z: _crop.z * f);
      setSheet(() {});
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Spielerfoto-Ausschnitt',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        Text(
          'Im runden Foto ziehen = verschieben, zwei Finger bzw. Mausrad = '
          'zoomen.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        Row(
          children: [
            IconButton(
              tooltip: 'Auszoomen',
              icon: const Icon(Icons.remove_circle_outline),
              onPressed: () => z(1 / 1.1),
            ),
            Expanded(
              child: Slider(
                value: _crop.z,
                min: 0.5,
                max: 4,
                onChanged: (v) {
                  _setCrop(z: v, save: false);
                  setSheet(() {});
                },
                onChangeEnd: (_) => _saveCrop(),
              ),
            ),
            IconButton(
              tooltip: 'Einzoomen',
              icon: const Icon(Icons.add_circle_outline),
              onPressed: () => z(1.1),
            ),
            SizedBox(
              width: 44,
              child: Text(
                '${(_crop.z * 100).round()}%',
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.center_focus_strong),
            label: const Text('Ausschnitt zurücksetzen'),
            onPressed: () {
              _setCrop(z: 1, dx: 0, dy: 0);
              setSheet(() {});
            },
          ),
        ),
      ],
    );
  }

  Future<void> _loadLooks() async {
    try {
      final p = await SharedPreferences.getInstance();
      final m = TextLook.decodeMap(p.getString(_looksPref));
      if (mounted) setState(() => _looks = m);
    } catch (_) {}
  }

  // Spieler (lokal veränderbar – z.B. neues Foto) und editierbarer Text.
  late Player _player = widget.player;

  // Standardtexte mit sinnvollen Umbrüchen (Umbruch nur per Enter).
  String get _defaultHonor => _hasMonth
      ? 'wird für herausragende Leistungen im Monat $_monthLabel\n'
            'zum Spieler des Monats ernannt.'
      : 'wird für seine Verdienste um den Verein geehrt.\n'
            'Herzlichen Glückwunsch und vielen Dank!';

  @override
  void initState() {
    super.initState();
    _load();
    _loadLooks();
    _loadCrop();
    _loadAiLooks();
    _loadAdj();
    _loadShowSponsors();
    _app = context.read<AppState>();
    _hist.reset(_layout.encode());
    _loadLayout();
  }

  @override
  void dispose() {
    _histTimer?.cancel();
    _saveTimer?.cancel();
    if (_layoutDirty) _flushSave();
    super.dispose();
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    final sponsors = await state.sponsors();
    final settings = await state.graphicSettings();
    final month = _hasMonth
        ? await state.playerMonthStats(
            widget.player.teamId,
            widget.yearMonth!,
            widget.player.id,
          )
        : const PlayerMonthStats();
    final total = await state.playerTotalStats(
      widget.player.teamId,
      widget.player.id,
    );
    final fupa = await state.playerSeasonStat(
      widget.player.teamId,
      widget.player.dedupKey,
    );
    if (!mounted) return;
    setState(() {
      _sponsors = sponsors;
      _settings = settings;
      _month = month;
      _total = total;
      _fupa = fupa;
      _loading = false;
    });
    // FuPa-Laufbahn (Netzwerk) im Hintergrund – blockiert die Ansicht nicht.
    _loadFupaClub();
  }

  Future<void> _loadFupaClub() async {
    final state = context.read<AppState>();
    final career = await state.playerFupaClub(
      widget.player.teamId,
      widget.player,
    );
    if (!mounted) return;
    setState(() {
      _fupaCareer = career;
      _fupaLoading = false;
    });
    // Falls das Anpassen-Sheet gerade offen ist: dort ebenfalls aktualisieren.
    _sheetSetState?.call(() {});
  }

  List<Sponsor> get _allBarSponsors =>
      _sponsors.where((s) => s.logo != null).toList();
  List<Sponsor> get _barSponsors =>
      _showSponsors ? _allBarSponsors : const <Sponsor>[];

  // Effektive Anzeige-Werte (Einstellung überschreibt die Defaults).
  String get _title =>
      (_settings.title != null && _settings.title!.trim().isNotEmpty)
      ? _settings.title!.trim()
      : widget.teamName;
  String? get _logo => _settings.logo ?? widget.teamLogo;

  String get _monthLabel {
    final ym = widget.yearMonth;
    if (ym == null) return '';
    final y = int.tryParse(ym.substring(0, 4)) ?? 2000;
    final m = int.tryParse(ym.substring(5, 7)) ?? 1;
    return DateFormat('MMMM yyyy', 'de_DE').format(DateTime(y, m));
  }

  Future<String?> _pickImage({required bool asBackground}) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final file = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: asBackground ? 1080 : 600,
        maxHeight: asBackground ? 1920 : 600,
        imageQuality: asBackground ? 75 : 90,
      );
      if (file == null) return null;
      final bytes = await file.readAsBytes();
      final mime = asBackground ? 'image/jpeg' : 'image/png';
      return 'data:$mime;base64,${base64Encode(bytes)}';
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Bild konnte nicht geladen werden: $e')),
      );
      return null;
    }
  }

  static const _occasionPresets = <String>[
    'Spieler des Monats',
    'Jubiläum',
    'Meilenstein',
    '100. Spiel für den Verein',
    'Torschützenkönig',
    'Danke!',
  ];

  Future<void> _openCustomize() async {
    final titleCtrl = TextEditingController(text: _settings.title ?? '');
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          _sheetSetState = setSheet;
          void apply(GraphicSettings s) {
            setState(() => _settings = s); // Live-Vorschau hinter dem Sheet
            setSheet(() {});
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
                  const SizedBox(height: 6),
                  Text(
                    'Logo, Titel und Farben gelten teamweit (wie bei der '
                    'Startelf-Grafik). Der Urkunden-Look bleibt klassisch.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  Card(
                    margin: EdgeInsets.zero,
                    child: ListTile(
                      leading: const Icon(Icons.edit_outlined),
                      title: const Text('Texte & Elemente bearbeiten'),
                      subtitle: const Text(
                        'Titel, Untertitel, Urkunden-Text und alle anderen '
                        'Texte direkt auf der Grafik antippen (Stift oben '
                        'rechts). Zeilenumbruch nur mit Enter.',
                      ),
                      onTap: () {
                        Navigator.pop(ctx);
                        if (!_editing) _toggleEdit();
                      },
                    ),
                  ),
                  const Divider(height: 28),
                  _cropSection(setSheet),
                  const Divider(height: 28),
                  _aiLookSection(setSheet),
                  const Divider(height: 28),
                  // Live-Vorschau des Verlaufs (Post/Story-Hintergrund).
                  Container(
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          _hex(_settings.gradTop),
                          _hex(_settings.gradBottom),
                        ],
                      ),
                    ),
                    child: const Text(
                      'Verlauf-Vorschau',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
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
                  _rowWithImage(
                    label: 'Logo',
                    preview: _logo,
                    onPick: () async {
                      final url = await _pickImage(asBackground: false);
                      if (url != null) apply(_settings.copyWith(logo: url));
                    },
                    onClear: _settings.logo == null
                        ? null
                        : () => apply(_settings.copyWith(clearLogo: true)),
                    clearLabel: 'Team-Logo',
                  ),
                  const SizedBox(height: 12),
                  _rowWithImage(
                    label: 'Hintergrundbild (nur Post/Story)',
                    preview: _settings.bgImage,
                    onPick: () async {
                      final url = await _pickImage(asBackground: true);
                      if (url != null) apply(_settings.copyWith(bgImage: url));
                    },
                    onClear: _settings.bgImage == null
                        ? null
                        : () => apply(_settings.copyWith(clearBgImage: true)),
                    clearLabel: 'Entfernen',
                  ),
                  const SizedBox(height: 8),
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
                  const Text('Verlaufsfarbe oben (Post/Story)'),
                  const SizedBox(height: 6),
                  _swatches(
                    selected: _settings.gradTop,
                    onPick: (hex) => apply(_settings.copyWith(gradTop: hex)),
                  ),
                  const SizedBox(height: 12),
                  const Text('Verlaufsfarbe unten (Post/Story)'),
                  const SizedBox(height: 6),
                  _swatches(
                    selected: _settings.gradBottom,
                    onPick: (hex) => apply(_settings.copyWith(gradBottom: hex)),
                  ),
                  const SizedBox(height: 16),
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
                            _settings.copyWith(gradTop: p.$2, gradBottom: p.$3),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // Verlaufsform + Splitter-Muster (teamweit, Post/Story).
                  BgStyleControls(
                    shape: _settings.gradShape,
                    pattern: _settings.bgPattern,
                    onShape: (v) => apply(
                      _settings.copyWith(
                        gradShape: v,
                        clearGradShape: v == null,
                      ),
                    ),
                    onPattern: (v) => apply(_settings.copyWith(bgPattern: v)),
                  ),
                  const SizedBox(height: 8),
                  const Divider(),
                  const Text(
                    'Daten anzeigen',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  if (_hasRating)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Bewertungen (Ø-Note)'),
                      subtitle: const Text('Durchschnittsnote des Monats'),
                      value: _showRating,
                      onChanged: (v) {
                        setState(() => _showRating = v);
                        setSheet(() {});
                      },
                    ),
                  if (_hasMonth)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Meine Daten (Monat, live)'),
                      subtitle: const Text(
                        'Tore/Vorlagen/Karten aus getrackten Spielen des Monats',
                      ),
                      value: _showMonth,
                      onChanged: (v) {
                        setState(() => _showMonth = v);
                        setSheet(() {});
                      },
                    ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Gesamt (alle getrackten Spiele)'),
                    subtitle: const Text(
                      'Summe über alle live getrackten Spiele',
                    ),
                    value: _showTotal,
                    onChanged: (v) {
                      setState(() => _showTotal = v);
                      setSheet(() {});
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('FuPa-Daten (Saison)'),
                    subtitle: const Text('Spiele/Tore/Vorlagen/Minuten/Top11'),
                    value: _showFupa,
                    onChanged: (v) {
                      setState(() => _showFupa = v);
                      setSheet(() {});
                    },
                  ),
                  // FuPa gesamt (Verein) – immer sichtbar, mit Lade-/Leer-Zustand.
                  if (_fupaLoading)
                    const ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('FuPa gesamt (Verein)'),
                      subtitle: Text('FuPa-Laufbahn wird geladen …'),
                      trailing: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  else if (_fupaCareer != null)
                    Builder(
                      builder: (_) {
                        final raw = _fupaCareer!.total();
                        final club = _fupaClub ?? raw;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                'FuPa gesamt (${raw.clubName.isEmpty ? 'Verein' : raw.clubName})',
                              ),
                              subtitle: Text(
                                'Beim Verein: '
                                '${club.matches} Spiele, ${club.goals} Tore, '
                                '${club.assists} Vorlagen'
                                '${_hasAdj ? ' (korrigiert)' : ''}',
                              ),
                              value: _showFupaClub,
                              onChanged: (v) {
                                setState(() => _showFupaClub = v);
                                setSheet(() {});
                              },
                            ),
                            if (_showFupaClub) _adjEditor(raw, club, setSheet),
                          ],
                        );
                      },
                    )
                  else
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      enabled: false,
                      title: const Text('FuPa gesamt (Verein)'),
                      subtitle: Text(
                        (widget.player.externalId ?? '').trim().isEmpty
                            ? 'Spieler ist nicht mit FuPa verknüpft.'
                            : 'Keine FuPa-Laufbahndaten gefunden.',
                      ),
                    ),
                  if (_allBarSponsors.isNotEmpty) ...[
                    const Divider(height: 24),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      secondary: const Icon(Icons.handshake_outlined),
                      title: const Text('Sponsoren anzeigen'),
                      subtitle: const Text(
                        'Logo-Leiste auf Grafik und Urkunde',
                      ),
                      value: _showSponsors,
                      onChanged: (v) {
                        setState(() => _showSponsors = v);
                        setSheet(() {});
                        _saveShowSponsors();
                      },
                    ),
                  ],
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
    _sheetSetState = null;
    if (!mounted) return;
    final state = context.read<AppState>();
    await state.saveGraphicSettings(_settings);
    await state.pushGraphicSettingsToCloud();
  }

  /// +1/−1-Korrektur der Vereinswerte (Spiele/Tore/Vorlagen) im Sheet.
  Widget _adjEditor(
    FupaClubTotal raw,
    FupaClubTotal club,
    void Function(VoidCallback) setSheet,
  ) {
    final scheme = Theme.of(context).colorScheme;
    void change(VoidCallback fn) {
      setState(fn);
      setSheet(() {});
      _saveAdj();
    }

    Widget row(
      String label,
      int fupa,
      int shown,
      int adj,
      void Function(int d) onDelta,
    ) {
      final hint = adj == 0
          ? 'FuPa $fupa'
          : 'FuPa $fupa · ${adj > 0 ? '+' : ''}$adj';
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            SizedBox(width: 78, child: Text(label)),
            IconButton.filledTonal(
              tooltip: '$label −1',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.remove),
              onPressed: shown > 0 ? () => change(() => onDelta(-1)) : null,
            ),
            SizedBox(
              width: 44,
              child: Text(
                '$shown',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
            IconButton.filledTonal(
              tooltip: '$label +1',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.add),
              onPressed: () => change(() => onDelta(1)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                hint,
                style: TextStyle(
                  fontSize: 12,
                  color: adj == 0 ? scheme.onSurfaceVariant : scheme.primary,
                  fontWeight: adj == 0 ? FontWeight.normal : FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Werte anpassen (z. B. 100. Spiel)',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 4),
          row('Spiele', raw.matches, club.matches, _adjMatches, (d) {
            _adjMatches = math.max(-raw.matches, _adjMatches + d);
          }),
          row('Tore', raw.goals, club.goals, _adjGoals, (d) {
            _adjGoals = math.max(-raw.goals, _adjGoals + d);
          }),
          row('Vorlagen', raw.assists, club.assists, _adjAssists, (d) {
            _adjAssists = math.max(-raw.assists, _adjAssists + d);
          }),
          const SizedBox(height: 4),
          Text(
            'Korrektur bleibt beim Spieler gespeichert. Sobald FuPa '
            'nachzieht, wieder auf 0 setzen.',
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
          if (_hasAdj)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => change(() {
                  _adjMatches = 0;
                  _adjGoals = 0;
                  _adjAssists = 0;
                }),
                icon: const Icon(Icons.restart_alt, size: 18),
                label: const Text('Korrektur zurücksetzen'),
              ),
            ),
        ],
      ),
    );
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
  }) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final hex in _palette)
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

  Future<void> _share() async {
    if (_sharing) return;
    setState(() {
      _sharing = true;
      // Auswahlrahmen, Hilfslinien und halbtransparente (ausgeblendete)
      // Elemente gehören nicht ins Bild.
      _capturing = true;
      _guides = const [];
    });
    final messenger = ScaffoldMessenger.of(context);
    unawaited(_flushSave());
    try {
      await WidgetsBinding.instance.endOfFrame;
      final boundary =
          _boundaryKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) return;
      final image = await boundary.toImage(
        pixelRatio: _fmt.targetWidth / _fmt.logical.width,
      );
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return;
      final safeName = _player.fullName.replaceAll(' ', '-');
      final title = (_layout.texts['occasion'] ?? _occasion)
          .replaceAll('\n', ' ')
          .trim();
      final savedPath = await shareOrSaveImage(
        data.buffer.asUint8List(),
        _hasMonth
            ? 'SpielerDesMonats_${safeName}_${widget.yearMonth}_${_fmt.fileSuffix}'
            : 'Ehrung_${safeName}_${_fmt.fileSuffix}',
        text: _hasMonth
            ? 'Spieler des Monats $_monthLabel – ${_player.fullName}'
            : '$title – ${_player.fullName}',
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
      if (mounted) {
        setState(() {
          _sharing = false;
          _capturing = false;
        });
      }
    }
  }

  /// Lädt ein Spielerfoto (Galerie oder Kamera), schneidet es quadratisch zu und
  /// speichert es als eigenes Foto (hohe Auflösung), teamweit/cloud-synchron.
  Future<void> _changePhoto() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Aus Galerie wählen'),
              onTap: () => Navigator.pop(ctx, 'gallery'),
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('Foto aufnehmen'),
              onTap: () => Navigator.pop(ctx, 'camera'),
            ),
            if (_player.hasCustomPhoto)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title: const Text('Eigenes Foto entfernen'),
                onTap: () => Navigator.pop(ctx, 'remove'),
              ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (choice == 'remove') {
      final updated = _player.copyWith(
        clearCustomPhoto: true,
        useCustomPhoto: false,
      );
      await context.read<AppState>().updatePlayer(updated);
      if (mounted) setState(() => _player = updated);
      return;
    }
    try {
      final file = await ImagePicker().pickImage(
        source: choice == 'camera' ? ImageSource.camera : ImageSource.gallery,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 92,
      );
      if (file == null) return;
      final raw = await file.readAsBytes();
      if (!mounted) return;
      final cropped = await Navigator.of(context).push<Uint8List>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => PhotoCropScreen(imageBytes: raw),
        ),
      );
      if (cropped == null || !mounted) return;
      final dataUrl = _encodeSquareJpeg(cropped);
      final updated = _player.copyWith(
        customPhoto: dataUrl,
        useCustomPhoto: true,
      );
      await context.read<AppState>().updatePlayer(updated);
      if (mounted) setState(() => _player = updated);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Foto konnte nicht geladen werden: $e')),
      );
    }
  }

  /// Quadratisches Foto auf max. 1024 px (hohe Auflösung) als JPEG-Data-URL.
  String _encodeSquareJpeg(Uint8List input) {
    final decoded = img.decodeImage(input);
    if (decoded == null) {
      return 'data:image/jpeg;base64,${base64Encode(input)}';
    }
    final sized = decoded.width > 1024
        ? img.copyResize(decoded, width: 1024, height: 1024)
        : decoded;
    final jpg = img.encodeJpg(sized, quality: 90);
    return 'data:image/jpeg;base64,${base64Encode(jpg)}';
  }

  // ================================================ Freie Bearbeitung
  // Bedienung wie im Designer: Element antippen = auswählen, ziehen =
  // verschieben, zwei Finger / Mausrad = Größe + Drehung. Texte gelten für
  // alle Formate, Position/Größe/Stil je Format. Je Spieler gespeichert
  // (Cloud-synchron), optional als Vorlage für alle.
  late final AppState _app;
  HonorLayout _layout = HonorLayout();
  int _rev = 0; // Layout geändert → Grafik neu zeichnen
  int _fieldRev = 0; // Textfelder neu befüllen (Laden/Rückgängig/Vorlage)
  bool _editing = false;
  bool _capturing = false; // Export läuft → Bearbeiten-Optik aus
  String? _selected;
  bool _cropMode = false; // Foto: Ausschnitt im Ring statt Element bewegen
  bool _layoutDirty = false;
  final DesignHistory _hist = DesignHistory();
  Timer? _saveTimer;
  Timer? _histTimer;
  final GlobalKey _canvasKey = GlobalKey();
  List<({bool vertical, double at})> _guides = const [];
  String? _gId;
  Offset _gRaw = Offset.zero;
  double _gScale0 = 1;
  double _gRot0 = 0;
  Offset? _gLast;

  HonorFormatLayout get _fl => _layout.format(_fmt.name);

  static const _textIds = {
    'team',
    'occasion',
    'ulabel',
    'subtitle',
    'name',
    'honor',
    'number',
    'legend',
  };
  static const _elNames = {
    'bar': 'Goldbalken',
    'team': 'Verein',
    'occasion': 'Titel (Anlass)',
    'ulabel': 'Urkunden-Zeile',
    'subtitle': 'Untertitel',
    'photo': 'Spielerfoto',
    'name': 'Name',
    'honor': 'Urkunden-Text',
    'number': 'Nummer · Position',
    'rating': 'Bewertung',
    'stats': 'Statistik',
    'legend': 'Legende',
    'sponsors': 'Sponsoren',
  };

  String _elName(String id) =>
      id.startsWith('free:') ? 'Eigener Text' : (_elNames[id] ?? id);

  HonorFreeText? _freeOf(String id) {
    for (final f in _fl.free) {
      if (f.itemId == id) return f;
    }
    return null;
  }

  bool _exists(String id) => !id.startsWith('free:') || _freeOf(id) != null;

  _Stats get _stats => _Stats(
    month: _month,
    total: _total,
    fupa: _fupa,
    club: _fupaClub,
    showMonth: _showMonth,
    showTotal: _showTotal,
    showFupa: _showFupa,
    showClub: _showFupaClub,
  );

  /// Standardtexte der Elemente (ohne Änderung des Nutzers).
  Map<String, String> get _defaultTexts {
    final p = _player;
    final sub = _subtitle.trim();
    return {
      'team': _title.toUpperCase(),
      'occasion': _occasion.toUpperCase(),
      'subtitle': sub.toUpperCase(),
      'ulabel': sub.isEmpty ? 'URKUNDE' : 'URKUNDE · ${sub.toUpperCase()}',
      'name': _fmt == _Fmt.urkunde ? p.fullName : p.fullName.toUpperCase(),
      'honor': _defaultHonor,
      'number': [
        if (p.number != null) '#${p.number}',
        if ((p.position ?? '').isNotEmpty) p.position!,
      ].join('  ·  ').toUpperCase(),
      'legend': _stats.socialLegend(),
      'sponsorsTitle': 'MIT FREUNDLICHER UNTERSTÜTZUNG',
    };
  }

  /// Stil eines Elements; Rückfall auf die bisherigen gerätweiten Looks.
  TextLook _lookOf(String id) =>
      _fl.item(id).look ??
      _looks[id == 'ulabel' ? 'subtitle' : id] ??
      const TextLook();

  // ------------------------------------------------ Laden / Speichern
  Future<void> _loadLayout() async {
    final id = HonorLayout.playerRowId(widget.player.id);
    Future<String?> read() async =>
        await _app.loadAnnouncementDesign(id) ??
        await _app.loadAnnouncementDesign(HonorLayout.templateRowId);
    try {
      final local = await read();
      if (!mounted) return;
      if (local != null) _applyLayout(HonorLayout.decode(local), reset: true);
      // Neuere Version eines anderen Geräts holen.
      await _app.refreshAnnouncementDesign(id);
      await _app.refreshAnnouncementDesign(HonorLayout.templateRowId);
      final fresh = await read();
      if (!mounted || _layoutDirty) return;
      if (fresh != null && fresh != local) {
        _applyLayout(HonorLayout.decode(fresh), reset: true);
      }
    } catch (_) {
      // Offline/Tabelle fehlt – Standard-Layout bleibt.
    }
  }

  void _applyLayout(HonorLayout l, {bool reset = false}) {
    setState(() {
      _layout = l;
      _rev++;
      _fieldRev++;
      if (_selected != null && !_exists(_selected!)) _selected = null;
    });
    if (reset) _hist.reset(l.encode());
    _resolvePhoto();
  }

  /// Nach jeder Änderung: Verlaufsschritt (gebündelt) + verzögert speichern.
  void _changed() {
    _layoutDirty = true;
    _histTimer?.cancel();
    _histTimer = Timer(const Duration(milliseconds: 400), _recordHist);
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), _flushSave);
  }

  void _recordHist() {
    _histTimer?.cancel();
    _histTimer = null;
    if (_hist.record(_layout.encode()) && mounted) setState(() {});
  }

  Future<void> _flushSave() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (!_layoutDirty) return;
    _layoutDirty = false;
    try {
      await _app.saveAnnouncementDesign(
        HonorLayout.playerRowId(widget.player.id),
        null,
        _layout.encode(),
        title: 'Ehrung ${widget.player.fullName}',
        kind: HonorLayout.kindPlayer,
      );
    } catch (_) {
      _layoutDirty = true; // nächster Versuch beim nächsten Speichern
    }
  }

  void _undoRedo(bool undo) {
    if (_histTimer != null) _recordHist();
    final st = undo ? _hist.undo() : _hist.redo();
    if (st == null) return;
    _applyLayout(HonorLayout.decode(st));
    _layoutDirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), _flushSave);
  }

  // ------------------------------------------------ Änderungen
  void _edit(
    String id,
    HonorElementEdit Function(HonorElementEdit e) fn, {
    bool commit = true,
  }) {
    setState(() {
      _fl.setItem(id, fn(_fl.item(id)));
      _rev++;
    });
    if (commit) _changed();
  }

  void _setText(String id, String v, String def) {
    setState(() {
      if (v == def) {
        _layout.texts.remove(id);
      } else {
        _layout.texts[id] = v;
      }
      _rev++;
    });
    _changed();
  }

  void _select(String? id) {
    if (_selected == id) return;
    setState(() {
      _selected = id;
      _cropMode = false;
    });
  }

  void _toggleEdit() {
    setState(() {
      _editing = !_editing;
      _selected = null;
      _cropMode = false;
      _guides = const [];
    });
    if (!_editing) _flushSave();
  }

  // ------------------------------------------------ Gesten
  void _gStart(String id, ScaleStartDetails d, BuildContext ctx) {
    _select(id);
    final e = _fl.item(id);
    _gId = id;
    _gRaw = e.off;
    _gScale0 = e.scale;
    _gRot0 = e.rot;
    _gLast = d.focalPoint;
  }

  void _gUpdate(String id, ScaleUpdateDetails d, BuildContext ctx) {
    if (_gId != id) return;
    final rb = ctx.findRenderObject();
    if (rb is! RenderBox || !rb.attached || !rb.hasSize) return;
    // rb = äußerste Transform-Box: ihr Koordinatensystem ist das des
    // Eltern-Layouts (alle FittedBox-Skalierungen sind herausgerechnet).
    final last = _gLast ?? d.focalPoint;
    _gRaw += rb.globalToLocal(d.focalPoint) - rb.globalToLocal(last);
    _gLast = d.focalPoint;
    var e = _fl.item(id).copyWith(off: _gRaw);
    if (d.pointerCount >= 2) {
      e = e.copyWith(scale: _gScale0 * d.scale, rot: _gRot0 + d.rotation);
      _guides = const [];
    } else {
      e = _snap(rb, e);
    }
    setState(() {
      _fl.setItem(id, e);
      _rev++;
    });
  }

  void _gEnd(String id) {
    if (_gId != id) return;
    _gId = null;
    _gLast = null;
    setState(() => _guides = const []);
    _changed();
  }

  void _wheel(String id, double dy) {
    _select(id);
    _edit(id, (e) => e.copyWith(scale: e.scale * (dy < 0 ? 1.06 : 1 / 1.06)));
  }

  /// Einrasten an Mitte und 16-px-Rändern der Grafik (Hilfslinien).
  HonorElementEdit _snap(RenderBox rb, HonorElementEdit e) {
    final canvas = _canvasKey.currentContext?.findRenderObject();
    if (canvas is! RenderBox || !canvas.attached) {
      _guides = const [];
      return e;
    }
    Offset toC(Offset q) => canvas.globalToLocal(rb.localToGlobal(q));
    final o = toC(Offset.zero);
    final ratio = (toC(const Offset(1, 0)) - o).distance;
    if (ratio <= 0) return e;
    final c = toC(rb.size.center(Offset.zero)) + e.off * ratio;
    final w = _fmt.logical.width;
    final h = _fmt.logical.height;
    final sx = snapAxis(
      center: c.dx,
      half: rb.size.width * ratio * e.scale / 2,
      centerLines: [w / 2],
      edgeLines: [16, w - 16],
    );
    final sy = snapAxis(
      center: c.dy,
      half: rb.size.height * ratio * e.scale / 2,
      centerLines: [h / 2],
      edgeLines: [16, h - 16],
    );
    _guides = [
      if (sx.line != null) (vertical: true, at: sx.line!),
      if (sy.line != null) (vertical: false, at: sy.line!),
    ];
    return e.copyWith(off: e.off + Offset(sx.offset, sy.offset) / ratio);
  }

  // ------------------------------------------------ Menü
  Future<void> _menu(String v) async {
    switch (v) {
      case 'add':
        _addFree();
      case 'hidden':
        await _showHidden();
      case 'saveTpl':
        await _saveTemplate();
      case 'loadTpl':
        await _loadTemplate();
      case 'reset':
        await _resetFormat();
      case 'resetTexts':
        await _resetTexts();
    }
  }

  void _addFree() {
    final f = HonorFreeText(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      text: 'Neuer Text',
    );
    setState(() {
      _fl.free.add(f);
      _rev++;
      _selected = f.itemId;
      _cropMode = false;
    });
    _changed();
  }

  void _removeFree(HonorFreeText f) {
    setState(() {
      _fl.free.remove(f);
      _fl.items.remove(f.itemId);
      _selected = null;
      _rev++;
    });
    _changed();
  }

  Future<void> _showHidden() async {
    final hidden = [
      for (final e in _fl.items.entries)
        if (e.value.hidden && _exists(e.key)) e.key,
    ];
    if (hidden.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('In diesem Format ist nichts ausgeblendet.'),
        ),
      );
      return;
    }
    final id = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text(
                'Ausgeblendete Elemente',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: Text('Antippen zum Einblenden'),
            ),
            for (final h in hidden)
              ListTile(
                leading: const Icon(Icons.visibility_outlined),
                title: Text(_elName(h)),
                onTap: () => Navigator.pop(ctx, h),
              ),
          ],
        ),
      ),
    );
    if (id == null || !mounted) return;
    _edit(id, (e) => e.copyWith(hidden: false));
    _select(id);
  }

  Future<void> _saveTemplate() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _app.saveAnnouncementDesign(
        HonorLayout.templateRowId,
        null,
        _layout.forTemplate().encode(),
        title: 'Ehrung – Vorlage',
        kind: HonorLayout.kindTemplate,
      );
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Als Vorlage gespeichert. Spieler ohne eigenes Layout starten '
            'damit – Name, Foto und Werte kommen je Spieler.',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Vorlage konnte nicht gespeichert werden: $e')),
      );
    }
  }

  Future<void> _loadTemplate() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _app.refreshAnnouncementDesign(HonorLayout.templateRowId);
    } catch (_) {}
    final raw = await _app.loadAnnouncementDesign(HonorLayout.templateRowId);
    if (!mounted) return;
    if (raw == null) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Noch keine Vorlage – zuerst „Als Vorlage für alle speichern“.',
          ),
        ),
      );
      return;
    }
    final ok = await _confirm(
      'Vorlage laden?',
      'Das Layout dieses Spielers (alle Formate) wird durch die Vorlage '
          'ersetzt. Rückgängig ist möglich.',
    );
    if (!ok) return;
    final t = HonorLayout.decode(raw);
    final name = _layout.texts['name'];
    if (name != null) t.texts['name'] = name;
    _applyLayout(t);
    _changed();
  }

  Future<void> _resetFormat() async {
    final ok = await _confirm(
      'Layout zurücksetzen?',
      '${_fmt.label}: Position, Größe, Drehung, Stil und eigene Texte gehen '
          'zurück auf Standard. Die Texte der Elemente bleiben.',
    );
    if (!ok) return;
    setState(() {
      _layout.formats.remove(_fmt.name);
      _selected = null;
      _rev++;
    });
    _changed();
  }

  Future<void> _resetTexts() async {
    final ok = await _confirm(
      'Alle Texte zurücksetzen?',
      'Alle geänderten Texte (in allen Formaten) gehen zurück auf den '
          'Standard.',
    );
    if (!ok) return;
    setState(() {
      _layout.texts.clear();
      _rev++;
      _fieldRev++;
    });
    _changed();
  }

  Future<bool> _confirm(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('OK'),
            ),
          ],
        ),
      ) ??
      false;

  // ------------------------------------------------ Panel
  Future<void> _styleSheet(String id) => showTextLookSheet(
    context,
    title: 'Text gestalten – ${_elName(id)}',
    initial: _lookOf(id),
    defaultAlign: id == 'team' && _fmt != _Fmt.urkunde
        ? TextAlign.left
        : TextAlign.center,
    palette: [
      ('Weiß', Colors.white),
      ('Gold', _gold),
      ('Schwarz', Colors.black),
      ('Dunkel', _ink),
      ('Vereinsfarbe', _hex(_settings.gradTop)),
      ('Rot', const Color(0xFFD32F2F)),
    ],
    onChanged: (l) => _edit(id, (e) => e.copyWith(look: l)),
  );

  Widget _textField(
    String id,
    String def, {
    String label = 'Text',
    int maxLines = 6,
    String? helper,
  }) {
    final changed = _layout.texts.containsKey(id);
    return TextFormField(
      key: ValueKey('txt:$id:$_fieldRev'),
      initialValue: _layout.texts[id] ?? def,
      minLines: 1,
      maxLines: maxLines,
      keyboardType: TextInputType.multiline,
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        isDense: true,
        border: const OutlineInputBorder(),
        suffixIcon: changed
            ? IconButton(
                tooltip: 'Standardtext',
                icon: const Icon(Icons.restart_alt),
                onPressed: () {
                  setState(() {
                    _layout.texts.remove(id);
                    _rev++;
                    _fieldRev++;
                  });
                  _changed();
                },
              )
            : null,
      ),
      onChanged: (v) => _setText(id, v, def),
    );
  }

  Widget _freeField(HonorFreeText f) => TextFormField(
    key: ValueKey('free:${f.id}:$_fieldRev'),
    initialValue: f.text,
    minLines: 1,
    maxLines: 6,
    keyboardType: TextInputType.multiline,
    decoration: const InputDecoration(
      labelText: 'Text',
      helperText: 'Zeilenumbruch nur mit Enter',
      isDense: true,
      border: OutlineInputBorder(),
    ),
    onChanged: (v) {
      setState(() {
        f.text = v;
        _rev++;
      });
      _changed();
    },
  );

  List<Widget> _statFields() {
    final st = _stats;
    final fields = <(String, String, String)>[];
    if (_fmt == _Fmt.urkunde) {
      final labels = <String>{};
      for (final c in st.urkundeCols()) {
        fields.add(('stat:t:${c.key}', c.title, 'Spaltentitel'));
        labels.addAll(c.rows.map((r) => r.$1));
      }
      for (final l in labels) {
        fields.add(('stat:$l', l, 'Bezeichnung'));
      }
    } else {
      for (final t in st.socialTiles()) {
        fields.add(('stat:${t.$1}', t.$1.toUpperCase(), 'Bezeichnung'));
      }
    }
    return [
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          'Texte der Statistik – die Zahlen kommen aus den Daten '
          '(Korrektur über Grafik anpassen → Daten anzeigen).',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
      for (final f in fields)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _textField(f.$1, f.$2, label: f.$3, maxLines: 2),
        ),
    ];
  }

  Widget _editPanel() {
    final id = _selected!;
    final e = _fl.item(id);
    final free = _freeOf(id);
    final isText = free != null || _textIds.contains(id);
    final defs = _defaultTexts;
    final deg = e.rot * 180 / math.pi;
    return Material(
      elevation: 8,
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.42,
        ),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _elName(id),
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                ),
                if (isText)
                  IconButton(
                    tooltip: 'Schrift, Farbe, Schatten, Ausrichtung',
                    icon: const Icon(Icons.text_format),
                    onPressed: () => _styleSheet(id),
                  ),
                IconButton(
                  tooltip: e.hidden ? 'Einblenden' : 'Ausblenden',
                  icon: Icon(
                    e.hidden
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  onPressed: () =>
                      _edit(id, (x) => x.copyWith(hidden: !x.hidden)),
                ),
                if (free != null)
                  IconButton(
                    tooltip: 'Text löschen',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _removeFree(free),
                  ),
                IconButton(
                  tooltip: 'Fertig',
                  icon: const Icon(Icons.check),
                  onPressed: () => _select(null),
                ),
              ],
            ),
            if (free != null)
              _freeField(free)
            else if (_textIds.contains(id))
              _textField(
                id,
                defs[id] ?? '',
                helper: 'Zeilenumbruch nur mit Enter',
              ),
            if (id == 'occasion') ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final p in _occasionPresets)
                    ActionChip(
                      label: Text(p),
                      onPressed: () {
                        setState(() {
                          _layout.texts['occasion'] = p.toUpperCase();
                          _rev++;
                          _fieldRev++;
                        });
                        _changed();
                      },
                    ),
                ],
              ),
            ],
            if (id == 'stats') ..._statFields(),
            if (id == 'sponsors' && _fmt == _Fmt.urkunde)
              _textField(
                'sponsorsTitle',
                defs['sponsorsTitle']!,
                label: 'Überschrift',
                maxLines: 2,
              ),
            if (id == 'photo') ...[
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      icon: const Icon(Icons.photo_library_outlined),
                      label: const Text('Foto austauschen'),
                      onPressed: _pickHonorPhoto,
                    ),
                  ),
                  if (_layout.photoSlot != null || _layout.photoData != null)
                    TextButton(
                      onPressed: () => _setPhoto(null, null),
                      child: const Text('Profilbild'),
                    ),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('Ausschnitt im Ring anpassen'),
                subtitle: const Text(
                  'An: Ziehen/Zoomen bewegt das Foto im Ring statt das Element',
                ),
                value: _cropMode,
                onChanged: (v) => setState(() => _cropMode = v),
              ),
              if (_cropMode) _cropSection((fn) => setState(fn)),
            ],
            const SizedBox(height: 4),
            Row(
              children: [
                const SizedBox(width: 64, child: Text('Größe')),
                Expanded(
                  child: Slider(
                    value: e.scale.clamp(0.3, 3.0),
                    min: 0.3,
                    max: 3.0,
                    onChanged: (v) =>
                        _edit(id, (x) => x.copyWith(scale: v), commit: false),
                    onChangeEnd: (_) => _changed(),
                  ),
                ),
                SizedBox(
                  width: 44,
                  child: Text(
                    '${(e.scale * 100).round()}%',
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
            Row(
              children: [
                const SizedBox(width: 64, child: Text('Drehung')),
                Expanded(
                  child: Slider(
                    value: deg.clamp(-180.0, 180.0),
                    min: -180,
                    max: 180,
                    onChanged: (v) {
                      var d = v;
                      for (final s in const [-180.0, -90.0, 0.0, 90.0, 180.0]) {
                        if ((d - s).abs() < 4) d = s;
                      }
                      _edit(
                        id,
                        (x) => x.copyWith(rot: d * math.pi / 180),
                        commit: false,
                      );
                    },
                    onChangeEnd: (_) => _changed(),
                  ),
                ),
                SizedBox(
                  width: 44,
                  child: Text(
                    '${deg.round()}°',
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.restart_alt, size: 18),
                label: const Text('Position, Größe & Drehung zurück'),
                onPressed: () => _edit(
                  id,
                  (x) => x.copyWith(off: Offset.zero, scale: 1, rot: 0),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------ Foto der Ehrung
  String? _photoShown; // aufgelöstes Ehrungs-Foto (Data-URL), null = Profil
  final Map<String, String> _slotThumbs = {};

  /// Spieler, wie er auf der Grafik erscheint (ggf. mit Ehrungs-Foto).
  Player get _shownPlayer => _photoShown == null
      ? _player
      : _player.copyWith(customPhoto: _photoShown, useCustomPhoto: true);

  Future<String?> _slotThumb(PlayerPhotoSlot slot) async {
    final cached = _slotThumbs[slot.key];
    if (cached != null) return cached;
    String? thumb;
    try {
      final orig = await _app.playerPhoto(_player.id, slot);
      if (orig != null) {
        thumb = await compute(_honorThumb, orig);
      } else if (slot == PlayerPhotoSlot.fupa && _player.hasFupaPhoto) {
        thumb = _player.fupaPhoto;
      }
    } catch (_) {}
    if (thumb != null) _slotThumbs[slot.key] = thumb;
    return thumb;
  }

  Future<void> _resolvePhoto() async {
    final slot = PlayerPhotoSlot.fromKey(_layout.photoSlot);
    var shown = _layout.photoData;
    if (shown == null && slot != null) shown = await _slotThumb(slot);
    if (mounted && shown != _photoShown) setState(() => _photoShown = shown);
  }

  void _setPhoto(String? slot, String? data) {
    setState(() {
      _layout.photoSlot = slot;
      _layout.photoData = data;
      _rev++;
    });
    _changed();
    _resolvePhoto();
  }

  /// Foto aus Galerie/Kamera, quadratisch zugeschnitten (Data-URL) oder null.
  Future<String?> _pickCroppedPhoto(ImageSource source) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final file = await ImagePicker().pickImage(
        source: source,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 92,
      );
      if (file == null) return null;
      final raw = await file.readAsBytes();
      if (!mounted) return null;
      final cropped = await Navigator.of(context).push<Uint8List>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => PhotoCropScreen(imageBytes: raw),
        ),
      );
      if (cropped == null) return null;
      return _encodeSquareJpeg(cropped);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Foto konnte nicht geladen werden: $e')),
      );
      return null;
    }
  }

  /// Foto der Ehrung austauschen: Spielerfotos (FuPa, eigenes, Verein,
  /// Action), Galerie/Kamera – nur für diese Ehrung, das Profilbild bleibt.
  Future<void> _pickHonorPhoto() async {
    final thumbs = <PlayerPhotoSlot, String>{};
    for (final sl in PlayerPhotoSlot.values) {
      final t = await _slotThumb(sl);
      if (t != null) thumbs[sl] = t;
    }
    if (!mounted) return;
    final cur = _layout.photoData != null
        ? 'custom'
        : (_layout.photoSlot ?? 'profile');
    Widget avatar(String? dataUrl) {
      final b = TeamLogo.decode(dataUrl);
      return CircleAvatar(
        radius: 22,
        backgroundColor: _greenDark,
        backgroundImage: b == null ? null : MemoryImage(b),
        child: b == null ? const Icon(Icons.person, color: Colors.white) : null,
      );
    }

    const check = Icon(Icons.check);
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(
                title: Text(
                  'Foto für diese Ehrung',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text(
                  'Gilt nur für diese Grafik – das Profilbild des Spielers '
                  'bleibt unverändert.',
                ),
              ),
              ListTile(
                leading: avatar(_player.photoPath),
                title: const Text('Profilbild'),
                subtitle: const Text('Standard'),
                trailing: cur == 'profile' ? check : null,
                onTap: () => Navigator.pop(ctx, 'profile'),
              ),
              for (final e in thumbs.entries)
                ListTile(
                  leading: avatar(e.value),
                  title: Text(e.key.label),
                  subtitle: Text(e.key.description),
                  trailing: cur == e.key.key ? check : null,
                  onTap: () => Navigator.pop(ctx, 'slot:${e.key.key}'),
                ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Aus Galerie wählen'),
                trailing: cur == 'custom' ? check : null,
                onTap: () => Navigator.pop(ctx, 'gallery'),
              ),
              ListTile(
                leading: const Icon(Icons.camera_alt_outlined),
                title: const Text('Foto aufnehmen'),
                onTap: () => Navigator.pop(ctx, 'camera'),
              ),
              ListTile(
                leading: const Icon(Icons.account_circle_outlined),
                title: const Text('Profilbild des Spielers ändern …'),
                subtitle: const Text(
                  'Teamweit – auch für Kader und andere Grafiken',
                ),
                onTap: () => Navigator.pop(ctx, 'profileEdit'),
              ),
            ],
          ),
        ),
      ),
    );
    if (choice == null || !mounted) return;
    switch (choice) {
      case 'profile':
        _setPhoto(null, null);
      case 'gallery' || 'camera':
        final data = await _pickCroppedPhoto(
          choice == 'camera' ? ImageSource.camera : ImageSource.gallery,
        );
        if (data != null && mounted) _setPhoto(null, data);
      case 'profileEdit':
        await _changePhoto();
      default:
        if (choice.startsWith('slot:')) _setPhoto(choice.substring(5), null);
    }
  }

  /// Eigene Texte (frei platziert) über der Grafik.
  Widget _freeLayer(Size size) {
    final urk = _fmt == _Fmt.urkunde;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        for (final f in _fl.free)
          Positioned(
            left: f.x * size.width,
            top: f.y * size.height,
            child: FractionalTranslation(
              translation: const Offset(-0.5, -0.5),
              child: _Editable(
                f.itemId,
                child: Builder(
                  builder: (_) {
                    final l = _lookOf(f.itemId);
                    return Text(
                      f.text.isEmpty ? ' ' : f.text,
                      softWrap: false,
                      textAlign: l.textAlign(TextAlign.center),
                      style: l.apply(
                        TextStyle(
                          color: urk ? _ink : Colors.white,
                          fontSize: urk ? 20 : 24,
                          fontWeight: FontWeight.w800,
                          height: 1.1,
                        ),
                        glow: _gold,
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final size = _fmt.logical;
    final texts = {..._defaultTexts, ..._layout.texts};
    final stats = _stats;
    final graphic = _fmt == _Fmt.urkunde
        ? _UrkundeGraphic(
            player: _shownPlayer,
            teamLogo: _logo,
            texts: texts,
            edits: _fl,
            looks: _looks,
            avg: widget.avg,
            ratedCount: widget.ratedCount,
            stats: stats,
            barSponsors: _barSponsors,
            showRating: _showRating,
          )
        : _SocialGraphic(
            player: _shownPlayer,
            teamLogo: _logo,
            texts: texts,
            edits: _fl,
            looks: _looks,
            avg: widget.avg,
            ratedCount: widget.ratedCount,
            stats: stats,
            barSponsors: _barSponsors,
            gradTop: _hex(_settings.gradTop),
            gradBottom: _hex(_settings.gradBottom),
            gradShape: _settings.gradShape,
            bgPattern: _settings.bgPattern,
            bgImage: _settings.bgImage,
            overlayOpacity: _settings.overlayOpacity / 100,
            showRating: _showRating,
            logoCircle: _settings.logoShape == 'circle',
            compact: _fmt == _Fmt.post,
          );
    final editingView = _editing && !_capturing;
    final sel = _selected != null && _exists(_selected!) ? _selected : null;
    final canvas = _EditScope(
      layout: _fl,
      rev: _rev,
      editing: editingView,
      selected: _capturing ? null : sel,
      onSelect: _select,
      onStart: _gStart,
      onUpdate: _gUpdate,
      onEnd: _gEnd,
      onWheel: _wheel,
      child: SizedBox(
        key: _canvasKey,
        width: size.width,
        height: size.height,
        // KI-Look liegt über der Grafik (auch im Export), eigene Texte oben.
        child: Stack(
          fit: StackFit.expand,
          children: [
            _RingCropScope(
              crop: _crop,
              enabled: !_editing || (sel == 'photo' && _cropMode),
              onStart: () => _cropZ0 = _crop.z,
              onUpdate: (d, diameter) => _setCrop(
                z: d.pointerCount >= 2 ? _cropZ0 * d.scale : null,
                dx: _crop.dx + d.focalPointDelta.dx / diameter,
                dy: _crop.dy + d.focalPointDelta.dy / diameter,
                save: false,
              ),
              onEnd: _saveCrop,
              onWheel: (dy) =>
                  _setCrop(z: _crop.z * (dy < 0 ? 1.08 : 1 / 1.08)),
              child: graphic,
            ),
            if (_aiLooks[_fmt] case final look?)
              if (TeamLogo.decode(look.dataUrl) case final b?)
                IgnorePointer(
                  child: Opacity(
                    opacity: look.opacity.clamp(0.1, 1.0),
                    child: Image.memory(
                      b,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                    ),
                  ),
                ),
            _freeLayer(size),
          ],
        ),
      ),
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(_editing ? 'Bearbeiten' : 'Grafik teilen'),
        actions: _editing
            ? [
                IconButton(
                  tooltip: 'Rückgängig',
                  icon: const Icon(Icons.undo),
                  onPressed: _hist.canUndo || _histTimer != null
                      ? () => _undoRedo(true)
                      : null,
                ),
                IconButton(
                  tooltip: 'Wiederholen',
                  icon: const Icon(Icons.redo),
                  onPressed: _hist.canRedo ? () => _undoRedo(false) : null,
                ),
                PopupMenuButton<String>(
                  tooltip: 'Mehr',
                  onSelected: _menu,
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'add',
                      child: ListTile(
                        leading: Icon(Icons.title),
                        title: Text('Text hinzufügen'),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'hidden',
                      child: ListTile(
                        leading: Icon(Icons.visibility_outlined),
                        title: Text('Ausgeblendete Elemente'),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'saveTpl',
                      child: ListTile(
                        leading: Icon(Icons.bookmark_add_outlined),
                        title: Text('Als Vorlage für alle speichern'),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'loadTpl',
                      child: ListTile(
                        leading: Icon(Icons.bookmark_outline),
                        title: Text('Vorlage laden'),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'reset',
                      child: ListTile(
                        leading: Icon(Icons.restart_alt),
                        title: Text('Layout zurücksetzen (dieses Format)'),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'resetTexts',
                      child: ListTile(
                        leading: Icon(Icons.format_clear),
                        title: Text('Alle Texte zurücksetzen'),
                      ),
                    ),
                  ],
                ),
                IconButton(
                  tooltip: 'Bearbeiten beenden',
                  icon: const Icon(Icons.check),
                  onPressed: _toggleEdit,
                ),
              ]
            : [
                IconButton(
                  tooltip: 'Foto austauschen',
                  icon: const Icon(Icons.add_a_photo_outlined),
                  onPressed: _pickHonorPhoto,
                ),
                IconButton(
                  tooltip: 'Grafik anpassen',
                  icon: const Icon(Icons.tune),
                  onPressed: _openCustomize,
                ),
                IconButton(
                  tooltip: 'Texte & Elemente bearbeiten',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: _toggleEdit,
                ),
              ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: SegmentedButton<_Fmt>(
              segments: [
                for (final f in _Fmt.values)
                  ButtonSegment(value: f, label: Text(f.label)),
              ],
              selected: {_fmt},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() {
                _fmt = s.first;
                _selected = null;
                _cropMode = false;
              }),
            ),
          ),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _editing ? () => _select(null) : null,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: FittedBox(
                    fit: BoxFit.contain,
                    child: Stack(
                      children: [
                        RepaintBoundary(key: _boundaryKey, child: canvas),
                        if (_guides.isNotEmpty)
                          Positioned.fill(
                            child: IgnorePointer(
                              child: CustomPaint(
                                painter: _GuidePainter(_guides),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (_editing && sel != null)
            SafeArea(top: false, child: _editPanel())
          else ...[
            if (_editing)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 2),
                child: Text(
                  'Element antippen = bearbeiten · ziehen = verschieben · '
                  'zwei Finger/Mausrad = Größe & Drehung · ⋯ = eigener Text, '
                  'Vorlage',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _sharing ? null : _share,
                    icon: _sharing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.ios_share),
                    label: Text(
                      _fmt == _Fmt.urkunde
                          ? 'Urkunde teilen/drucken'
                          : 'Teilen',
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// Kuratierte Farbpalette und Verlauf-Vorlagen (wie Startelf-Grafik).
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
const _presets = <(String, String, String)>[
  ('Dunkelgrün', '#0E3325', '#15603F'),
  ('Vereinsgrün', '#0B6B43', '#0E3D28'),
  ('Schwarz', '#1F2937', '#000000'),
  ('Nacht', '#0C4A6E', '#111827'),
  ('Weinrot', '#7F1D1D', '#111827'),
];

Color _hex(String h) {
  var s = h.replaceAll('#', '').trim();
  if (s.length == 6) s = 'FF$s';
  return Color(int.tryParse(s, radix: 16) ?? 0xFF0E3325);
}

/// Rundes Spielerfoto in fester Größe mit Goldring; Rückfall auf Initialen.
class _PhotoRing extends StatelessWidget {
  const _PhotoRing({required this.player, required this.diameter});

  final Player player;
  final double diameter;

  @override
  Widget build(BuildContext context) {
    final bytes = TeamLogo.decode(player.photoPath);
    final fallback = player.lastName.isNotEmpty
        ? player.lastName[0].toUpperCase()
        : '?';
    final scope = _RingCropScope.maybeOf(context);
    final c = scope?.crop ?? (z: 1.0, dx: 0.0, dy: 0.0);
    final ring = Container(
      width: diameter,
      height: diameter,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: _greenDark,
      ),
      foregroundDecoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: _gold, width: 4),
      ),
      alignment: Alignment.center,
      child: bytes == null
          ? Text(
              fallback,
              style: TextStyle(
                color: Colors.white,
                fontSize: diameter * 0.4,
                fontWeight: FontWeight.w800,
              ),
            )
          : ClipOval(
              child: Transform.translate(
                offset: Offset(c.dx * diameter, c.dy * diameter),
                child: Transform.scale(
                  scale: c.z,
                  child: Image.memory(
                    bytes,
                    width: diameter,
                    height: diameter,
                    fit: BoxFit.cover,
                    // Glättet das Hochskalieren kleiner FuPa-Fotos im Export.
                    filterQuality: FilterQuality.high,
                    gaplessPlayback: true,
                  ),
                ),
              ),
            ),
    );
    if (scope == null || bytes == null || !scope.enabled) return ring;
    return Listener(
      onPointerSignal: (e) {
        if (e is! PointerScrollEvent) return;
        GestureBinding.instance.pointerSignalResolver.register(
          e,
          (ev) => scope.onWheel((ev as PointerScrollEvent).scrollDelta.dy),
        );
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onScaleStart: (_) => scope.onStart(),
        onScaleUpdate: (d) => scope.onUpdate(d, diameter),
        onScaleEnd: (_) => scope.onEnd(),
        child: ring,
      ),
    );
  }
}

Widget _logoChip(Uint8List bytes, {required double height}) => Container(
  height: height,
  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
  decoration: BoxDecoration(
    color: Colors.white,
    borderRadius: BorderRadius.circular(5),
  ),
  child: Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true),
);

/// Kompakte Statistik-Kachel „Zahl + Label".
class _StatTile extends StatelessWidget {
  const _StatTile({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.w900,
            height: 1.0,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.75),
            fontSize: 9,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
          ),
        ),
      ],
    );
  }
}

/// Moderne Social-Grafik (Instagram). [compact] = Post 1:1, sonst Story 9:16.
/// Jedes Element liegt in einer [_Editable]-Hülle (Designer-Bedienung).
class _SocialGraphic extends StatelessWidget {
  const _SocialGraphic({
    required this.player,
    required this.teamLogo,
    required this.texts,
    required this.edits,
    this.looks = const {},
    required this.avg,
    required this.ratedCount,
    required this.stats,
    required this.barSponsors,
    required this.gradTop,
    required this.gradBottom,
    this.gradShape,
    this.bgPattern = 0,
    required this.bgImage,
    required this.overlayOpacity,
    required this.showRating,
    this.logoCircle = false,
    required this.compact,
  });

  final Player player;
  final String? teamLogo;

  /// Wirksame Texte je Element (Standard + Änderungen des Nutzers).
  final Map<String, String> texts;
  final HonorFormatLayout edits;
  final Map<String, TextLook> looks;
  final double? avg;
  final int ratedCount;
  final _Stats stats;
  final List<Sponsor> barSponsors;
  final Color gradTop;
  final Color gradBottom;
  final String? gradShape;
  final double bgPattern;
  final String? bgImage;
  final double overlayOpacity; // 0..1
  final bool showRating;
  final bool logoCircle; // Logo auf rundem statt eckigem Feld
  final bool compact;

  String _t(String id, [String def = '']) => texts[id] ?? def;
  TextLook _look(String id) =>
      edits.item(id).look ?? looks[id] ?? const TextLook();

  Widget _text(
    String id,
    TextStyle base, {
    TextAlign align = TextAlign.center,
  }) {
    final l = _look(id);
    final a = l.textAlign(align);
    return _placed(id, _ftext(_t(id), l.apply(base, glow: _gold), a), a);
  }

  @override
  Widget build(BuildContext context) {
    final pad = compact ? 18.0 : 22.0;
    final photo = compact ? 120.0 : 168.0;
    final bgBytes = TeamLogo.decode(bgImage);
    final tiles = stats.socialTiles();
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(
          decoration: BoxDecoration(
            gradient: bgGradient(gradShape ?? 'linear', gradTop, gradBottom),
          ),
        ),
        if (bgPattern > 0) CustomPaint(painter: BgPatternPainter(bgPattern)),
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
        ],
        Padding(
          padding: EdgeInsets.all(pad),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(),
              SizedBox(height: compact ? 8 : 14),
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: SizedBox(
                    width: 320,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _Editable(
                          'photo',
                          child: _PhotoRing(player: player, diameter: photo),
                        ),
                        const SizedBox(height: 12),
                        _text(
                          'name',
                          const TextStyle(
                            color: Colors.white,
                            fontSize: 26,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.5,
                            height: 1.05,
                          ),
                        ),
                        if (_t('number').trim().isNotEmpty) ...[
                          const SizedBox(height: 2),
                          _text(
                            'number',
                            const TextStyle(
                              color: _gold,
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1,
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                        if (avg != null && showRating)
                          _Editable('rating', child: _noteBadge()),
                        const SizedBox(height: 14),
                        if (tiles.isNotEmpty)
                          _Editable('stats', child: _statRow(tiles)),
                        if (tiles.isNotEmpty &&
                            _t('legend').trim().isNotEmpty) ...[
                          const SizedBox(height: 6),
                          _text(
                            'legend',
                            TextStyle(
                              color: Colors.white.withValues(alpha: 0.6),
                              fontSize: 9,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              if (barSponsors.isNotEmpty) ...[
                SizedBox(height: compact ? 8 : 12),
                _Editable('sponsors', child: _sponsorBar()),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _header() {
    final team = _look('team');
    final teamAlign = team.textAlign(TextAlign.left);
    return Column(
      children: [
        _Editable(
          'team',
          child: Row(
            children: [
              if (teamLogo != null) ...[
                if (TeamLogo.decode(teamLogo) case final lb?)
                  LogoChip(
                    bytes: lb,
                    height: compact ? 34 : 44,
                    circle: logoCircle,
                  )
                else
                  TeamLogo(logoPath: teamLogo, size: compact ? 30 : 38),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Align(
                  alignment: _alignOf(teamAlign),
                  child: _ftext(
                    _t('team'),
                    team.apply(
                      TextStyle(
                        color: Colors.white.withValues(alpha: 0.9),
                        fontSize: compact ? 12 : 14,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                      ),
                      glow: _gold,
                    ),
                    teamAlign,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        _text(
          'occasion',
          TextStyle(
            color: _gold,
            fontSize: compact ? 22 : 26,
            fontWeight: FontWeight.w900,
            letterSpacing: 1.5,
            height: 1.0,
          ),
        ),
        if (_t('subtitle').trim().isNotEmpty) ...[
          const SizedBox(height: 2),
          _text(
            'subtitle',
            TextStyle(
              color: Colors.white.withValues(alpha: 0.85),
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 2,
            ),
          ),
        ],
      ],
    );
  }

  Widget _noteBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: _gold,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star_rounded, color: _greenDark, size: 20),
          const SizedBox(width: 6),
          Text(
            'Ø ${avg!.toStringAsFixed(1)}',
            style: const TextStyle(
              color: _greenDark,
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '($ratedCount Bew.)',
            style: TextStyle(
              color: _greenDark.withValues(alpha: 0.8),
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _statRow(List<(String, String)> tiles) {
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 22,
      runSpacing: 10,
      children: [
        for (final (label, value) in tiles)
          _StatTile(
            value: value,
            label: _t('stat:$label', label.toUpperCase()),
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
              _logoChip(TeamLogo.decode(s.logo)!, height: compact ? 24 : 30),
        ],
      ),
    );
  }
}

/// Klassische DIN-A4-Urkunde (Hochformat) zum Drucken. Der Inhalt skaliert
/// über eine FittedBox sicher in das A4-Format (kein Überlauf). Jedes Element
/// liegt in einer [_Editable]-Hülle (Designer-Bedienung).
class _UrkundeGraphic extends StatelessWidget {
  const _UrkundeGraphic({
    required this.player,
    required this.teamLogo,
    required this.texts,
    required this.edits,
    this.looks = const {},
    required this.avg,
    required this.ratedCount,
    required this.stats,
    required this.barSponsors,
    required this.showRating,
  });

  final Player player;
  final String? teamLogo;
  final Map<String, String> texts;
  final HonorFormatLayout edits;
  final Map<String, TextLook> looks;
  final double? avg;
  final int ratedCount;
  final _Stats stats;
  final List<Sponsor> barSponsors;
  final bool showRating;

  static const _line = Color(0xFFE7E3D8);

  String _t(String id, [String def = '']) => texts[id] ?? def;
  TextLook _look(String id) =>
      edits.item(id).look ??
      looks[id == 'ulabel' ? 'subtitle' : id] ??
      const TextLook();

  Widget _text(String id, TextStyle base, {EdgeInsets? pad}) {
    final l = _look(id);
    final a = l.textAlign(TextAlign.center);
    Widget w = _ftext(_t(id), l.apply(base, glow: _gold), a);
    if (pad != null) w = Padding(padding: pad, child: w);
    return _placed(id, w, a);
  }

  @override
  Widget build(BuildContext context) {
    // Modern, weißer Hintergrund; dezenter Rahmen + goldener Akzentbalken oben.
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.all(16),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _line, width: 1.5),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Editable('bar', child: Container(height: 6, color: _gold)),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 22, 24, 20),
                // Skaliert den Inhalt sicher ins A4-Format (nie Überlauf).
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: SizedBox(width: 330, child: _content()),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _content() {
    final team = _look('team');
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Kopf: Logo + Verein.
        Center(
          child: _Editable(
            'team',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (teamLogo != null) ...[
                  TeamLogo(logoPath: teamLogo, size: 34),
                  const SizedBox(width: 10),
                ],
                Flexible(
                  child: _ftext(
                    _t('team'),
                    team.apply(
                      TextStyle(
                        color: _ink.withValues(alpha: 0.75),
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.5,
                      ),
                      glow: _gold,
                    ),
                    team.textAlign(TextAlign.center),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        // Eyebrow (Anlass) + kleines URKUNDE-Label.
        _text(
          'occasion',
          const TextStyle(
            color: _gold,
            fontSize: 20,
            fontWeight: FontWeight.w900,
            letterSpacing: 3,
            height: 1.05,
          ),
        ),
        const SizedBox(height: 6),
        _text(
          'ulabel',
          TextStyle(
            color: _ink.withValues(alpha: 0.55),
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 2,
          ),
        ),
        const SizedBox(height: 20),
        Center(
          child: _Editable(
            'photo',
            child: _PhotoRing(player: player, diameter: 104),
          ),
        ),
        const SizedBox(height: 14),
        _text(
          'name',
          const TextStyle(
            color: _ink,
            fontSize: 28,
            fontWeight: FontWeight.w900,
            height: 1.05,
          ),
        ),
        const SizedBox(height: 8),
        _text(
          'honor',
          TextStyle(
            color: _ink.withValues(alpha: 0.72),
            fontSize: 12.5,
            height: 1.45,
          ),
          pad: const EdgeInsets.symmetric(horizontal: 6),
        ),
        if (showRating && avg != null) ...[
          const SizedBox(height: 14),
          Center(child: _Editable('rating', child: _notePill())),
        ],
        if (stats.urkundeAny) ...[
          const SizedBox(height: 16),
          _Editable('stats', child: _statsBlock()),
        ],
        if (barSponsors.isNotEmpty) ...[
          const SizedBox(height: 18),
          Center(child: _Editable('sponsors', child: _sponsorBar())),
        ],
      ],
    );
  }

  Widget _notePill() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      decoration: BoxDecoration(
        color: _gold,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star_rounded, color: Colors.white, size: 18),
          const SizedBox(width: 6),
          Text(
            'Ø ${avg!.toStringAsFixed(1)}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '($ratedCount Bew.)',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.9),
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _statsBlock() {
    Widget col(String key, String title, List<(String, String)> rows) =>
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _t('stat:t:$key', title),
                style: const TextStyle(
                  color: _gold,
                  fontSize: 9.5,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 4),
              for (final r in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _t('stat:${r.$1}', r.$1),
                        style: TextStyle(
                          color: _ink.withValues(alpha: 0.7),
                          fontSize: 10,
                        ),
                      ),
                      Text(
                        r.$2,
                        style: const TextStyle(
                          color: _ink,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );

    // Nur die aktivierten Quellen – Spalten nebeneinander.
    final cols = [
      for (final c in stats.urkundeCols()) col(c.key, c.title, c.rows),
    ];

    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F6F5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _line),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < cols.length; i++) ...[
              if (i > 0)
                Container(
                  width: 1,
                  margin: const EdgeInsets.symmetric(horizontal: 14),
                  color: _line,
                ),
              cols[i],
            ],
          ],
        ),
      ),
    );
  }

  Widget _sponsorBar() {
    return Column(
      children: [
        Text(
          _t('sponsorsTitle', 'MIT FREUNDLICHER UNTERSTÜTZUNG'),
          textAlign: TextAlign.center,
          style: TextStyle(
            color: _ink.withValues(alpha: 0.5),
            fontSize: 8,
            fontWeight: FontWeight.w700,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final s in barSponsors)
              if (TeamLogo.decode(s.logo) != null)
                Container(
                  height: 28,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(color: _line),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Image.memory(
                    TeamLogo.decode(s.logo)!,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                  ),
                ),
          ],
        ),
      ],
    );
  }
}

/// Statistik-Daten der Ehrung – gemeinsam für Grafik und Bearbeiten-Panel
/// (welche Spalten/Kacheln und Bezeichnungen gerade sichtbar sind).
class _Stats {
  const _Stats({
    required this.month,
    required this.total,
    required this.fupa,
    required this.club,
    required this.showMonth,
    required this.showTotal,
    required this.showFupa,
    required this.showClub,
  });

  final PlayerMonthStats month;
  final PlayerMonthStats total;
  final PlayerStat? fupa;
  final FupaClubTotal? club;
  final bool showMonth;
  final bool showTotal;
  final bool showFupa;
  final bool showClub;

  bool get clubShown => showClub && club != null && club!.hasAny;
  String get clubName =>
      (club == null || club!.clubName.isEmpty) ? 'Verein' : club!.clubName;
  bool get urkundeAny => showMonth || showTotal || showFupa || clubShown;

  /// Spalten der Urkunde: key, Standard-Titel, Zeilen (Bezeichnung, Wert).
  List<({String key, String title, List<(String, String)> rows})>
  urkundeCols() {
    final f = fupa;
    final fc = club;
    return [
      if (showMonth)
        (
          key: 'month',
          title: 'DIESER MONAT',
          rows: [
            ('Spiele', '${month.games}'),
            ('Tore', '${month.goals}'),
            ('Vorlagen', '${month.assists}'),
            if (month.yellow > 0) ('Gelbe Karten', '${month.yellow}'),
            if (month.redTotal > 0) ('Rote Karten', '${month.redTotal}'),
          ],
        ),
      if (showTotal)
        (
          key: 'total',
          title: 'GESAMT',
          rows: [
            ('Spiele', '${total.games}'),
            ('Tore', '${total.goals}'),
            ('Vorlagen', '${total.assists}'),
            if (total.yellow > 0) ('Gelbe Karten', '${total.yellow}'),
            if (total.redTotal > 0) ('Rote Karten', '${total.redTotal}'),
          ],
        ),
      if (showFupa)
        (
          key: 'season',
          title: 'SAISON (FUPA)',
          rows: [
            ('Spiele', '${f?.matches ?? 0}'),
            ('Tore', '${f?.goals ?? 0}'),
            ('Vorlagen', '${f?.assists ?? 0}'),
            ('Scorerpunkte', '${f?.scorerPoints ?? 0}'),
            ('Minuten', '${f?.minutes ?? 0}'),
            if ((f?.yellowCards ?? 0) > 0) ('Gelbe', '${f!.yellowCards}'),
            if ((f?.yellowRedCards ?? 0) > 0)
              ('Gelb-Rot', '${f!.yellowRedCards}'),
            if ((f?.redCards ?? 0) > 0) ('Rote', '${f!.redCards}'),
            if ((f?.topEleven ?? 0) > 0) ('⭐ Top11', '${f!.topEleven}'),
          ],
        ),
      if (clubShown)
        (
          key: 'club',
          title: '${clubName.toUpperCase()} GESAMT',
          rows: [
            ('Spiele', '${fc!.matches}'),
            ('Tore', '${fc.goals}'),
            ('Vorlagen', '${fc.assists}'),
            ('Scorerpunkte', '${fc.scorerPoints}'),
          ],
        ),
    ];
  }

  bool get _monthShown => showMonth && month.hasAny;
  bool get _totalShown => showTotal && total.hasAny;
  bool get _fupaShown => showFupa && fupa != null;

  /// Kacheln der Social-Grafik: (Bezeichnung, Wert).
  List<(String, String)> socialTiles() {
    final f = fupa;
    final fc = club;
    return [
      if (_monthShown) ...[
        ('Tore M.', '${month.goals}'),
        ('Vorl. M.', '${month.assists}'),
        if (month.redTotal > 0) ('Rot M.', '${month.redTotal}'),
        if (month.yellow > 0) ('Gelb M.', '${month.yellow}'),
      ],
      if (_totalShown) ...[
        ('Spiele G.', '${total.games}'),
        ('Tore G.', '${total.goals}'),
        ('Vorl. G.', '${total.assists}'),
      ],
      if (_fupaShown) ...[
        ('Spiele S.', '${f!.matches}'),
        ('Tore S.', '${f.goals}'),
        ('Vorl. S.', '${f.assists}'),
        ('Min. S.', '${f.minutes}'),
        if (f.topEleven > 0) ('⭐ Top11', '${f.topEleven}'),
      ],
      if (clubShown) ...[
        ('Spiele V.', '${fc!.matches}'),
        ('Tore V.', '${fc.goals}'),
        ('Vorl. V.', '${fc.assists}'),
        ('Scorer V.', '${fc.scorerPoints}'),
      ],
    ];
  }

  String socialLegend() => [
    if (_monthShown) 'M. = Monat',
    if (_totalShown) 'G. = Gesamt',
    if (_fupaShown) 'S. = Saison (FuPa)',
    if (clubShown) 'V. = $clubName gesamt (FuPa)',
  ].join(' · ');
}

Alignment _alignOf(TextAlign a) => switch (a) {
  TextAlign.left || TextAlign.start => Alignment.centerLeft,
  TextAlign.right || TextAlign.end => Alignment.centerRight,
  _ => Alignment.center,
};

/// Text, der nur bei Enter umbricht; zu breite Zeilen werden verkleinert.
Widget _ftext(String text, TextStyle style, TextAlign align) => FittedBox(
  fit: BoxFit.scaleDown,
  alignment: _alignOf(align),
  child: Text(
    text.isEmpty ? ' ' : text,
    textAlign: align,
    softWrap: false,
    style: style,
  ),
);

/// Element an seiner Standardstelle (Ausrichtung) mit Bearbeiten-Hülle.
Widget _placed(String id, Widget child, TextAlign a) => Align(
  alignment: _alignOf(a),
  child: _Editable(id, child: child),
);

/// Reicht das Layout und die Gesten-Rückrufe an alle [_Editable]-Hüllen.
class _EditScope extends InheritedWidget {
  const _EditScope({
    required this.layout,
    required this.rev,
    required this.editing,
    required this.selected,
    required this.onSelect,
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
    required this.onWheel,
    required super.child,
  });

  final HonorFormatLayout layout;
  final int rev;
  final bool editing;
  final String? selected;
  final ValueChanged<String> onSelect;
  final void Function(String id, ScaleStartDetails d, BuildContext ctx) onStart;
  final void Function(String id, ScaleUpdateDetails d, BuildContext ctx)
  onUpdate;
  final ValueChanged<String> onEnd;
  final void Function(String id, double dy) onWheel;

  static _EditScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_EditScope>();

  @override
  bool updateShouldNotify(_EditScope old) =>
      old.rev != rev ||
      old.layout != layout ||
      old.editing != editing ||
      old.selected != selected;
}

/// Hülle eines Grafik-Elements: Versatz, Drehung, Größe, ausgeblendet; im
/// Bearbeiten-Modus antippbar/ziehbar mit Auswahlrahmen. Die äußerste Box
/// (Transform.translate) liegt im Koordinatensystem des Eltern-Layouts –
/// darüber rechnet der Editor Fingerbewegungen um.
class _Editable extends StatelessWidget {
  const _Editable(this.id, {required this.child});

  final String id;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final s = _EditScope.maybeOf(context);
    if (s == null) return child;
    final e = s.layout.item(id);
    var w = child;
    if (s.editing && s.selected == id) {
      w = DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: Border.all(
            color: const Color(0xFFE91E63),
            width: 1.4 / e.scale,
          ),
          borderRadius: BorderRadius.circular(3),
        ),
        child: w,
      );
    }
    if (e.hidden) {
      w = s.editing
          ? Opacity(opacity: 0.25, child: w)
          : Visibility(
              visible: false,
              maintainSize: true,
              maintainAnimation: true,
              maintainState: true,
              child: w,
            );
    }
    if (s.editing) {
      w = Listener(
        onPointerSignal: (ev) {
          if (ev is! PointerScrollEvent) return;
          GestureBinding.instance.pointerSignalResolver.register(
            ev,
            (x) => s.onWheel(id, (x as PointerScrollEvent).scrollDelta.dy),
          );
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => s.onSelect(id),
          onScaleStart: (d) => s.onStart(id, d, context),
          onScaleUpdate: (d) => s.onUpdate(id, d, context),
          onScaleEnd: (_) => s.onEnd(id),
          child: w,
        ),
      );
    }
    if (e.scale != 1) w = Transform.scale(scale: e.scale, child: w);
    if (e.rot != 0) w = Transform.rotate(angle: e.rot, child: w);
    return Transform.translate(offset: e.off, child: w);
  }
}

/// Magenta-Hilfslinien beim Einrasten (liegen außerhalb des Exports).
class _GuidePainter extends CustomPainter {
  _GuidePainter(this.lines);

  final List<({bool vertical, double at})> lines;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = const Color(0xFFE91E63)
      ..strokeWidth = 1;
    for (final l in lines) {
      if (l.vertical) {
        canvas.drawLine(Offset(l.at, 0), Offset(l.at, size.height), p);
      } else {
        canvas.drawLine(Offset(0, l.at), Offset(size.width, l.at), p);
      }
    }
  }

  @override
  bool shouldRepaint(_GuidePainter old) => old.lines != lines;
}

/// Gibt den Ausschnitt (Zoom/Verschiebung) und die Gesten-Rückrufe an das
/// runde Spielerfoto weiter – ohne sie durch alle Grafik-Klassen zu reichen.
class _RingCropScope extends InheritedWidget {
  const _RingCropScope({
    required this.crop,
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
    required this.onWheel,
    this.enabled = true,
    required super.child,
  });

  /// false = Gesten gehen an den Element-Editor (Bearbeiten-Modus).
  final bool enabled;

  final ({double z, double dx, double dy}) crop;
  final VoidCallback onStart;
  final void Function(ScaleUpdateDetails d, double diameter) onUpdate;
  final VoidCallback onEnd;
  final ValueChanged<double> onWheel;

  static _RingCropScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_RingCropScope>();

  @override
  bool updateShouldNotify(_RingCropScope old) =>
      old.crop != crop || old.enabled != enabled;
}

/// Ehrungs-Foto aus einem Spielerfoto: höchstens 1024 px (scharf im
/// A4-Export, klein genug für Layout + Cloud). Läuft per compute().
String? _honorThumb(String dataUrl) {
  final bytes = dataUrlBytes(dataUrl);
  if (bytes == null) return null;
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  final baked = img.bakeOrientation(decoded);
  final small = (baked.width > 1024 || baked.height > 1024)
      ? (baked.width >= baked.height
            ? img.copyResize(baked, width: 1024)
            : img.copyResize(baked, height: 1024))
      : baked;
  return 'data:image/jpeg;base64,'
      '${base64Encode(img.encodeJpg(small, quality: 88))}';
}
