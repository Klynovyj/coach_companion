import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../screens/startelf_graphic_screen.dart'
    show chromaKeyMagenta, lookCanvasPng, lumaKeyBlack;
import '../services/cloud_service.dart';

/// KI-Look: Deko-Ebene (PNG mit Alpha), die Gemini über eine fertige Grafik
/// malt (Konfetti, Lichter, Pyro …). Texte/Logos/Spieler bleiben unverändert.
/// Gemeinsame Bausteine für Spielankündigung & Co. und die Ehrungen-Grafik.

// KI-Look-Vorlagen: Gruppe → (Name, Motiv-Beschreibung für die KI).
const Map<String, List<(String, String)>> kAiLookPresets = {
  'Feiertage': [
    (
      'Karneval',
      'Karneval/Fasching: bunte Luftschlangen, Konfetti, Narrenkappen-Zacken, '
          'kleine Sterne und Luftballons in Rot, Gelb, Grün und Blau',
    ),
    (
      'Weihnachten',
      'Weihnachten: goldene Lichterketten, Christbaumkugeln, Tannenzweige, '
          'Schneeflocken und warmes Funkeln',
    ),
    (
      'Ostern',
      'Ostern: Frühlingsblüten, bunte Ostereier, Pastellfarben, Gräser und '
          'kleine Schmetterlinge',
    ),
    (
      'Silvester',
      'Silvester/Neujahr: Feuerwerk, goldene Funken, Sektperlen, Glitzer und '
          'Lichtstreifen',
    ),
    (
      'Halloween',
      'Halloween: Kürbisse, Fledermäuse, Spinnweben, orange-violettes '
          'Leuchten und Nebelschwaden',
    ),
  ],
  'Spiel-Anlässe': [
    (
      'Derby',
      'Derby-Stimmung: lodernde Flammen, Funkenflug, Rauchschwaden und '
          'Pyro-Leuchten in den Vereinsfarben',
    ),
    (
      'Pokalspiel',
      'Pokalspiel: goldene Lichtstrahlen, Glanz, Funkeln und edle '
          'Goldakzente wie bei einem Finale',
    ),
    (
      'Saisonstart',
      'Saisonstart: dynamische Speed-Lines, Lichtblitze und Energie-Streifen '
          'in den Vereinsfarben',
    ),
    (
      'Flutlicht',
      'Topspiel unter Flutlicht: helle Flutlicht-Strahlen von oben, '
          'Lichtkegel, Lens-Flares und leichter Dunst',
    ),
  ],
  'Feiern': [
    (
      'Sieg',
      'Siegesfeier: Konfetti-Regen, Goldglitzer, Luftschlangen und '
          'Jubel-Lichteffekte',
    ),
    (
      'Aufstieg',
      'Aufstiegsfeier: goldenes Konfetti, Feuerwerk, Sektspritzer und '
          'Lichtstrahlen nach oben',
    ),
    (
      'Meisterschaft',
      'Meisterschaft: goldene Sterne, Lorbeerzweige, Konfetti und edler '
          'Goldglanz',
    ),
    (
      'Jubiläum',
      'Vereinsjubiläum: elegante Goldornamente, Sterne, Lichterglanz und '
          'festliches Funkeln',
    ),
  ],
  'Wetter & Stimmung': [
    (
      'Herbst',
      'Herbst: fallende bunte Blätter in Rot, Orange und Gelb, warmes '
          'Gegenlicht',
    ),
    (
      'Winter',
      'Winter: Schneefall, Eiskristalle, Frost an den Rändern, kühles '
          'Glitzern',
    ),
    (
      'Sommer',
      'Sommer: Sonnenstrahlen, Lens-Flares, warmes goldenes Licht und '
          'Hitzeflimmern',
    ),
    (
      'Regen & Nebel',
      'Regen und Nebel: Regentropfen, Regenschlieren, Nebelschwaden und '
          'stimmungsvolles Gegenlicht',
    ),
  ],
};

/// Zusätzliche Vorlagen für Ehrungen (Spieler des Monats, Jubiläum …).
const Map<String, List<(String, String)>> kAiLookHonorPresets = {
  'Ehrungen': [
    (
      'Spieler des Monats',
      'Ehrung Spieler des Monats: edler Goldglanz, funkelnde Sterne, '
          'Lichtstrahlen von oben und feiner Goldstaub',
    ),
    (
      'Jubiläum',
      'Jubiläum: elegante Goldornamente, Konfetti, Lichterglanz und festliches '
          'Funkeln',
    ),
    (
      'Meilenstein',
      'Meilenstein/100. Spiel: goldene Lorbeerzweige, Lichtstrahlen, Glanz und '
          'aufsteigende Funken',
    ),
    (
      'Torschützenkönig',
      'Torschützenkönig: goldene Krone, Funkenregen, Glitzer und kraftvolles '
          'Leuchten',
    ),
    (
      'Danke',
      'Dankeschön: warmes goldenes Licht, kleine Herzen, Bokeh-Lichter und '
          'sanftes Funkeln',
    ),
  ],
};

/// Kurzname eines Looks (Vorlagen-Name oder Anfang des eigenen Textes).
String aiLookName(
  String theme, [
  Map<String, List<(String, String)>> presets = kAiLookPresets,
]) {
  for (final group in presets.values) {
    for (final p in group) {
      if (p.$2 == theme) return p.$1;
    }
  }
  final t = theme.trim();
  return t.length > 32 ? '${t.substring(0, 32)} …' : t;
}

/// Gespeicherter KI-Look (Bild + Motiv + Darstellung + Stärke).
class AiLookData {
  AiLookData({
    required this.dataUrl,
    required this.mode,
    required this.theme,
    this.opacity = 1.0,
  });

  final String dataUrl;

  /// 'glow' (Leuchtend) | 'cutout' (Freigestellt)
  final String mode;
  final String theme;
  double opacity;

  Map<String, Object> toJson() => {
    'url': dataUrl,
    'mode': mode,
    'theme': theme,
    'op': opacity,
  };

  static AiLookData? fromJson(Object? v) {
    if (v is! Map) return null;
    final url = v['url'];
    if (url is! String || url.isEmpty) return null;
    final op = v['op'];
    return AiLookData(
      dataUrl: url,
      mode: v['mode'] == 'cutout' ? 'cutout' : 'glow',
      theme: v['theme']?.toString() ?? '',
      opacity: op is num ? op.toDouble().clamp(0.1, 1.0) : 1.0,
    );
  }
}

/// Dialog „KI-Look erstellen": Vorlagen (füllen das Textfeld, frei änderbar)
/// oder eigener Text + Darstellung Leuchtend/Freigestellt. Ist [fixedMode]
/// gesetzt, entfällt die Wahl (z. B. Urkunde: immer „Freigestellt").
Future<({String theme, String mode})?> showAiLookDialog(
  BuildContext context, {
  String? theme,
  String mode = 'glow',
  Map<String, List<(String, String)>> presets = kAiLookPresets,
  String? fixedMode,
  String? fixedModeHint,
}) async {
  final ctrl = TextEditingController(text: theme ?? '');
  var m = fixedMode ?? mode;
  return showDialog<({String theme, String mode})>(
    context: context,
    builder: (ctx) => AlertDialog(
      scrollable: true,
      title: const Text('KI-Look erstellen'),
      content: SizedBox(
        width: double.maxFinite,
        child: StatefulBuilder(
          builder: (ctx, setLocal) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Die KI malt nur eine Deko-Ebene an den Rändern. Deine '
                'Grafik darunter bleibt unverändert.',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              for (final group in presets.entries) ...[
                const SizedBox(height: 10),
                Text(
                  group.key,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final p in group.value)
                      ChoiceChip(
                        label: Text(p.$1),
                        selected: ctrl.text == p.$2,
                        onSelected: (_) => setLocal(() {
                          ctrl.text = p.$2;
                          ctrl.selection = TextSelection.collapsed(
                            offset: ctrl.text.length,
                          );
                        }),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                maxLines: 3,
                textCapitalization: TextCapitalization.sentences,
                onChanged: (_) => setLocal(() {}),
                decoration: const InputDecoration(
                  labelText: 'Eigener Look / Vorlage anpassen',
                  hintText:
                      'z. B. Derby gegen Benrath: rot-weiße Pyro, '
                      'Rauch und Funken',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              if (fixedMode == null) ...[
                const Text('Darstellung:', style: TextStyle(fontSize: 12)),
                const SizedBox(height: 4),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: 'glow',
                      label: Text('Leuchtend'),
                      icon: Icon(Icons.flare),
                    ),
                    ButtonSegment(
                      value: 'cutout',
                      label: Text('Freigestellt'),
                      icon: Icon(Icons.layers),
                    ),
                  ],
                  selected: {m},
                  onSelectionChanged: (sel) => setLocal(() => m = sel.first),
                ),
                const SizedBox(height: 4),
                Text(
                  m == 'glow'
                      ? 'Leuchtend: Licht, Funken, Konfetti, Schnee wirken '
                            'strahlend; dunkle Deko-Teile verschwinden.'
                      : 'Freigestellt: Farben exakt (auch dunkle Deko wie '
                            'Tannenzweige); Ränder können leicht ausfransen.',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
              ] else if (fixedModeHint != null)
                Text(fixedModeHint, style: Theme.of(ctx).textTheme.bodySmall),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          onPressed: () {
            final t = ctrl.text.trim();
            if (t.isEmpty) return;
            Navigator.pop(ctx, (theme: t, mode: m));
          },
          child: const Text('Erstellen'),
        ),
      ],
    ),
  );
}

/// Erzeugt die Deko-Ebene: leere Leinwand ([width]×[height], Schwarz bzw.
/// Magenta) an Gemini (Modus `overlay`), Ergebnis per Luma-/Chroma-Key in ein
/// PNG mit Alpha. Gibt `null` zurück, wenn die KI kein Bild liefert; wirft bei
/// Fehlern (Meldung über [aiErrorMessage]).
Future<Uint8List?> generateAiLookPng({
  required String theme,
  required String mode,
  required int width,
  required int height,
  required String aspect,
  required String gradTop,
  required String gradBottom,
}) async {
  final magenta = mode == 'cutout';
  final canvas = await compute(lookCanvasPng, <String, Object>{
    'w': width,
    'h': height,
    'magenta': magenta,
  });
  final out = await CloudService.aiImage(
    images: [
      {
        'mime': 'image/png',
        'data': 'data:image/png;base64,${base64Encode(canvas)}',
        'role': 'canvas',
      },
    ],
    prompt: '$theme. Vereinsfarben als Akzent: $gradTop, $gradBottom.',
    mode: 'overlay',
    aspect: aspect,
    key: magenta ? 'magenta' : 'black',
  );
  if (out == null) return null;
  return compute(magenta ? chromaKeyMagenta : lumaKeyBlack, out);
}

String _errSnippet(String s, int max) {
  final d = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return d.length > max ? '${d.substring(0, max)}…' : d;
}

/// Verständliche Meldung zu einem KI-Fehler (Gemini/Edge-Function).
String aiErrorMessage(Object e) {
  final s = e.toString();
  final low = s.toLowerCase();
  if (low.contains('resource_exhausted') ||
      low.contains('prepayment credits') ||
      low.contains('quota') ||
      low.contains('"code": 402') ||
      low.contains('code: 402')) {
    return 'Gemini-Guthaben aufgebraucht – im Google AI Studio Guthaben aufladen.';
  }
  if (low.contains('api_key_invalid') ||
      low.contains('api key not valid') ||
      low.contains('unauthorized') ||
      low.contains('permission_denied')) {
    return 'Gemini-Zugang abgelehnt – API-Key im Supabase-Secret prüfen.';
  }
  if (low.contains('gemini_api_key fehlt') || low.contains('secret setzen')) {
    return 'Gemini ist noch nicht eingerichtet (Secret fehlt).';
  }
  if (low.contains('nicht freigeschaltet')) {
    return 'KI ist für dich nicht freigeschaltet (Einstellungen → '
        'KI-Berechtigungen).';
  }
  if (low.contains('kein bild von der ki')) {
    return 'Die KI hat kein Bild zurückgegeben – anderen Wunsch probieren.';
  }
  // Zeitlimit/Server kurz überlastet ≠ kein Internet.
  if (low.contains('timeout') ||
      low.contains('timed out') ||
      low.contains('504') ||
      low.contains('503') ||
      low.contains('546') ||
      low.contains('wall clock') ||
      low.contains('worker_limit')) {
    return 'Die KI hat zu lange gebraucht bzw. war kurz überlastet – bitte '
        'gleich noch mal versuchen.';
  }
  if (low.contains('failed host lookup') ||
      low.contains('network is unreachable') ||
      low.contains('no address associated')) {
    return 'Keine Internetverbindung – Netz prüfen und erneut versuchen.';
  }
  if (low.contains('socketexception') ||
      low.contains('clientexception') ||
      low.contains('connection')) {
    return 'Verbindung zur KI abgebrochen – bitte erneut versuchen. '
        '(${_errSnippet(s, 90)})';
  }
  // Unbekannter Fehler: kurzen Rohhinweis mitgeben, damit die echte Ursache
  // sichtbar ist (Function-/Gemini-Meldung), statt nur „später versuchen".
  final detail = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  final snippet = detail.length > 160 ? '${detail.substring(0, 160)}…' : detail;
  return 'KI-Fehler: $snippet';
}
