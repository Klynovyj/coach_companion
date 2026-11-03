import 'dart:typed_data';

import 'package:crop_your_image/crop_your_image.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

/// Einfacher Foto-Editor (wie der Android-Editor): zuschneiden, drehen,
/// Helligkeit und Kontrast (Live-Vorschau). Gibt die bearbeiteten Bytes zurück
/// (JPEG), oder null bei Abbruch.
class PhotoEditorScreen extends StatefulWidget {
  const PhotoEditorScreen({
    super.key,
    required this.imageBytes,
    this.aspectRatio,
    this.maxSize = 1600,
    this.keepAlpha = false,
  });

  final Uint8List imageBytes;

  /// Fester Seitenverhältnis-Rahmen; null = frei.
  final double? aspectRatio;

  /// Längste Kante im Ergebnis (zum Begrenzen der Dateigröße).
  final int maxSize;

  /// Transparenz erhalten → Ergebnis als PNG (statt JPEG). Für freigestellte
  /// Spielerbilder, damit der Hintergrund dahinter durchscheint.
  final bool keepAlpha;

  @override
  State<PhotoEditorScreen> createState() => _PhotoEditorScreenState();
}

class _PhotoEditorScreenState extends State<PhotoEditorScreen> {
  final _controller = CropController();
  late Uint8List _bytes = widget.imageBytes;
  int _rotation = 0; // nur für den Crop-Key beim Drehen
  double _brightness = 0; // -100..100
  double _contrast = 0; // -100..100
  bool _busy = false;
  // Zuschneider erst bereit, wenn das Bild dekodiert/angelegt ist. Vorher
  // schlägt ein crop() fehl („Zuschnitt fehlgeschlagen") – daher „Übernehmen"
  // bis dahin sperren.
  bool _ready = false;

  /// Farbmatrix für die Live-Vorschau (Helligkeit = Offset, Kontrast = Skalierung
  /// um 128). Entspricht ungefähr dem späteren Einrechnen.
  List<double> _previewMatrix() {
    final c = 1 + (_contrast / 100) * 0.8; // 0.2 .. 1.8
    final b = (_brightness / 100) * 80; // -80 .. 80 (Offset in 0..255)
    final t = 128 * (1 - c) + b;
    return [c, 0, 0, 0, t, 0, c, 0, 0, t, 0, 0, c, 0, t, 0, 0, 0, 1, 0];
  }

  Future<void> _rotate() async {
    setState(() => _busy = true);
    try {
      final decoded = img.decodeImage(_bytes);
      if (decoded != null) {
        final rotated = img.copyRotate(decoded, angle: 90);
        _bytes = Uint8List.fromList(
          widget.keepAlpha
              ? img.encodePng(rotated)
              : img.encodeJpg(rotated, quality: 92),
        );
        _rotation++;
        _ready = false; // neuer Crop-Key → wieder warten, bis bereit
      }
    } catch (_) {
      // Drehen fehlgeschlagen – Bild bleibt wie es war.
    }
    if (mounted) setState(() => _busy = false);
  }

  void _onCropped(CropResult result) {
    switch (result) {
      case CropSuccess(:final croppedImage):
        _finishWith(croppedImage, cropped: true);
      case CropFailure():
        // Der Zuschnitt im Paket kann bei manchen Bildern fehlschlagen. Statt
        // den Nutzer mit „Zuschnitt fehlgeschlagen" stehen zu lassen, nehmen wir
        // das ganze (angepasste) Bild – „Übernehmen" liefert also immer etwas.
        _finishWith(_bytes, cropped: false);
    }
  }

  /// Wendet Helligkeit/Kontrast an, begrenzt die Größe und gibt das Bild zurück.
  /// [cropped]=false (Fallback) → kurzer Hinweis, dass nicht zugeschnitten wurde.
  void _finishWith(Uint8List bytes, {required bool cropped}) {
    Uint8List out = bytes;
    try {
      var im = img.decodeImage(bytes);
      if (im != null) {
        if (_brightness != 0 || _contrast != 0) {
          im = img.adjustColor(
            im,
            brightness: 1 + (_brightness / 100) * 0.6,
            contrast: 1 + (_contrast / 100) * 0.6,
          );
        }
        final longer = im.width >= im.height ? im.width : im.height;
        if (longer > widget.maxSize) {
          im = im.width >= im.height
              ? img.copyResize(im, width: widget.maxSize)
              : img.copyResize(im, height: widget.maxSize);
        }
        out = Uint8List.fromList(
          widget.keepAlpha ? img.encodePng(im) : img.encodeJpg(im, quality: 85),
        );
      }
    } catch (_) {
      // Nachbearbeitung fehlgeschlagen → Bild unverändert übernehmen.
    }
    if (!mounted) return;
    if (!cropped) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Zuschnitt nicht möglich – ganzes Bild übernommen.'),
          duration: Duration(seconds: 2),
        ),
      );
    }
    Navigator.pop(context, out);
  }

  Widget _sliderRow(
    IconData icon,
    String label,
    double value,
    ValueChanged<double> onChanged,
  ) {
    return Row(
      children: [
        Icon(icon, color: Colors.white70, size: 20),
        const SizedBox(width: 6),
        SizedBox(
          width: 78,
          child: Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
        ),
        Expanded(
          child: Slider(
            value: value,
            min: -100,
            max: 100,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 34,
          child: Text(
            value.round().toString(),
            textAlign: TextAlign.right,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Foto bearbeiten'),
        actions: [
          IconButton(
            tooltip: 'Drehen',
            icon: const Icon(Icons.rotate_right),
            onPressed: _busy ? null : _rotate,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: FilledButton.icon(
              onPressed: (_busy || !_ready)
                  ? null
                  : () {
                      setState(() => _busy = true);
                      _controller.crop();
                    },
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.check, size: 18),
              label: Text(_ready ? 'Übernehmen' : 'Lädt …'),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ColorFiltered(
              colorFilter: ColorFilter.matrix(_previewMatrix()),
              child: Crop(
                key: ValueKey(_rotation),
                image: _bytes,
                controller: _controller,
                aspectRatio: widget.aspectRatio,
                initialRectBuilder: InitialRectBuilder.withBuilder((
                  viewport,
                  _,
                ) {
                  final inset = viewport.shortestSide * 0.08;
                  return Rect.fromLTRB(
                    viewport.left + inset,
                    viewport.top + inset,
                    viewport.right - inset,
                    viewport.bottom - inset,
                  );
                }),
                baseColor: Colors.black,
                maskColor: Colors.black.withValues(alpha: 0.6),
                onStatusChanged: (status) {
                  final ready = status == CropStatus.ready;
                  if (ready != _ready && mounted) {
                    setState(() => _ready = ready);
                  }
                },
                onCropped: _onCropped,
              ),
            ),
          ),
          Container(
            color: Colors.black,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _sliderRow(
                    Icons.brightness_6,
                    'Helligkeit',
                    _brightness,
                    (v) => setState(() => _brightness = v),
                  ),
                  _sliderRow(
                    Icons.contrast,
                    'Kontrast',
                    _contrast,
                    (v) => setState(() => _contrast = v),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: (_brightness == 0 && _contrast == 0)
                          ? null
                          : () => setState(() {
                              _brightness = 0;
                              _contrast = 0;
                            }),
                      child: const Text('Zurücksetzen'),
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
