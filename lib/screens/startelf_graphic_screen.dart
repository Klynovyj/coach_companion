import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/graphic_settings.dart';
import '../models/sponsor.dart';
import '../services/share_service.dart';
import '../state/app_state.dart';
import '../widgets/team_logo.dart';

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
  // Nur Ergebnis-Grafik: optionales Foto oben (Data-URL, nicht gespeichert).
  String? _resultPhoto;

  // Logische Zeichengrößen (× pixelRatio 3 = 1080×1920 bzw. 1080×1080).
  static const double _storyW = 360, _storyH = 640;
  static const double _postW = 360, _postH = 360;

  @override
  void initState() {
    super.initState();
    _load();
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
    // Lokale Einstellung (evtl. vor Existenz der Cloud-Tabelle angelegt) in die
    // Cloud nachschieben, damit sie auf anderen Geräten erscheint.
    state.pushGraphicSettingsToCloud();
  }

  // Effektive Anzeige-Werte (Einstellung überschreibt die Defaults).
  String get _title =>
      (_settings.title != null && _settings.title!.trim().isNotEmpty)
      ? _settings.title!.trim()
      : widget.teamName;
  String? get _logo => _settings.logo ?? widget.teamLogo;

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
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final file = await ImagePicker().pickImage(
        source: source,
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

  /// Foto oben für die Ergebnis-Grafik: aufnehmen / aus Galerie / entfernen.
  Future<void> _pickResultPhoto() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera),
              title: const Text('Foto aufnehmen'),
              onTap: () => Navigator.pop(ctx, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Aus Galerie'),
              onTap: () => Navigator.pop(ctx, 'gallery'),
            ),
            if (_resultPhoto != null)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Foto entfernen'),
                onTap: () => Navigator.pop(ctx, 'remove'),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'remove') {
      setState(() => _resultPhoto = null);
      return;
    }
    final url = await _pickImage(
      asBackground: true,
      source: choice == 'camera' ? ImageSource.camera : ImageSource.gallery,
    );
    if (url != null && mounted) setState(() => _resultPhoto = url);
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
                  // Hintergrundbild -------------------------------------
                  _rowWithImage(
                    label: 'Hintergrundbild',
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
                            _settings.copyWith(gradTop: p.$2, gradBottom: p.$3),
                          ),
                        ),
                    ],
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
    setState(() => _sharing = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final boundary =
          _boundaryKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) return;
      final logicalWidth = _story ? _storyW : _postW;
      final image = await boundary.toImage(pixelRatio: 1080 / logicalWidth);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return;
      final kind = widget.isAnnouncement
          ? 'Spieltag'
          : (widget.isResult ? 'Ergebnis' : 'Startelf');
      final savedPath = await shareOrSaveImage(
        data.buffer.asUint8List(),
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
          if (widget.isResult)
            IconButton(
              tooltip: 'Foto oben (aufnehmen/Galerie)',
              icon: Icon(
                _resultPhoto != null
                    ? Icons.add_a_photo
                    : Icons.add_a_photo_outlined,
              ),
              onPressed: _pickResultPhoto,
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
                        logo: _logo,
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
                        opponentLogo: _settings.showOpponentLogo
                            ? widget.opponentLogo
                            : null,
                        compact: !_story,
                        result: widget.result,
                        announcement: widget.announcement,
                        resultPhoto: _resultPhoto,
                        showPhotos: _settings.showPhotos,
                        bgPreset: _settings.bgPreset,
                      ),
                    ),
                  ),
                ),
              ),
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
                      : const Icon(Icons.share),
                  label: const Text('Teilen (WhatsApp)'),
                ),
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

// Fertige Verlauf-Vorlagen (Name, oben, unten).
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
    this.resultPhoto,
    this.showPhotos = false,
    this.bgPreset,
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
  final String? resultPhoto; // Ergebnis-Grafik: Foto oben (Data-URL)
  final bool showPhotos; // Spielerfotos in der Ergebnis-Grafik
  final String? bgPreset; // eingebautes Hintergrund-Design ('stripes')

  @override
  Widget build(BuildContext context) {
    if (announcement != null) return _announcementLayout();
    if (result != null && resultPhoto != null) return _photoResultLayout();
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
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.topCenter,
                  child: result != null ? _resultBlock() : _lineupBlock(),
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
    final bgBytes = TeamLogo.decode(bgImage);
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
          Colors.white.withValues(alpha: 0.35),
          Colors.white.withValues(alpha: 0.08),
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
                style: const TextStyle(
                  color: Colors.white,
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

  Widget _presentedBy(Sponsor s) {
    final logoBytes = TeamLogo.decode(s.logo);
    return Row(
      children: [
        Text(
          'PRÄSENTIERT VON',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.8),
            fontSize: compact ? 9 : 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(width: 8),
        if (logoBytes != null)
          _logoChip(logoBytes, height: compact ? 24 : 30)
        else
          Text(
            s.name,
            style: TextStyle(
              color: Colors.white,
              fontSize: compact ? 13 : 15,
              fontWeight: FontWeight.bold,
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
            color: Colors.white.withValues(alpha: 0.8),
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

  /// Ergebnis-Grafik mit Foto oben: Foto (≈52 %) + dunkles Panel mit
  /// „FULL TIME" + Spielstand/Torschützen/Karten + Sponsoren.
  Widget _photoResultLayout() {
    final photoBytes = TeamLogo.decode(resultPhoto);
    final pad = compact ? 14.0 : 18.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 52,
          child: photoBytes != null
              ? Image.memory(
                  photoBytes,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                )
              : Container(color: gradTop),
        ),
        Expanded(
          flex: 48,
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [gradTop, gradBottom],
              ),
            ),
            padding: EdgeInsets.fromLTRB(pad, compact ? 10 : 14, pad, pad),
            child: Column(
              children: [
                if (mainSponsor != null) ...[
                  _presentedBy(mainSponsor!),
                  SizedBox(height: compact ? 6 : 10),
                ],
                const Text(
                  'FULL TIME',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.5,
                    height: 1.0,
                  ),
                ),
                SizedBox(height: compact ? 8 : 12),
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.topCenter,
                    child: _resultBlock(),
                  ),
                ),
                if (barSponsors.isNotEmpty) ...[
                  SizedBox(height: compact ? 6 : 10),
                  _sponsorBar(),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Ergebnis-Block: großer Spielstand + Torschützen + Karten (je Seite).
  Widget _resultBlock() {
    final r = result!;
    final ownLogo = TeamLogo.decode(logo);
    final oppLogo = TeamLogo.decode(opponentLogo);
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

    Widget side(Uint8List? bytes, String name) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (bytes != null)
          _logoChip(bytes, height: 56)
        else
          const SizedBox(height: 56),
        const SizedBox(height: 6),
        SizedBox(
          width: 120,
          child: Text(
            name.toUpperCase(),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w800,
              height: 1.1,
            ),
          ),
        ),
      ],
    );

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
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: side(ownLogo, title)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  '${r.ownScore} : ${r.oppScore}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 46,
                    fontWeight: FontWeight.w900,
                    height: 1.0,
                  ),
                ),
              ),
              Expanded(
                child: side(oppLogo, opponentName.isEmpty ? 'Gegner' : opponentName),
              ),
            ],
          ),
          section('TORE', ownGoals, oppGoals),
          section('KARTEN', ownCards, oppCards),
        ],
      ),
    );
  }

  /// Spielankündigungs-Grafik: Titel (POKALSPIEL/SPIELTAG) + große Logos „VS" +
  /// Datum/Uhrzeit/Spielstätte/Adresse mit Icons.
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

    Widget infoRow(IconData icon, String text) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 22),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 17,
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
        ),
      );
      if (local.hour != 0 || local.minute != 0) {
        rows.add(
          infoRow(
            Icons.schedule,
            '${DateFormat('HH:mm', 'de_DE').format(local)} Uhr',
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

    return Stack(
      fit: StackFit.expand,
      children: [
        _bgBase(),
        Padding(
          padding: EdgeInsets.all(pad),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Spacer(flex: 2),
              if (mainSponsor != null) ...[
                _presentedBy(mainSponsor!),
                SizedBox(height: compact ? 10 : 14),
              ],
              // Titel immer EINZEILIG: skaliert automatisch auf die Breite.
              SizedBox(
                width: double.infinity,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.center,
                  child: Text(
                    titleWord,
                    maxLines: 1,
                    softWrap: false,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 52,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 2,
                      height: 1.0,
                    ),
                  ),
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
              SizedBox(height: compact ? 20 : 30),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(child: Center(child: side(ownLogo))),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Text(
                      'VS',
                      style: TextStyle(
                        color: Colors.white,
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
              const Spacer(flex: 3),
              if (barSponsors.isNotEmpty) _sponsorBar(),
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
