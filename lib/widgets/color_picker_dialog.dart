import 'package:flutter/material.dart';

import 'text_look.dart' show hexColor;

String colorToHex(Color c) =>
    '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

/// Freie Farbwahl (Farbton, Sättigung, Helligkeit). Liefert Hex (#RRGGBB)
/// oder null bei Abbruch.
Future<String?> showHsvColorPicker(BuildContext context, String initialHex) {
  var hsv = HSVColor.fromColor(hexColor(initialHex));
  Widget slider(
    String label,
    double value,
    double max,
    ValueChanged<double> onChanged,
  ) => Row(
    children: [
      SizedBox(width: 86, child: Text(label)),
      Expanded(
        child: Slider(value: value, min: 0, max: max, onChanged: onChanged),
      ),
    ],
  );
  return showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        final color = hsv.toColor();
        return AlertDialog(
          title: const Text('Farbe wählen'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  height: 44,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.black26),
                  ),
                ),
                const SizedBox(height: 8),
                slider(
                  'Farbton',
                  hsv.hue,
                  360,
                  (v) => setLocal(() => hsv = hsv.withHue(v)),
                ),
                slider(
                  'Sättigung',
                  hsv.saturation,
                  1,
                  (v) => setLocal(() => hsv = hsv.withSaturation(v)),
                ),
                slider(
                  'Helligkeit',
                  hsv.value,
                  1,
                  (v) => setLocal(() => hsv = hsv.withValue(v)),
                ),
                Text(colorToHex(color)),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, colorToHex(color)),
              child: const Text('Übernehmen'),
            ),
          ],
        );
      },
    ),
  );
}
