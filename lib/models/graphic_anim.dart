import 'dart:math' as math;
import 'dart:ui' show Offset;

/// Animation eines Grafik-Elements (Spielankündigung/Startelf/Ergebnis).
///
/// Alles rein und deterministisch: Der Zustand zu einem Zeitpunkt `t`
/// (Sekunden) ergibt sich nur aus den Werten hier – so sind Vorschau und
/// Video-Export (Frame für Frame) identisch.
class ElementAnim {
  ElementAnim({
    this.fx = 'none',
    this.start = 0,
    this.len = 0.6,
    this.count = 'none',
    this.shine = false,
    this.pulse = false,
  });

  /// none | fade | slideUp | slideDown | slideLeft | slideRight | zoomIn | pop
  String fx;
  double start;
  double len;

  /// none | up (von 0 hochzählen) | roll (Zahlen rollen bis zum Endwert)
  String count;
  bool shine;
  bool pulse;

  static const effects = <String, String>{
    'none': 'Keine',
    'fade': 'Einblenden',
    'slideUp': 'Von unten',
    'slideDown': 'Von oben',
    'slideLeft': 'Von rechts',
    'slideRight': 'Von links',
    'zoomIn': 'Reinzoomen',
    'pop': 'Aufploppen',
  };
  static const counts = <String, String>{
    'none': 'Aus',
    'up': 'Hochzählen',
    'roll': 'Rollen',
  };

  bool get isActive => fx != 'none' || count != 'none' || shine || pulse;

  /// Ende der Einblendung (bzw. des Zählens).
  double get end => start + len;

  ElementAnim copy() => ElementAnim.fromJson(toJson())!;

  Map<String, Object> toJson() => {
    'fx': fx,
    'start': start,
    'len': len,
    'count': count,
    'shine': shine,
    'pulse': pulse,
  };

  /// Liest (auch KI-Antworten) streng: unbekannte Werte → Standard, Zeiten
  /// auf [0, maxSeconds] begrenzt.
  static ElementAnim? fromJson(Object? v, {double maxSeconds = 15}) {
    if (v is! Map) return null;
    double num0(Object? x, double d) => x is num ? x.toDouble() : d;
    final fx = v['fx']?.toString() ?? 'none';
    final count = v['count']?.toString() ?? 'none';
    final start = num0(
      v['start'],
      0,
    ).clamp(0.0, math.max(0.0, maxSeconds - 0.2));
    return ElementAnim(
      fx: effects.containsKey(fx) ? fx : 'none',
      start: start.toDouble(),
      len: num0(v['len'], 0.6).clamp(0.1, 5.0).toDouble(),
      count: counts.containsKey(count) ? count : 'none',
      shine: v['shine'] == true,
      pulse: v['pulse'] == true,
    );
  }
}

/// Animation einer Grafik (je Format Story/Post).
class GraphicAnim {
  GraphicAnim({
    this.seconds = 8,
    this.bg = 'none',
    Map<String, ElementAnim>? items,
    this.preset = 'none',
  }) : items = items ?? {};

  /// Videolänge (5–15 s).
  int seconds;

  /// none | zoom (langsam heranzoomen) | pan (langsamer Schwenk)
  String bg;
  Map<String, ElementAnim> items;

  /// Zuletzt gewählte Vorlage (nur Anzeige).
  String preset;

  static const backgrounds = <String, String>{
    'none': 'Aus',
    'zoom': 'Zoom',
    'pan': 'Schwenk',
  };

  static const presets = <String, String>{
    'none': 'Keine',
    'stagger': 'Nacheinander',
    'reveal': 'Ergebnis-Reveal',
    'zoom': 'Zoom-In',
    'calm': 'Ruhig',
  };

  bool get isActive => bg != 'none' || items.values.any((e) => e.isActive);

  ElementAnim? of(String id) => items[id];

  GraphicAnim copy() => GraphicAnim.fromJson(toJson());

  Map<String, Object> toJson() => {
    'seconds': seconds,
    'bg': bg,
    'preset': preset,
    'items': {for (final e in items.entries) e.key: e.value.toJson()},
  };

  /// Liest gespeicherte Werte oder eine KI-Antwort. Mit [ids] werden nur
  /// bekannte Elemente übernommen.
  factory GraphicAnim.fromJson(Object? v, {Set<String>? ids, int? seconds}) {
    final a = GraphicAnim();
    if (v is! Map) {
      if (seconds != null) a.seconds = seconds;
      return a;
    }
    final s =
        seconds ?? (v['seconds'] is num ? (v['seconds'] as num).round() : 8);
    a.seconds = s.clamp(5, 15);
    final bg = v['bg']?.toString() ?? 'none';
    a.bg = backgrounds.containsKey(bg) ? bg : 'none';
    final p = v['preset']?.toString() ?? 'none';
    a.preset = presets.containsKey(p) || p == 'ai' ? p : 'none';
    final items = v['items'];
    if (items is Map) {
      items.forEach((k, e) {
        final id = k.toString();
        if (ids != null && !ids.contains(id)) return;
        final el = ElementAnim.fromJson(e, maxSeconds: a.seconds.toDouble());
        if (el != null && el.isActive) a.items[id] = el;
      });
    }
    return a;
  }
}

// ------------------------------------------------------------- Kurven
double _clamp01(double x) => x < 0 ? 0 : (x > 1 ? 1 : x);
double easeOutCubic(double p) => 1 - math.pow(1 - _clamp01(p), 3).toDouble();
double easeOutBack(double p) {
  const c1 = 1.70158, c3 = c1 + 1;
  final x = _clamp01(p) - 1;
  return 1 + c3 * x * x * x + c1 * x * x;
}

/// Fortschritt (0..1) der Einblendung von [e] zum Zeitpunkt [t].
double animProgress(ElementAnim e, double t) =>
    e.len <= 0 ? 1 : _clamp01((t - e.start) / e.len);

/// Zustand eines Elements zum Zeitpunkt [t]: Deckkraft, Versatz (Anteil der
/// Grafikbreite) und Skalierung. Ohne Animation: (1, 0, 1).
({double opacity, Offset offset, double scale}) animState(
  ElementAnim? e,
  double t,
) {
  if (e == null) return (opacity: 1, offset: Offset.zero, scale: 1);
  final p = animProgress(e, t);
  final k = easeOutCubic(p);
  var opacity = 1.0;
  var offset = Offset.zero;
  var scale = 1.0;
  const d = 0.12; // Weg beim Reinfliegen (Anteil der Breite)
  switch (e.fx) {
    case 'fade':
      opacity = k;
    case 'slideUp':
      opacity = _clamp01(p * 2);
      offset = Offset(0, (1 - k) * d);
    case 'slideDown':
      opacity = _clamp01(p * 2);
      offset = Offset(0, -(1 - k) * d);
    case 'slideLeft':
      opacity = _clamp01(p * 2);
      offset = Offset((1 - k) * d, 0);
    case 'slideRight':
      opacity = _clamp01(p * 2);
      offset = Offset(-(1 - k) * d, 0);
    case 'zoomIn':
      opacity = k;
      scale = 0.6 + 0.4 * k;
    case 'pop':
      opacity = _clamp01(p * 3);
      scale = math.max(0.0, easeOutBack(p));
  }
  if (e.pulse && t >= e.end) {
    scale *= 1 + 0.03 * math.sin(2 * math.pi * (t - e.end) / 1.2);
  }
  return (opacity: opacity, offset: offset, scale: scale);
}

/// Lage des Glanz-Streifens (-0.3 … 1.3 über die Elementbreite) oder null,
/// wenn gerade kein Durchlauf ist. Alle 3 s ein Durchlauf von 0,8 s, der
/// erste direkt nach der Einblendung.
double? shineAt(ElementAnim? e, double t) {
  if (e == null || !e.shine) return null;
  final since = t - e.end;
  if (since < 0) return null;
  final phase = since % 3.0;
  if (phase > 0.8) return null;
  return -0.3 + 1.6 * (phase / 0.8);
}

/// Hintergrund-Bewegung: (Skalierung, Versatz als Anteil der Breite).
({double scale, Offset offset}) bgTransform(String bg, double t, int seconds) {
  final p = seconds <= 0 ? 0.0 : _clamp01(t / seconds);
  switch (bg) {
    case 'zoom':
      return (scale: 1 + 0.08 * p, offset: Offset.zero);
    case 'pan':
      return (scale: 1.12, offset: Offset(0.04 - 0.08 * p, 0));
    default:
      return (scale: 1, offset: Offset.zero);
  }
}

final _numRe = RegExp(r'\d+');

/// Text mit Zahlen zum Zeitpunkt [t]: `up` zählt von 0 hoch, `roll` zeigt
/// wechselnde Werte und rastet am Ende exakt auf dem Original ein.
String countText(String text, ElementAnim? e, double t, {String seed = ''}) {
  if (e == null || e.count == 'none') return text;
  final p = animProgress(e, t);
  if (p >= 1) return text;
  var i = 0;
  final frame = (t * 12).floor(); // 12 Wechsel je Sekunde beim Rollen
  return text.replaceAllMapped(_numRe, (m) {
    final orig = m.group(0)!;
    final n = int.parse(orig);
    final idx = i++;
    if (e.count == 'up') {
      return (n * easeOutCubic(p)).round().toString();
    }
    if (t < e.start) return '0';
    final max = math.max(9, n);
    final h = _hash('$seed|$idx|$frame');
    return (h % (max + 1)).toString();
  });
}

/// Hat der Text eine Zahl (für den Zähler)?
bool hasNumber(String text) => _numRe.hasMatch(text);

int _hash(String s) {
  var h = 0x811c9dc5;
  for (final c in s.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0x7fffffff;
  }
  return h;
}

/// Ein Element für Vorlagen/KI: id, Art und (bei Texten) der Text.
typedef AnimElement = ({String id, String type, String? text});

/// Vorlage anwenden: setzt Effekte je Element (in Ebenen-Reihenfolge).
/// Arten: text | image | player | logo | score | other.
GraphicAnim applyPreset(
  String preset,
  List<AnimElement> els, {
  required String kind,
  int seconds = 8,
}) {
  final a = GraphicAnim(seconds: seconds, preset: preset);
  if (preset == 'none') return a;
  String numCount(AnimElement el, String c) =>
      el.type == 'score' || (el.text != null && hasNumber(el.text!))
      ? c
      : 'none';
  switch (preset) {
    case 'stagger':
      a.bg = 'zoom';
      for (var i = 0; i < els.length; i++) {
        final el = els[i];
        a.items[el.id] = ElementAnim(
          fx: switch (el.type) {
            'logo' => 'pop',
            'player' => 'slideUp',
            'image' => 'fade',
            _ => 'slideUp',
          },
          start: 0.2 + i * 0.2,
          count: numCount(el, el.type == 'score' ? 'roll' : 'up'),
        );
      }
    case 'reveal':
      a.bg = 'zoom';
      var late = 1.6;
      for (final el in els) {
        if (el.type == 'score') {
          a.items[el.id] = ElementAnim(
            fx: 'fade',
            start: 0.5,
            len: 1.6,
            count: 'roll',
          );
        } else if (el.type == 'logo') {
          a.items[el.id] = ElementAnim(fx: 'pop', start: 0.3, len: 0.5);
        } else if (el.text != null && hasNumber(el.text!)) {
          a.items[el.id] = ElementAnim(
            fx: 'fade',
            start: 0.5,
            len: 1.6,
            count: 'roll',
          );
        } else {
          a.items[el.id] = ElementAnim(fx: 'fade', start: late);
          late += 0.15;
        }
      }
    case 'zoom':
      a.bg = 'zoom';
      for (var i = 0; i < els.length; i++) {
        final el = els[i];
        a.items[el.id] = ElementAnim(
          fx: 'zoomIn',
          start: 0.15 + i * 0.15,
          count: numCount(el, 'up'),
        );
      }
    case 'calm':
      a.bg = 'zoom';
      final first = els
          .where((e) => e.type == 'text' || e.type == 'score')
          .firstOrNull;
      if (first != null) {
        a.items[first.id] = ElementAnim(start: 0.5, len: 0.1, shine: true);
      }
  }
  // Nichts über das Videoende hinaus.
  for (final e in a.items.values) {
    if (e.start > seconds - 1) e.start = (seconds - 1).toDouble();
  }
  return a;
}

/// KI-Ergebnis [ai] gezielt in [base] übernehmen: nur die Elemente [ids]
/// werden ersetzt (bzw. entfernt, wenn die KI keinen Effekt liefert), alle
/// anderen bleiben unverändert. Hintergrund nur bei [withBg].
GraphicAnim mergeAnim(
  GraphicAnim base,
  GraphicAnim ai,
  Set<String> ids, {
  required bool withBg,
}) {
  final out = base.copy();
  for (final id in ids) {
    final e = ai.items[id];
    if (e != null && e.isActive) {
      out.items[id] = e.copy();
    } else {
      out.items.remove(id);
    }
  }
  if (withBg) out.bg = ai.bg;
  out.preset = 'ai';
  return out;
}
