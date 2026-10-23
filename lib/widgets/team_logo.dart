import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Zeigt ein Vereinslogo aus einer Data-URL (image/png o.ä.). Fehlt das Logo
/// oder ist es ungültig, wird ein Wappen-Platzhalter angezeigt.
class TeamLogo extends StatelessWidget {
  const TeamLogo({super.key, required this.logoPath, this.size = 40});

  final String? logoPath;
  final double size;

  static Uint8List? decode(String? dataUrl) {
    if (dataUrl == null) return null;
    final idx = dataUrl.indexOf('base64,');
    if (idx < 0) return null;
    try {
      return base64Decode(dataUrl.substring(idx + 7));
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = decode(logoPath);
    if (bytes == null) {
      return Icon(Icons.shield_outlined, size: size, color: Colors.grey);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.memory(
        bytes,
        width: size,
        height: size,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) =>
            Icon(Icons.shield_outlined, size: size, color: Colors.grey),
      ),
    );
  }
}
