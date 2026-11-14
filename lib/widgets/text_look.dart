import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../screens/startelf_graphic_screen.dart' show posterFontStyle;

/// Schriftarten für Grafik-Texte (Schlüssel → Anzeigename).
const Map<String, String> kTextLookFonts = {
  'standard': 'Standard',
  'anton': 'Anton',
  'antonio': 'Antonio',
  'staat': 'Staatliches',
  'fjalla': 'Fjalla One',
  'oswald': 'Oswald',
  'barlow': 'Barlow Condensed',
  'archivo': 'Archivo',
  'bebas': 'Bebas Neue',
  'teko': 'Teko',
  'russo': 'Russo One',
};

/// Schatten-Arten (Schlüssel → Anzeigename).
const Map<String, String> kTextShadowKinds = {
  'none': 'Aus',
  'soft': 'Weich',
  'strong': 'Stark',
  'outline': 'Kontur',
  'glow': 'Leuchten',
};

/// Schatten für einen Text: Weich, Stark, Kontur (Umrandung) oder Leuchten
/// (Schein in [glow]). Größen relativ zur Schriftgröße [fs].
List<Shadow> textShadowsFor(String? kind, double fs, Color glow) =>
    switch (kind) {
      'soft' => [
        Shadow(
          color: Colors.black.withValues(alpha: 0.6),
          offset: Offset(0, fs * 0.06),
          blurRadius: fs * 0.25,
        ),
      ],
      'strong' => [
        Shadow(
          color: Colors.black.withValues(alpha: 0.9),
          offset: Offset(fs * 0.07, fs * 0.09),
          blurRadius: fs * 0.03,
        ),
        Shadow(
          color: Colors.black.withValues(alpha: 0.55),
          blurRadius: fs * 0.45,
        ),
      ],
      'outline' => [
        for (var a = 0; a < 360; a += 30)
          Shadow(
            color: Colors.black,
            offset: Offset(
              math.cos(a * math.pi / 180) * fs * 0.045,
              math.sin(a * math.pi / 180) * fs * 0.045,
            ),
          ),
      ],
      'glow' => [
        Shadow(color: glow.withValues(alpha: 0.95), blurRadius: fs * 0.3),
        Shadow(color: glow.withValues(alpha: 0.75), blurRadius: fs * 0.8),
      ],
      _ => const <Shadow>[],
    };

/// Gestaltung eines Grafik-Texts: Schrift, Farbe, Schatten, Ausrichtung.
/// `null` = Standard der jeweiligen Grafik.
class TextLook {
  const TextLook({this.font, this.color, this.shadow, this.align});

  final String? font;

  /// Farbe als Hex (#RRGGBB).
  final String? color;
  final String? shadow;

  /// left | center | right
  final String? align;

  bool get isDefault =>
      font == null && color == null && shadow == null && align == null;

  TextLook copyWith({
    Object? font = _unset,
    Object? color = _unset,
    Object? shadow = _unset,
    Object? align = _unset,
  }) => TextLook(
    font: identical(font, _unset) ? this.font : font as String?,
    color: identical(color, _unset) ? this.color : color as String?,
    shadow: identical(shadow, _unset) ? this.shadow : shadow as String?,
    align: identical(align, _unset) ? this.align : align as String?,
  );
  static const _unset = Object();

  /// Stil anwenden: [base] = Standard der Grafik, [glow] = Leuchtfarbe.
  TextStyle apply(TextStyle base, {Color glow = Colors.white}) {
    var s = base;
    final c = color;
    if (c != null) s = s.copyWith(color: hexColor(c));
    final f = font;
    if (f != null) s = posterFontStyle(f, s);
    final sh = shadow;
    if (sh != null && sh != 'none') {
      s = s.copyWith(
        shadows: [...?s.shadows, ...textShadowsFor(sh, s.fontSize ?? 16, glow)],
      );
    }
    return s;
  }

  TextAlign textAlign(TextAlign def) => switch (align) {
    'left' => TextAlign.left,
    'right' => TextAlign.right,
    'center' => TextAlign.center,
    _ => def,
  };

  CrossAxisAlignment crossAxis(CrossAxisAlignment def) => switch (align) {
    'left' => CrossAxisAlignment.start,
    'right' => CrossAxisAlignment.end,
    'center' => CrossAxisAlignment.center,
    _ => def,
  };

  Map<String, dynamic> toJson() => {
    if (font != null) 'font': font,
    if (color != null) 'color': color,
    if (shadow != null) 'shadow': shadow,
    if (align != null) 'align': align,
  };

  factory TextLook.fromJson(Map<String, dynamic> j) => TextLook(
    font: j['font'] as String?,
    color: j['color'] as String?,
    shadow: j['shadow'] as String?,
    align: j['align'] as String?,
  );

  static Map<String, TextLook> decodeMap(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final m = jsonDecode(raw);
      if (m is! Map) return {};
      return {
        for (final e in m.entries)
          if (e.value is Map)
            e.key.toString(): TextLook.fromJson(
              Map<String, dynamic>.from(e.value as Map),
            ),
      };
    } catch (_) {
      return {};
    }
  }

  static String encodeMap(Map<String, TextLook> m) => jsonEncode({
    for (final e in m.entries)
      if (!e.value.isDefault) e.key: e.value.toJson(),
  });
}

Color hexColor(String h) {
  var s = h.replaceAll('#', '').trim();
  if (s.length == 6) s = 'FF$s';
  return Color(int.tryParse(s, radix: 16) ?? 0xFFFFFFFF);
}

/// Blatt zum Gestalten eines Texts (Ausrichtung, Schrift, Farbe, Schatten).
/// [onChanged] wird bei jeder Änderung gerufen (Live-Vorschau dahinter).
Future<void> showTextLookSheet(
  BuildContext context, {
  required String title,
  required TextLook initial,
  required ValueChanged<TextLook> onChanged,
  List<(String, Color)> palette = const [],
  TextAlign defaultAlign = TextAlign.center,
}) {
  var look = initial;
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    barrierColor: Colors.black12,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) {
        void set(TextLook l) {
          setSheet(() => look = l);
          onChanged(l);
        }

        final scheme = Theme.of(ctx).colorScheme;
        final hint = Theme.of(ctx).hintColor;
        Widget section(String label, Widget child) => Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: hint,
                ),
              ),
              const SizedBox(height: 6),
              child,
            ],
          ),
        );
        Widget hScroll(List<Widget> kids) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final k in kids)
                Padding(padding: const EdgeInsets.only(right: 8), child: k),
            ],
          ),
        );

        final defAlign = switch (defaultAlign) {
          TextAlign.left || TextAlign.start => 'left',
          TextAlign.right || TextAlign.end => 'right',
          _ => 'center',
        };
        final colors = <(String?, Color, String)>[
          (null, Colors.transparent, 'Standard'),
          for (final (name, c) in palette)
            (
              '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}',
              c,
              name,
            ),
        ];

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.restore, size: 18),
                        label: const Text('Standard'),
                        onPressed: () => set(const TextLook()),
                      ),
                    ],
                  ),
                  section(
                    'Ausrichtung',
                    SegmentedButton<String>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(
                          value: 'left',
                          icon: Icon(Icons.format_align_left),
                          tooltip: 'Linksbündig',
                        ),
                        ButtonSegment(
                          value: 'center',
                          icon: Icon(Icons.format_align_center),
                          tooltip: 'Zentriert',
                        ),
                        ButtonSegment(
                          value: 'right',
                          icon: Icon(Icons.format_align_right),
                          tooltip: 'Rechtsbündig',
                        ),
                      ],
                      selected: {look.align ?? defAlign},
                      onSelectionChanged: (v) => set(
                        look.copyWith(
                          align: v.first == defAlign ? null : v.first,
                        ),
                      ),
                    ),
                  ),
                  section(
                    'Schrift',
                    hScroll([
                      for (final e in kTextLookFonts.entries)
                        ChoiceChip(
                          showCheckmark: false,
                          label: Text(
                            e.value,
                            style: posterFontStyle(
                              e.key,
                              const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          selected: (look.font ?? 'standard') == e.key,
                          onSelected: (_) => set(
                            look.copyWith(
                              font: e.key == 'standard' ? null : e.key,
                            ),
                          ),
                        ),
                    ]),
                  ),
                  section(
                    'Farbe',
                    hScroll([
                      for (final (key, c, name) in colors)
                        Tooltip(
                          message: name,
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: () => set(look.copyWith(color: key)),
                            child: Container(
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                color: key == null ? null : c,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: look.color == key
                                      ? scheme.primary
                                      : Colors.black26,
                                  width: look.color == key ? 3 : 1,
                                ),
                              ),
                              child: key == null
                                  ? Icon(
                                      Icons.format_color_reset,
                                      size: 18,
                                      color: hint,
                                    )
                                  : look.color == key
                                  ? Icon(
                                      Icons.check,
                                      size: 18,
                                      color: c.computeLuminance() > 0.5
                                          ? Colors.black
                                          : Colors.white,
                                    )
                                  : null,
                            ),
                          ),
                        ),
                    ]),
                  ),
                  section(
                    'Schatten',
                    hScroll([
                      for (final e in kTextShadowKinds.entries)
                        ChoiceChip(
                          label: Text(e.value),
                          selected: (look.shadow ?? 'none') == e.key,
                          onSelected: (_) => set(
                            look.copyWith(
                              shadow: e.key == 'none' ? null : e.key,
                            ),
                          ),
                        ),
                    ]),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}
