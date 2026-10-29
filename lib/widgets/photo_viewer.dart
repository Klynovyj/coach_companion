import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Zeigt ein Bild formatfüllend mit Zoom/Schwenk und Schließen-Knopf.
Future<void> showPhotoFullscreen(BuildContext context, Uint8List bytes) {
  return Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.black,
      pageBuilder: (_, _, _) => _PhotoViewerPage(bytes: bytes),
    ),
  );
}

class _PhotoViewerPage extends StatelessWidget {
  const _PhotoViewerPage({required this.bytes});

  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              minScale: 1,
              maxScale: 5,
              child: Center(child: Image.memory(bytes, fit: BoxFit.contain)),
            ),
          ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            right: 8,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white, size: 28),
              onPressed: () => Navigator.pop(context),
            ),
          ),
        ],
      ),
    );
  }
}
