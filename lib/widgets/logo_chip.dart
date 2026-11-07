import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/logo_tools.dart';

/// Logo in einem kleinen Feld für die Grafiken (leichter Schlagschatten).
/// [mode]: 'auto' = Weiß, bei hellen/goldenen Logos automatisch dunkel (weißer
/// Bildgrund wird dann transparent); 'white'; 'dark'; 'none' = ohne Feld.
class LogoChip extends StatelessWidget {
  const LogoChip({
    super.key,
    required this.bytes,
    required this.height,
    this.circle = false,
    this.mode = 'auto',
  });

  final Uint8List bytes;
  final double height;
  final bool circle;
  final String mode;

  @override
  Widget build(BuildContext context) {
    var image = bytes;
    var dark = mode == 'dark';
    if (mode == 'auto') {
      final fix = logoContrastFix(bytes);
      dark = fix.dark;
      image = fix.bytes;
    }
    final img = Image.memory(image, fit: BoxFit.contain, gaplessPlayback: true);
    if (mode == 'none') {
      // Frei auf dem Hintergrund (am besten mit transparentem Logo).
      return SizedBox(
        height: height,
        width: circle ? height : null,
        child: Padding(padding: const EdgeInsets.all(2), child: img),
      );
    }
    final shadow = [
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.55),
        blurRadius: 12,
        offset: const Offset(0, 5),
      ),
    ];
    final deco = BoxDecoration(
      color: dark ? const Color(0xFF121212) : Colors.white,
      shape: circle ? BoxShape.circle : BoxShape.rectangle,
      borderRadius: circle ? null : BorderRadius.circular(6),
      boxShadow: shadow,
      border: dark
          ? Border.all(color: Colors.white.withValues(alpha: 0.35), width: 1)
          : (circle
                ? null
                : Border.all(
                    color: Colors.white.withValues(alpha: 0.9),
                    width: 0.5,
                  )),
    );
    if (circle) {
      return Container(
        width: height,
        height: height,
        padding: const EdgeInsets.all(6),
        clipBehavior: Clip.antiAlias,
        decoration: deco,
        child: img,
      );
    }
    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: deco,
      child: img,
    );
  }
}
