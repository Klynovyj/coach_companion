import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Zoom-Knöpfe (− / +) über einem Zuschneide-Editor (`Crop` mit
/// `interactive: true`). Das Paket hat keine Zoom-Schnittstelle – die Knöpfe
/// lösen daher Mausrad-Schritte in der Mitte des Editors aus (wie am PC).
class CropZoomOverlay extends StatefulWidget {
  const CropZoomOverlay({super.key, required this.child});

  /// Der `Crop`-Editor (interactive).
  final Widget child;

  @override
  State<CropZoomOverlay> createState() => _CropZoomOverlayState();
}

class _CropZoomOverlayState extends State<CropZoomOverlay> {
  final _key = GlobalKey();

  void _zoom(bool zoomIn) {
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final c = box.localToGlobal(box.size.center(Offset.zero));
    final view = View.of(context);
    for (var i = 0; i < 2; i++) {
      GestureBinding.instance.handlePointerEvent(
        PointerScrollEvent(
          viewId: view.viewId,
          kind: PointerDeviceKind.mouse,
          position: c,
          scrollDelta: Offset(0, zoomIn ? -40 : 40),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: KeyedSubtree(key: _key, child: widget.child),
        ),
        // Rechts in der Mitte – oben/unten liegen die Eck-Griffe des Rahmens.
        Positioned(
          right: 4,
          top: 0,
          bottom: 0,
          child: Center(
            child: Material(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Einzoomen',
                    color: Colors.white,
                    icon: const Icon(Icons.zoom_in),
                    onPressed: () => _zoom(true),
                  ),
                  IconButton(
                    tooltip: 'Auszoomen',
                    color: Colors.white,
                    icon: const Icon(Icons.zoom_out),
                    onPressed: () => _zoom(false),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
