import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/graphic_settings.dart';
import '../models/player.dart';
import '../models/player_stat.dart';
import '../models/sponsor.dart';
import '../services/fupa/fupa_dtos.dart';
import '../services/share_service.dart';
import '../state/app_state.dart';
import '../widgets/team_logo.dart';
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
  GraphicSettings _settings = const GraphicSettings(id: 'local');

  // Anlass (Eyebrow) + Untertitel – editierbar.
  late String _occasion = widget.defaultOccasion;
  late String _subtitle =
      widget.defaultSubtitle ?? (widget.yearMonth != null ? _monthLabel : '');

  bool get _hasMonth => widget.yearMonth != null;
  bool get _hasRating => widget.avg != null;

  // Welche Datenquellen auf der Grafik/Urkunde erscheinen (umschaltbar).
  late bool _showRating = _hasRating; // Bewertungen (Ø-Note)
  late bool _showMonth = _hasMonth; // meine Monatsdaten (live getrackt)
  late bool _showTotal = !_hasMonth; // Gesamt (alle getrackten Spiele)
  bool _showFupa = true; // FuPa-Saison
  late bool _showFupaClub = !_hasMonth; // FuPa gesamt (Verein)
  bool _fupaClubPflicht = true; // nur Pflichtspiele (Pokal zählt)

  /// Vereins-Gesamtwerte entsprechend dem Pflichtspiel-Schalter; null ohne Daten.
  FupaClubTotal? get _fupaClub {
    final c = _fupaCareer;
    if (c == null) return null;
    final t = c.total(pflichtOnly: _fupaClubPflicht);
    return t.hasAny ? t : null;
  }

  // Spieler (lokal veränderbar – z.B. neues Foto) und editierbarer Text.
  late Player _player = widget.player;
  String? _honorText;

  String get _defaultHonor => _hasMonth
      ? 'wird für herausragende Leistungen im Monat $_monthLabel zum '
            'Spieler des Monats ernannt.'
      : 'wird für seine Verdienste um den Verein geehrt. '
            'Herzlichen Glückwunsch und vielen Dank!';
  String get _effectiveHonor =>
      (_honorText != null && _honorText!.trim().isNotEmpty)
      ? _honorText!.trim()
      : _defaultHonor;

  @override
  void initState() {
    super.initState();
    _load();
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
    final fupaCareer = await state.playerFupaClub(
      widget.player.teamId,
      widget.player,
    );
    if (!mounted) return;
    setState(() {
      _sponsors = sponsors;
      _settings = settings;
      _month = month;
      _total = total;
      _fupa = fupa;
      _fupaCareer = fupaCareer;
      _loading = false;
    });
  }

  List<Sponsor> get _barSponsors =>
      _sponsors.where((s) => s.logo != null).toList();

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
    final honorCtrl = TextEditingController(text: _effectiveHonor);
    final occasionCtrl = TextEditingController(text: _occasion);
    final subtitleCtrl = TextEditingController(text: _subtitle);
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
                  const SizedBox(height: 6),
                  Text(
                    'Logo, Titel und Farben gelten teamweit (wie bei der '
                    'Startelf-Grafik). Der Urkunden-Look bleibt klassisch.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  // Anlass: Vorlagen + frei editierbar.
                  const Text(
                    'Anlass',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final p in _occasionPresets)
                        ActionChip(
                          label: Text(p),
                          onPressed: () {
                            occasionCtrl.text = p;
                            setState(() => _occasion = p);
                            setSheet(() {});
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: occasionCtrl,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'Anlass-Titel',
                      helperText: 'Große Überschrift der Grafik',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) => setState(() => _occasion = v),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: subtitleCtrl,
                    textCapitalization: TextCapitalization.words,
                    decoration: InputDecoration(
                      labelText: 'Untertitel (optional)',
                      hintText: _hasMonth ? _monthLabel : 'z.B. Garather SV',
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (v) => setState(() => _subtitle = v),
                  ),
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
                  // Urkunden-Text – jederzeit frei eingebbar.
                  TextField(
                    controller: honorCtrl,
                    minLines: 2,
                    maxLines: 4,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      labelText: 'Urkunden-Text',
                      helperText: 'Erscheint auf der Urkunde unter dem Namen',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        tooltip: 'Auf Standardtext zurücksetzen',
                        icon: const Icon(Icons.restart_alt),
                        onPressed: () {
                          honorCtrl.text = _defaultHonor;
                          setState(() => _honorText = null);
                          setSheet(() {});
                        },
                      ),
                    ),
                    onChanged: (v) => setState(() => _honorText = v),
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
                  if (_fupaCareer != null) ...[
                    Builder(
                      builder: (_) {
                        final club = _fupaCareer!.total(
                          pflichtOnly: _fupaClubPflicht,
                        );
                        return SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            'FuPa gesamt (${club.clubName.isEmpty ? 'Verein' : club.clubName})',
                          ),
                          subtitle: Text(
                            '${_fupaClubPflicht ? 'Nur Pflichtspiele' : 'Alle Spiele'}: '
                            '${club.matches} Spiele, ${club.goals} Tore, '
                            '${club.assists} Vorlagen',
                          ),
                          value: _showFupaClub,
                          onChanged: (v) {
                            setState(() => _showFupaClub = v);
                            setSheet(() {});
                          },
                        );
                      },
                    ),
                    if (_showFupaClub)
                      Padding(
                        padding: const EdgeInsets.only(left: 16),
                        child: SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Nur Pflichtspiele'),
                          subtitle: const Text(
                            'Freundschafts-/Testspiele ausschließen (Pokal zählt)',
                          ),
                          value: _fupaClubPflicht,
                          onChanged: (v) {
                            setState(() => _fupaClubPflicht = v);
                            setSheet(() {});
                          },
                        ),
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
      final image = await boundary.toImage(
        pixelRatio: _fmt.targetWidth / _fmt.logical.width,
      );
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return;
      final safeName = _player.fullName.replaceAll(' ', '-');
      final savedPath = await shareOrSaveImage(
        data.buffer.asUint8List(),
        'SpielerDesMonats_${safeName}_${widget.yearMonth}_${_fmt.fileSuffix}',
        text: 'Spieler des Monats $_monthLabel – ${_player.fullName}',
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

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final size = _fmt.logical;
    final graphic = _fmt == _Fmt.urkunde
        ? _UrkundeGraphic(
            player: _player,
            teamName: _title,
            teamLogo: _logo,
            occasion: _occasion,
            subtitle: _subtitle,
            honorText: _effectiveHonor,
            avg: widget.avg,
            ratedCount: widget.ratedCount,
            month: _month,
            total: _total,
            fupa: _fupa,
            fupaClub: _fupaClub,
            barSponsors: _barSponsors,
            showRating: _showRating,
            showMonth: _showMonth,
            showTotal: _showTotal,
            showFupa: _showFupa,
            showFupaClub: _showFupaClub,
          )
        : _SocialGraphic(
            player: _player,
            teamName: _title,
            teamLogo: _logo,
            occasion: _occasion,
            subtitle: _subtitle,
            avg: widget.avg,
            ratedCount: widget.ratedCount,
            month: _month,
            total: _total,
            fupa: _fupa,
            fupaClub: _fupaClub,
            barSponsors: _barSponsors,
            gradTop: _hex(_settings.gradTop),
            gradBottom: _hex(_settings.gradBottom),
            bgImage: _settings.bgImage,
            overlayOpacity: _settings.overlayOpacity / 100,
            showRating: _showRating,
            showMonth: _showMonth,
            showTotal: _showTotal,
            showFupa: _showFupa,
            showFupaClub: _showFupaClub,
            compact: _fmt == _Fmt.post,
          );
    return Scaffold(
      appBar: AppBar(
        title: const Text('Grafik teilen'),
        actions: [
          IconButton(
            tooltip: 'Spielerfoto (Galerie/Kamera)',
            icon: const Icon(Icons.add_a_photo_outlined),
            onPressed: _changePhoto,
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
            child: SegmentedButton<_Fmt>(
              segments: [
                for (final f in _Fmt.values)
                  ButtonSegment(value: f, label: Text(f.label)),
              ],
              selected: {_fmt},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() => _fmt = s.first),
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
                      width: size.width,
                      height: size.height,
                      child: graphic,
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
                      : const Icon(Icons.ios_share),
                  label: Text(
                    _fmt == _Fmt.urkunde ? 'Urkunde teilen/drucken' : 'Teilen',
                  ),
                ),
              ),
            ),
          ),
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
    return Container(
      width: diameter,
      height: diameter,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: _greenDark,
        border: Border.all(color: _gold, width: 4),
        image: bytes != null
            ? DecorationImage(
                image: MemoryImage(bytes),
                fit: BoxFit.cover,
                // Glättet das Hochskalieren kleiner FuPa-Fotos im Export.
                filterQuality: FilterQuality.high,
              )
            : null,
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
          : null,
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
          label.toUpperCase(),
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
class _SocialGraphic extends StatelessWidget {
  const _SocialGraphic({
    required this.player,
    required this.teamName,
    required this.teamLogo,
    required this.occasion,
    required this.subtitle,
    required this.avg,
    required this.ratedCount,
    required this.month,
    required this.total,
    required this.fupa,
    required this.fupaClub,
    required this.barSponsors,
    required this.gradTop,
    required this.gradBottom,
    required this.bgImage,
    required this.overlayOpacity,
    required this.showRating,
    required this.showMonth,
    required this.showTotal,
    required this.showFupa,
    required this.showFupaClub,
    required this.compact,
  });

  final Player player;
  final String teamName;
  final String? teamLogo;
  final String occasion;
  final String subtitle;
  final double? avg;
  final int ratedCount;
  final PlayerMonthStats month;
  final PlayerMonthStats total;
  final PlayerStat? fupa;
  final FupaClubTotal? fupaClub;
  final List<Sponsor> barSponsors;
  final Color gradTop;
  final Color gradBottom;
  final String? bgImage;
  final double overlayOpacity; // 0..1
  final bool showRating;
  final bool showMonth;
  final bool showTotal;
  final bool showFupa;
  final bool showFupaClub;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final pad = compact ? 18.0 : 22.0;
    final photo = compact ? 120.0 : 168.0;
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
                        _PhotoRing(player: player, diameter: photo),
                        const SizedBox(height: 12),
                        Text(
                          player.fullName.toUpperCase(),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 26,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.5,
                            height: 1.05,
                          ),
                        ),
                        if ((player.position ?? '').isNotEmpty ||
                            player.number != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            [
                              if (player.number != null) '#${player.number}',
                              if ((player.position ?? '').isNotEmpty)
                                player.position!,
                            ].join('  ·  ').toUpperCase(),
                            style: const TextStyle(
                              color: _gold,
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1,
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                        if (avg != null && showRating) _noteBadge(),
                        const SizedBox(height: 14),
                        _statRow(),
                      ],
                    ),
                  ),
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

  Widget _header() {
    return Column(
      children: [
        Row(
          children: [
            if (teamLogo != null) ...[
              TeamLogo(logoPath: teamLogo, size: compact ? 30 : 38),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Text(
                teamName.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.9),
                  fontSize: compact ? 12 : 14,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            children: [
              Text(
                occasion.toUpperCase(),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _gold,
                  fontSize: compact ? 22 : 26,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.5,
                  height: 1.0,
                ),
              ),
              if (subtitle.trim().isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle.toUpperCase(),
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.85),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 2,
                  ),
                ),
              ],
            ],
          ),
        ),
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

  Widget _statRow() {
    final tiles = <Widget>[];
    void add(String v, String l) => tiles.add(_StatTile(value: v, label: l));
    final monthShown = showMonth && month.hasAny;
    if (monthShown) {
      add('${month.goals}', 'Tore M.');
      add('${month.assists}', 'Vorl. M.');
      if (month.redTotal > 0) add('${month.redTotal}', 'Rot M.');
      if (month.yellow > 0) add('${month.yellow}', 'Gelb M.');
    }
    final totalShown = showTotal && total.hasAny;
    if (totalShown) {
      add('${total.games}', 'Spiele G.');
      add('${total.goals}', 'Tore G.');
      add('${total.assists}', 'Vorl. G.');
    }
    final f = fupa;
    final fupaShown = showFupa && f != null;
    if (fupaShown) {
      add('${f.matches}', 'Spiele S.');
      add('${f.goals}', 'Tore S.');
      add('${f.assists}', 'Vorl. S.');
      add('${f.minutes}', 'Min. S.');
      if (f.topEleven > 0) add('${f.topEleven}', '⭐ Top11');
    }
    final fc = fupaClub;
    final clubShown = showFupaClub && fc != null && fc.hasAny;
    if (clubShown) {
      add('${fc.matches}', 'Spiele V.');
      add('${fc.goals}', 'Tore V.');
      add('${fc.assists}', 'Vorl. V.');
      add('${fc.scorerPoints}', 'Scorer V.');
    }
    if (tiles.isEmpty) return const SizedBox.shrink();
    final legend = [
      if (monthShown) 'M. = Monat',
      if (totalShown) 'G. = Gesamt',
      if (fupaShown) 'S. = Saison (FuPa)',
      if (clubShown)
        'V. = ${fc.clubName.isEmpty ? 'Verein' : fc.clubName} gesamt (FuPa)',
    ].join(' · ');
    return Column(
      children: [
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 22,
          runSpacing: 10,
          children: tiles,
        ),
        if (legend.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            legend,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 9,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
          ),
        ],
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
/// über eine FittedBox sicher in das A4-Format (kein Überlauf).
class _UrkundeGraphic extends StatelessWidget {
  const _UrkundeGraphic({
    required this.player,
    required this.teamName,
    required this.teamLogo,
    required this.occasion,
    required this.subtitle,
    required this.honorText,
    required this.avg,
    required this.ratedCount,
    required this.month,
    required this.total,
    required this.fupa,
    required this.fupaClub,
    required this.barSponsors,
    required this.showRating,
    required this.showMonth,
    required this.showTotal,
    required this.showFupa,
    required this.showFupaClub,
  });

  final Player player;
  final String teamName;
  final String? teamLogo;
  final String occasion;
  final String subtitle;
  final String honorText;
  final double? avg;
  final int ratedCount;
  final PlayerMonthStats month;
  final PlayerMonthStats total;
  final PlayerStat? fupa;
  final FupaClubTotal? fupaClub;
  final List<Sponsor> barSponsors;
  final bool showRating;
  final bool showMonth;
  final bool showTotal;
  final bool showFupa;
  final bool showFupaClub;

  static const _line = Color(0xFFE7E3D8);

  bool get _clubShown => showFupaClub && fupaClub != null && fupaClub!.hasAny;

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
              Container(height: 6, color: _gold), // moderner Akzent
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Kopf: Logo + Verein.
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (teamLogo != null) ...[
              TeamLogo(logoPath: teamLogo, size: 34),
              const SizedBox(width: 10),
            ],
            Flexible(
              child: Text(
                teamName.toUpperCase(),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _ink.withValues(alpha: 0.75),
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.5,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        // Eyebrow (Anlass) + kleines URKUNDE-Label.
        Text(
          occasion.toUpperCase(),
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: _gold,
            fontSize: 20,
            fontWeight: FontWeight.w900,
            letterSpacing: 3,
            height: 1.05,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          subtitle.trim().isEmpty
              ? 'URKUNDE'
              : 'URKUNDE · ${subtitle.toUpperCase()}',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: _ink.withValues(alpha: 0.55),
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 2,
          ),
        ),
        const SizedBox(height: 20),
        Center(child: _PhotoRing(player: player, diameter: 104)),
        const SizedBox(height: 14),
        Text(
          player.fullName,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: _ink,
            fontSize: 28,
            fontWeight: FontWeight.w900,
            height: 1.05,
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text(
            honorText,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _ink.withValues(alpha: 0.72),
              fontSize: 12.5,
              height: 1.45,
            ),
          ),
        ),
        if (showRating && avg != null) ...[
          const SizedBox(height: 14),
          Center(child: _notePill()),
        ],
        if (showMonth || showTotal || showFupa || _clubShown) ...[
          const SizedBox(height: 16),
          _statsBlock(),
        ],
        if (barSponsors.isNotEmpty) ...[
          const SizedBox(height: 18),
          _sponsorBar(),
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
    final f = fupa;
    Widget col(String title, List<(String, String)> rows) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
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
                    r.$1,
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

    final monthRows = <(String, String)>[
      ('Spiele', '${month.games}'),
      ('Tore', '${month.goals}'),
      ('Vorlagen', '${month.assists}'),
      if (month.yellow > 0) ('Gelbe Karten', '${month.yellow}'),
      if (month.redTotal > 0) ('Rote Karten', '${month.redTotal}'),
    ];
    final totalRows = <(String, String)>[
      ('Spiele', '${total.games}'),
      ('Tore', '${total.goals}'),
      ('Vorlagen', '${total.assists}'),
      if (total.yellow > 0) ('Gelbe Karten', '${total.yellow}'),
      if (total.redTotal > 0) ('Rote Karten', '${total.redTotal}'),
    ];
    final seasonRows = <(String, String)>[
      ('Spiele', '${f?.matches ?? 0}'),
      ('Tore', '${f?.goals ?? 0}'),
      ('Vorlagen', '${f?.assists ?? 0}'),
      ('Scorerpunkte', '${f?.scorerPoints ?? 0}'),
      ('Minuten', '${f?.minutes ?? 0}'),
      if ((f?.yellowCards ?? 0) > 0) ('Gelbe', '${f!.yellowCards}'),
      if ((f?.yellowRedCards ?? 0) > 0) ('Gelb-Rot', '${f!.yellowRedCards}'),
      if ((f?.redCards ?? 0) > 0) ('Rote', '${f!.redCards}'),
      if ((f?.topEleven ?? 0) > 0) ('⭐ Top11', '${f!.topEleven}'),
    ];

    final fc = fupaClub;
    final clubRows = <(String, String)>[
      ('Spiele', '${fc?.matches ?? 0}'),
      ('Tore', '${fc?.goals ?? 0}'),
      ('Vorlagen', '${fc?.assists ?? 0}'),
      ('Scorerpunkte', '${fc?.scorerPoints ?? 0}'),
    ];

    // Nur die aktivierten Quellen – Spalten nebeneinander.
    final cols = <Widget>[
      if (showMonth) col('Dieser Monat', monthRows),
      if (showTotal) col('Gesamt', totalRows),
      if (showFupa) col('Saison (FuPa)', seasonRows),
      if (_clubShown)
        col(
          '${fc!.clubName.isEmpty ? 'Verein' : fc.clubName} gesamt',
          clubRows,
        ),
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
          'MIT FREUNDLICHER UNTERSTÜTZUNG',
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
