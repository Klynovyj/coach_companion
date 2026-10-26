import 'dart:typed_data';

import 'package:crop_your_image/crop_your_image.dart';
import 'package:flutter/material.dart';

/// Vollbild-Zuschnitt (quadratisch) für Spielerfotos. Der/die Nutzer:in rahmt
/// das Bild (Auswahlrahmen ziehen) und bestätigt mit „Übernehmen". Gibt die
/// zugeschnittenen Bytes zurück, oder null bei Abbruch.
class PhotoCropScreen extends StatefulWidget {
  const PhotoCropScreen({super.key, required this.imageBytes});

  final Uint8List imageBytes;

  @override
  State<PhotoCropScreen> createState() => _PhotoCropScreenState();
}

class _PhotoCropScreenState extends State<PhotoCropScreen> {
  final _controller = CropController();
  bool _cropping = false;

  void _onCropped(CropResult result) {
    switch (result) {
      case CropSuccess(:final croppedImage):
        if (mounted) Navigator.of(context).pop(croppedImage);
      case CropFailure():
        if (!mounted) return;
        setState(() => _cropping = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Zuschnitt fehlgeschlagen.')),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Foto zuschneiden'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: FilledButton.icon(
              onPressed: _cropping
                  ? null
                  : () {
                      setState(() => _cropping = true);
                      _controller.crop();
                    },
              icon: const Icon(Icons.check, size: 18),
              label: const Text('Übernehmen'),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Crop(
              image: widget.imageBytes,
              controller: _controller,
              aspectRatio: 1,
              // Start-Rahmen etwas eingerückt, damit die Eck-Punkte nicht am
              // Bildrand kleben und sich greifen lassen.
              initialRectBuilder: InitialRectBuilder.withBuilder((viewport, _) {
                final inset = viewport.shortestSide * 0.1;
                final side = viewport.shortestSide - inset * 2;
                return Rect.fromCenter(
                  center: viewport.center,
                  width: side,
                  height: side,
                );
              }),
              baseColor: Colors.black,
              maskColor: Colors.black.withValues(alpha: 0.6),
              onCropped: _onCropped,
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 10, 16, 16),
            child: Text(
              'Rahmen ziehen bzw. Ecken anpassen – das Foto wird quadratisch '
              'zugeschnitten. Dann „Übernehmen".',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
