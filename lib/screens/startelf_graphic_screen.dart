import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../models/sponsor.dart';
import '../services/share_service.dart';
import '../state/app_state.dart';
import '../widgets/team_logo.dart';

/// Ein Spieler in der Startelf-Grafik (Nummer + Anzeigename).
class StartelfPlayer {
  final int? number;
  final String name;
  const StartelfPlayer(this.number, this.name);
}

/// Erzeugt die teilbare Startelf-Grafik im Instagram-Format (Story 9:16 oder
/// Post 1:1). Sponsoren (Haupt-Sponsor „Präsentiert von …" + Logo-Leiste)
/// kommen aus der Sponsoring-Verwaltung und werden automatisch eingeblendet.
class StartelfGraphicScreen extends StatefulWidget {
  const StartelfGraphicScreen({
    super.key,
    required this.teamName,
    required this.teamLogo,
    required this.starters,
    required this.benchNames,
  });

  final String teamName;
  final String? teamLogo;
  final List<StartelfPlayer> starters;
  final List<String> benchNames;

  @override
  State<StartelfGraphicScreen> createState() => _StartelfGraphicScreenState();
}

class _StartelfGraphicScreenState extends State<StartelfGraphicScreen> {
  static const _bgSettingKey = 'startelf_bg';

  final GlobalKey _boundaryKey = GlobalKey();
  bool _story = true; // true = Story 9:16, false = Post 1:1
  List<Sponsor> _sponsors = [];
  String? _bg; // Hintergrundfoto (Data-URL), lokal gemerkt
  bool _useBg = true; // Foto verwenden, wenn vorhanden
  bool _loading = true;
  bool _sharing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    final sponsors = await state.sponsors();
    final bg = await state.repository.getSetting(_bgSettingKey);
    if (!mounted) return;
    setState(() {
      _sponsors = sponsors;
      _bg = bg;
      _useBg = bg != null;
      _loading = false;
    });
  }

  Future<void> _pickBg() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final file = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 85,
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      final dataUrl = 'data:image/jpeg;base64,${base64Encode(bytes)}';
      if (!mounted) return;
      await context.read<AppState>().repository.setSetting(_bgSettingKey, dataUrl);
      setState(() {
        _bg = dataUrl;
        _useBg = true;
      });
    } catch (e) {
      messenger
          .showSnackBar(SnackBar(content: Text('Bild konnte nicht geladen werden: $e')));
    }
  }

  Future<void> _removeBg() async {
    await context.read<AppState>().repository.setSetting(_bgSettingKey, null);
    if (!mounted) return;
    setState(() {
      _bg = null;
      _useBg = false;
    });
  }

  Future<void> _share() async {
    if (_sharing) return;
    setState(() => _sharing = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final boundary =
          _boundaryKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return;
      final logicalWidth = _story ? _storyW : _postW;
      // Exakt 1080 px breit → Story 1080×1920, Post 1080×1080.
      final image = await boundary.toImage(pixelRatio: 1080 / logicalWidth);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return;
      final savedPath = await shareOrSaveImage(
        data.buffer.asUint8List(),
        'Startelf_${widget.teamName}',
        text: 'Startelf – ${widget.teamName}',
      );
      if (savedPath != null && mounted) {
        messenger.showSnackBar(SnackBar(
          content: Text('Als Bild gespeichert und geöffnet:\n$savedPath'),
          duration: const Duration(seconds: 6),
        ));
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Teilen fehlgeschlagen: $e')));
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  // Logische Zeichengrößen (× pixelRatio 3 = 1080×1920 bzw. 1080×1080).
  static const double _storyW = 360, _storyH = 640;
  static const double _postW = 360, _postH = 360;

  Sponsor? get _mainSponsor {
    for (final s in _sponsors) {
      if (s.isMain) return s;
    }
    return null;
  }

  List<Sponsor> get _barSponsors =>
      _sponsors.where((s) => !s.isMain && s.logo != null).toList();

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final w = _story ? _storyW : _postW;
    final h = _story ? _storyH : _postH;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Startelf-Grafik'),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.image_outlined),
            tooltip: 'Hintergrund',
            onSelected: (v) {
              if (v == 'pick') _pickBg();
              if (v == 'remove') _removeBg();
              if (v == 'gradient') setState(() => _useBg = false);
              if (v == 'photo') setState(() => _useBg = true);
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'pick', child: Text('Hintergrundbild wählen')),
              if (_bg != null)
                PopupMenuItem(
                    value: _useBg ? 'gradient' : 'photo',
                    child: Text(_useBg ? 'Farbverlauf verwenden' : 'Foto verwenden')),
              if (_bg != null)
                const PopupMenuItem(value: 'remove', child: Text('Hintergrundbild entfernen')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // Format-Umschalter.
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
                        teamName: widget.teamName,
                        teamLogo: widget.teamLogo,
                        starters: widget.starters,
                        benchNames: widget.benchNames,
                        mainSponsor: _mainSponsor,
                        barSponsors: _barSponsors,
                        background: _useBg ? _bg : null,
                        compact: !_story,
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
                          child: CircularProgressIndicator(strokeWidth: 2))
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

/// Die eigentliche Grafik in fester logischer Größe (wird per RepaintBoundary
/// in ein PNG exportiert).
class _StartelfGraphic extends StatelessWidget {
  const _StartelfGraphic({
    required this.teamName,
    required this.teamLogo,
    required this.starters,
    required this.benchNames,
    required this.mainSponsor,
    required this.barSponsors,
    required this.background,
    required this.compact,
  });

  final String teamName;
  final String? teamLogo;
  final List<StartelfPlayer> starters;
  final List<String> benchNames;
  final Sponsor? mainSponsor;
  final List<Sponsor> barSponsors;
  final String? background; // Data-URL oder null (Farbverlauf)
  final bool compact;

  static const _green1 = Color(0xFF0E3325);
  static const _green2 = Color(0xFF15603F);

  @override
  Widget build(BuildContext context) {
    final bgBytes = TeamLogo.decode(background);
    final pad = compact ? 16.0 : 20.0;
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_green1, _green2],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (bgBytes != null) ...[
            Image.memory(bgBytes, fit: BoxFit.cover, gaplessPlayback: true),
            // Abdunkeln, damit die weiße Schrift lesbar bleibt.
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xE60E3325), Color(0xF215603F)],
                ),
              ),
            ),
          ],
          Padding(
            padding: EdgeInsets.fromLTRB(pad, pad, pad, pad),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(),
                if (mainSponsor != null) ...[
                  SizedBox(height: compact ? 8 : 12),
                  _presentedBy(mainSponsor!),
                ],
                SizedBox(height: compact ? 8 : 14),
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
      ),
    );
  }

  Widget _header() {
    return Row(
      children: [
        if (teamLogo != null) ...[
          TeamLogo(logoPath: teamLogo, size: compact ? 34 : 44),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                teamName.toUpperCase(),
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
                'STARTELF',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: compact ? 26 : 32,
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
      mainAxisAlignment: MainAxisAlignment.start,
      children: [
        Text('PRÄSENTIERT VON',
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.8),
                fontSize: compact ? 9 : 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 1)),
        const SizedBox(width: 8),
        if (logoBytes != null)
          _logoChip(logoBytes, height: compact ? 24 : 30)
        else
          Text(s.name,
              style: TextStyle(
                  color: Colors.white,
                  fontSize: compact ? 13 : 15,
                  fontWeight: FontWeight.bold)),
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
      fontSize: 22,
      fontWeight: FontWeight.w800,
      letterSpacing: 0.5,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final p in starters)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                SizedBox(
                    width: 38,
                    child: Text(p.number?.toString() ?? '', style: numStyle)),
                const SizedBox(width: 10),
                Text(p.name.toUpperCase(), style: nameStyle),
              ],
            ),
          ),
        if (benchNames.isNotEmpty) ...[
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('BANK',
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.9),
                      fontSize: 15,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1)),
              const SizedBox(width: 12),
              SizedBox(
                width: 260,
                child: Text(
                  benchNames.map((n) => n.toUpperCase()).join(', '),
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.92),
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      height: 1.3),
                ),
              ),
            ],
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
              _logoChip(TeamLogo.decode(s.logo)!, height: compact ? 26 : 32),
        ],
      ),
    );
  }

  // Logo auf weißem Chip (viele Logos sind transparent und wären auf dunklem
  // Grund unsichtbar).
  Widget _logoChip(Uint8List bytes, {required double height}) {
    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Image.memory(
        bytes,
        fit: BoxFit.contain,
        gaplessPlayback: true,
      ),
    );
  }
}
