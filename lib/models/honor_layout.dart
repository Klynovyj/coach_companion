import 'dart:convert';
import 'dart:ui' show Offset;

import '../widgets/text_look.dart';

/// Frei angepasstes Layout der Ehrungs-Grafiken (Post, Story, Urkunde) –
/// Bedienung wie im Designer: jedes feste Element lässt sich verschieben,
/// skalieren, drehen und ausblenden, jeder Text frei ändern (Umbruch nur per
/// Enter), dazu eigene Texte. Ohne Änderung = Standard-Layout.
///
/// Texte gelten für alle Formate (einmal tippen reicht), Position/Größe/Stil
/// je Format. Gespeichert je Spieler (`honor:<playerId>`) bzw. als Vorlage
/// für alle (`honor:template`) in `announcement_designs`.
class HonorLayout {
  HonorLayout({
    Map<String, String>? texts,
    Map<String, HonorFormatLayout>? fmts,
    this.photoSlot,
    this.photoData,
  }) : texts = texts ?? {},
       formats = fmts ?? {};

  /// Foto nur für diese Ehrung: eines der Spielerfotos (`fupa`/`own`/`club`/
  /// `action`) oder ein eigenes Bild ([photoData], quadratische Data-URL).
  /// Beides null = Profilbild des Spielers. Nie Teil einer Vorlage.
  String? photoSlot;
  String? photoData;

  /// Text-Overrides je Element-ID (z. B. `occasion`, `honor`, `stat:Spiele`).
  final Map<String, String> texts;

  /// Layout je Format (`post` / `story` / `urkunde`).
  final Map<String, HonorFormatLayout> formats;

  /// Zeilen-ID je Spieler bzw. der gemeinsamen Vorlage.
  static String playerRowId(String playerId) => 'honor:$playerId';
  static const templateRowId = 'honor:template';
  static const kindPlayer = 'honor_layout';
  static const kindTemplate = 'honor_template';

  /// Spielerbezogene Texte, die eine Vorlage NIE mitnimmt.
  static const playerOnlyTexts = {'name'};

  bool get isEmpty =>
      texts.isEmpty &&
      photoSlot == null &&
      photoData == null &&
      formats.values.every((f) => f.isEmpty);

  HonorFormatLayout format(String fmt) =>
      formats.putIfAbsent(fmt, HonorFormatLayout.new);

  /// Kopie als Vorlage für alle Spieler (ohne Name-Override).
  HonorLayout forTemplate() {
    final c = HonorLayout.fromJson(toJson());
    c.texts.removeWhere((k, _) => playerOnlyTexts.contains(k));
    c.photoSlot = null;
    c.photoData = null;
    return c;
  }

  Map<String, dynamic> toJson() => {
    'v': 1,
    if (texts.isNotEmpty) 'texts': texts,
    if (photoSlot != null) 'photoSlot': photoSlot,
    if (photoData != null) 'photoData': photoData,
    'formats': {
      for (final e in formats.entries)
        if (!e.value.isEmpty) e.key: e.value.toJson(),
    },
  };

  factory HonorLayout.fromJson(Map<String, dynamic> j) {
    final t = j['texts'];
    final f = j['formats'];
    return HonorLayout(
      texts: t is Map
          ? {for (final e in t.entries) e.key.toString(): e.value.toString()}
          : null,
      fmts: f is Map
          ? {
              for (final e in f.entries)
                if (e.value is Map)
                  e.key.toString(): HonorFormatLayout.fromJson(
                    Map<String, dynamic>.from(e.value as Map),
                  ),
            }
          : null,
      photoSlot: j['photoSlot'] as String?,
      photoData: j['photoData'] as String?,
    );
  }

  String encode() => jsonEncode(toJson());

  /// Robust: kaputte/fehlende Daten → leeres Layout (= Standard).
  static HonorLayout decode(String? raw) {
    if (raw == null || raw.isEmpty) return HonorLayout();
    try {
      final m = jsonDecode(raw);
      if (m is Map) return HonorLayout.fromJson(Map<String, dynamic>.from(m));
    } catch (_) {}
    return HonorLayout();
  }
}

/// Layout eines Formats: Anpassungen der festen Elemente + eigene Texte.
class HonorFormatLayout {
  HonorFormatLayout({
    Map<String, HonorElementEdit>? items,
    List<HonorFreeText>? free,
  }) : items = items ?? {},
       free = free ?? [];

  final Map<String, HonorElementEdit> items;
  final List<HonorFreeText> free;

  bool get isEmpty => free.isEmpty && items.values.every((e) => e.isDefault);

  HonorElementEdit item(String id) => items[id] ?? const HonorElementEdit();

  void setItem(String id, HonorElementEdit e) {
    if (e.isDefault) {
      items.remove(id);
    } else {
      items[id] = e;
    }
  }

  Map<String, dynamic> toJson() => {
    'items': {
      for (final e in items.entries)
        if (!e.value.isDefault) e.key: e.value.toJson(),
    },
    if (free.isNotEmpty) 'free': [for (final f in free) f.toJson()],
  };

  factory HonorFormatLayout.fromJson(Map<String, dynamic> j) {
    final it = j['items'];
    final fr = j['free'];
    return HonorFormatLayout(
      items: it is Map
          ? {
              for (final e in it.entries)
                if (e.value is Map)
                  e.key.toString(): HonorElementEdit.fromJson(
                    Map<String, dynamic>.from(e.value as Map),
                  ),
            }
          : null,
      free: fr is List
          ? [
              for (final f in fr)
                if (f is Map)
                  HonorFreeText.fromJson(Map<String, dynamic>.from(f)),
            ]
          : null,
    );
  }
}

/// Anpassung eines Elements: Versatz (logische px), Größe, Drehung (rad),
/// ausgeblendet, Text-Stil und Schriftgröße ([fs] = Faktor auf die
/// Standard-Schriftgröße; anders als [scale] ändert sie nur die Schrift).
class HonorElementEdit {
  const HonorElementEdit({
    this.off = Offset.zero,
    this.scale = 1,
    this.rot = 0,
    this.hidden = false,
    this.look,
    this.fs = 1,
  });

  static const minScale = 0.3;
  static const maxScale = 5.0;
  static const minFs = 0.4;
  static const maxFs = 4.0;

  final Offset off;
  final double scale;
  final double rot;
  final bool hidden;
  final TextLook? look;
  final double fs;

  bool get isDefault =>
      off == Offset.zero &&
      scale == 1 &&
      rot == 0 &&
      !hidden &&
      fs == 1 &&
      (look == null || look!.isDefault);

  HonorElementEdit copyWith({
    Offset? off,
    double? scale,
    double? rot,
    bool? hidden,
    Object? look = _unset,
    double? fs,
  }) => HonorElementEdit(
    off: off ?? this.off,
    scale: (scale ?? this.scale).clamp(minScale, maxScale).toDouble(),
    rot: rot ?? this.rot,
    hidden: hidden ?? this.hidden,
    look: identical(look, _unset) ? this.look : look as TextLook?,
    fs: (fs ?? this.fs).clamp(minFs, maxFs).toDouble(),
  );
  static const _unset = Object();

  Map<String, dynamic> toJson() => {
    if (off != Offset.zero) 'off': [_r(off.dx), _r(off.dy)],
    if (scale != 1) 'scale': _r(scale),
    if (rot != 0) 'rot': _r(rot),
    if (hidden) 'hidden': true,
    if (fs != 1) 'fs': _r(fs),
    if (look != null && !look!.isDefault) 'look': look!.toJson(),
  };

  factory HonorElementEdit.fromJson(Map<String, dynamic> j) {
    final o = j['off'];
    final l = j['look'];
    return HonorElementEdit(
      off: o is List && o.length == 2
          ? Offset((o[0] as num).toDouble(), (o[1] as num).toDouble())
          : Offset.zero,
      scale: ((j['scale'] as num?)?.toDouble() ?? 1)
          .clamp(minScale, maxScale)
          .toDouble(),
      rot: (j['rot'] as num?)?.toDouble() ?? 0,
      hidden: j['hidden'] == true,
      look: l is Map ? TextLook.fromJson(Map<String, dynamic>.from(l)) : null,
      fs: ((j['fs'] as num?)?.toDouble() ?? 1).clamp(minFs, maxFs).toDouble(),
    );
  }
}

/// Eigener, frei platzierter Text. [x]/[y] = Mittelpunkt als Anteil der
/// Grafik (0..1); Versatz/Größe/Drehung/Stil liegen wie bei festen Elementen
/// unter `free:<id>` in [HonorFormatLayout.items].
class HonorFreeText {
  HonorFreeText({
    required this.id,
    required this.text,
    this.x = 0.5,
    this.y = 0.5,
  });

  final String id;
  String text;
  final double x;
  final double y;

  String get itemId => 'free:$id';

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'x': _r(x),
    'y': _r(y),
  };

  factory HonorFreeText.fromJson(Map<String, dynamic> j) => HonorFreeText(
    id: j['id']?.toString() ?? '0',
    text: j['text']?.toString() ?? '',
    x: ((j['x'] as num?)?.toDouble() ?? 0.5).clamp(0.0, 1.0).toDouble(),
    y: ((j['y'] as num?)?.toDouble() ?? 0.5).clamp(0.0, 1.0).toDouble(),
  );
}

double _r(double v) => (v * 1000).roundToDouble() / 1000;
