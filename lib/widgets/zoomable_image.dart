import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Vollbild-Ansicht eines Bildes: zoomen mit zwei Fingern, Mausrad oder den
/// Knöpfen − / +, verschieben per Ziehen.
class ZoomableImagePage extends StatefulWidget {
  const ZoomableImagePage({
    super.key,
    required this.bytes,
    required this.title,
    this.actions = const [],
  });

  final Uint8List bytes;
  final String title;
  final List<Widget> actions;

  @override
  State<ZoomableImagePage> createState() => _ZoomableImagePageState();
}

class _ZoomableImagePageState extends State<ZoomableImagePage> {
  final _ctrl = TransformationController();
  Size _viewport = Size.zero;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// Um die Bildschirmmitte zoomen (Faktor [f]); 0 = zurück auf ganzes Bild.
  void _zoom(double f) {
    if (f == 0) {
      _ctrl.value = Matrix4.identity();
      return;
    }
    final cur = _ctrl.value.getMaxScaleOnAxis();
    final next = (cur * f).clamp(1.0, 8.0);
    final k = next / cur;
    final c = _viewport.center(Offset.zero);
    // Neue Matrix: um c skalieren (T(c)·S(k)·T(−c)·M).
    final m = Matrix4.identity()
      ..translateByDouble(c.dx, c.dy, 0, 1)
      ..scaleByDouble(k, k, 1, 1)
      ..translateByDouble(-c.dx, -c.dy, 0, 1);
    _ctrl.value = m * _ctrl.value;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: 'Auszoomen',
            icon: const Icon(Icons.zoom_out),
            onPressed: () => _zoom(1 / 1.4),
          ),
          IconButton(
            tooltip: 'Einzoomen',
            icon: const Icon(Icons.zoom_in),
            onPressed: () => _zoom(1.4),
          ),
          IconButton(
            tooltip: 'Ganzes Bild',
            icon: const Icon(Icons.fit_screen),
            onPressed: () => _zoom(0),
          ),
          ...widget.actions,
        ],
      ),
      body: LayoutBuilder(
        builder: (ctx, c) {
          _viewport = Size(c.maxWidth, c.maxHeight);
          return InteractiveViewer(
            transformationController: _ctrl,
            maxScale: 8,
            child: Center(
              child: Image.memory(widget.bytes, fit: BoxFit.contain),
            ),
          );
        },
      ),
    );
  }
}
