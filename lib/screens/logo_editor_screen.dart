import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/logo_tools.dart';
import '../widgets/logo_chip.dart';
import 'photo_crop_screen.dart';

/// Ergebnis des Logo-Editors: bearbeitetes Logo (PNG) + Feld auf Grafiken.
typedef LogoEditResult = ({Uint8List bytes, String chip});

Uint8List _edgeWhite(Uint8List b) => removeWhiteBackground(b);
Uint8List _allWhite(Uint8List b) => removeWhiteBackground(b, everywhere: true);
Uint8List _trim(Uint8List b) => trimLogo(b);
Uint8List _normalize(Uint8List b) => normalizeLogoPng(b);

/// Logo-Editor (z. B. für Sponsoren): frei zuschneiden, drehen, leere Ränder
/// entfernen, weißen Hintergrund ausstanzen und festlegen, auf welchem Feld
/// das Logo in den Grafiken steht – mit Live-Vorschau.
class LogoEditorScreen extends StatefulWidget {
  const LogoEditorScreen({
    super.key,
    required this.imageBytes,
    this.chip = 'auto',
    this.name = '',
  });

  final Uint8List imageBytes;
  final String chip;
  final String name;

  @override
  State<LogoEditorScreen> createState() => _LogoEditorScreenState();
}

class _LogoEditorScreenState extends State<LogoEditorScreen> {
  final List<Uint8List> _history = [];
  Uint8List? _original;
  late String _chip = widget.chip;
  bool _busy = true;
  String? _busyText = 'Logo wird geladen …';
  Size? _size;

  Uint8List? get _current => _history.isEmpty ? null : _history.last;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final png = await compute(_normalize, widget.imageBytes);
    if (!mounted) return;
    _original = png;
    _push(png);
  }

  Future<void> _push(Uint8List b) async {
    final s = await _measure(b);
    if (!mounted) return;
    setState(() {
      _history.add(b);
      _size = s;
      _busy = false;
      _busyText = null;
    });
  }

  Future<Size?> _measure(Uint8List b) async {
    try {
      final codec = await ui.instantiateImageCodec(b);
      final f = await codec.getNextFrame();
      final s = Size(f.image.width.toDouble(), f.image.height.toDouble());
      f.image.dispose();
      return s;
    } catch (_) {
      return null;
    }
  }

  Future<void> _run(
    String text,
    ComputeCallback<Uint8List, Uint8List> op,
  ) async {
    final cur = _current;
    if (cur == null || _busy) return;
    setState(() {
      _busy = true;
      _busyText = text;
    });
    try {
      final out = await compute(op, cur);
      await _push(out);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _busyText = null;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Hat nicht geklappt: $e')));
    }
  }

  Future<void> _crop() async {
    final cur = _current;
    if (cur == null || _busy) return;
    final cropped = await Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(
        builder: (_) => PhotoCropScreen(
          imageBytes: cur,
          aspectRatio: null,
          title: 'Logo zuschneiden',
        ),
      ),
    );
    if (cropped == null || !mounted) return;
    setState(() {
      _busy = true;
      _busyText = 'Zuschnitt wird übernommen …';
    });
    await _push(await compute(_normalize, cropped));
  }

  void _undo() {
    if (_history.length <= 1) return;
    setState(() => _history.removeLast());
    _measure(_history.last).then((s) {
      if (mounted) setState(() => _size = s);
    });
  }

  void _resetOriginal() {
    final o = _original;
    if (o == null) return;
    _push(o);
  }

  @override
  Widget build(BuildContext context) {
    final cur = _current;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Logo bearbeiten'),
        actions: [
          IconButton(
            tooltip: 'Rückgängig',
            icon: const Icon(Icons.undo),
            onPressed: _history.length > 1 && !_busy ? _undo : null,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: FilledButton.icon(
              onPressed: cur == null || _busy
                  ? null
                  : () => Navigator.of(
                      context,
                    ).pop<LogoEditResult>((bytes: cur, chip: _chip)),
              icon: const Icon(Icons.check, size: 18),
              label: const Text('Übernehmen'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Großes Logo auf Schachbrett (zeigt Transparenz).
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                height: 240,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    const CustomPaint(painter: _CheckerPainter()),
                    if (cur != null)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Image.memory(
                          cur,
                          fit: BoxFit.contain,
                          gaplessPlayback: true,
                        ),
                      ),
                    if (_busy)
                      ColoredBox(
                        color: Colors.black.withValues(alpha: 0.35),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const CircularProgressIndicator(),
                              if (_busyText != null) ...[
                                const SizedBox(height: 10),
                                Text(
                                  _busyText!,
                                  style: const TextStyle(color: Colors.white),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (_size != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '${_size!.width.round()} × ${_size!.height.round()} px · '
                  'Karomuster = durchsichtig',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: Theme.of(context).hintColor,
                  ),
                ),
              ),
            const SizedBox(height: 16),
            _section(context, 'Werkzeuge'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _tool(Icons.crop, 'Zuschneiden', _crop),
                _tool(
                  Icons.rotate_right,
                  'Drehen',
                  () => _run('Wird gedreht …', rotateLogo90),
                ),
                _tool(
                  Icons.fit_screen,
                  'Ränder entfernen',
                  () => _run('Ränder werden entfernt …', _trim),
                ),
                _tool(
                  Icons.format_color_reset,
                  'Weiß am Rand entfernen',
                  () => _run('Hintergrund wird entfernt …', _edgeWhite),
                ),
                _tool(
                  Icons.invert_colors_off,
                  'Alles Weiß entfernen',
                  () => _run('Weiß wird entfernt …', _allWhite),
                ),
                _tool(
                  Icons.restore,
                  'Original',
                  _history.length > 1 ? _resetOriginal : null,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '„Weiß am Rand" stanzt nur den Hintergrund aus – weiße Schrift '
              'im Logo bleibt. „Alles Weiß" entfernt jedes Weiß.',
              style: TextStyle(
                fontSize: 11.5,
                color: Theme.of(context).hintColor,
              ),
            ),
            const SizedBox(height: 18),
            _section(context, 'Feld auf den Grafiken'),
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 'auto', label: Text('Auto')),
                ButtonSegment(value: 'white', label: Text('Weiß')),
                ButtonSegment(value: 'dark', label: Text('Dunkel')),
                ButtonSegment(value: 'none', label: Text('Ohne')),
              ],
              selected: {_chip},
              onSelectionChanged: (v) => setState(() => _chip = v.first),
            ),
            const SizedBox(height: 6),
            Text(
              _chip == 'auto'
                  ? 'Weiß – helle/goldene Logos automatisch auf dunklem Feld.'
                  : _chip == 'none'
                  ? 'Ohne Feld – am besten mit durchsichtigem Logo.'
                  : 'Immer ${_chip == 'white' ? 'weißes' : 'dunkles'} Feld.',
              style: TextStyle(
                fontSize: 11.5,
                color: Theme.of(context).hintColor,
              ),
            ),
            const SizedBox(height: 12),
            // Vorschau wie auf der Grafik (dunkelgrün + hell).
            Row(
              children: [
                Expanded(child: _preview(cur, dark: true)),
                const SizedBox(width: 10),
                Expanded(child: _preview(cur, dark: false)),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Vorschau auf dunklem und hellem Hintergrund',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: scheme.outline),
            ),
          ],
        ),
      ),
    );
  }

  Widget _preview(Uint8List? bytes, {required bool dark}) {
    return Container(
      height: 110,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: dark
              ? const [Color(0xFF0F2A1C), Color(0xFF1B5E3A)]
              : const [Color(0xFFE8ECEA), Color(0xFFC9D3CE)],
        ),
      ),
      alignment: Alignment.center,
      child: bytes == null
          ? null
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'PRÄSENTIERT VON',
                  style: TextStyle(
                    color: dark ? Colors.white : Colors.black87,
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.4,
                  ),
                ),
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 150),
                  child: LogoChip(bytes: bytes, height: 50, mode: _chip),
                ),
              ],
            ),
    );
  }

  Widget _section(BuildContext context, String t) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      t,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.bold,
      ),
    ),
  );

  Widget _tool(IconData icon, String label, VoidCallback? onTap) =>
      OutlinedButton.icon(
        onPressed: _busy || _current == null ? null : onTap,
        icon: Icon(icon, size: 18),
        label: Text(label),
      );
}

/// Schachbrett-Hintergrund (grau/weiß) für durchsichtige Bereiche.
class _CheckerPainter extends CustomPainter {
  const _CheckerPainter();

  @override
  void paint(Canvas canvas, Size size) {
    const cell = 12.0;
    final a = Paint()..color = const Color(0xFFFFFFFF);
    final b = Paint()..color = const Color(0xFFDADADA);
    canvas.drawRect(Offset.zero & size, a);
    for (var y = 0; y * cell < size.height; y++) {
      for (var x = 0; x * cell < size.width; x++) {
        if ((x + y).isOdd) {
          canvas.drawRect(Rect.fromLTWH(x * cell, y * cell, cell, cell), b);
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
