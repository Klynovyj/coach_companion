import 'dart:convert';
import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/prep_plan.dart';

/// Vorbereitungsplan als DIN-A4-PDF (Hochformat) – Layout 1:1 wie der Druck
/// im Coach Studio: Logo + Titel, grüne Tabellen-Kopfzeile (wiederholt sich
/// auf Folgeseiten), farbige Zeilen (Heim grün, Auswärts orange, Training
/// blau), „Fraglich"-Markierung, Extra-Texte und die Vorbereitungsbilanz.
class PrepPlanPdf {
  const PrepPlanPdf._();

  // Farben aus dem Coach-Studio-Druck.
  static const _green = PdfColor.fromInt(0xFF166534);
  static const _pitch800 = PdfColor.fromInt(0xFF0D3F24);
  static const _pitch700 = PdfColor.fromInt(0xFF125632);
  static const _title = PdfColor.fromInt(0xFF0F172A);
  static const _text = PdfColor.fromInt(0xFF111827);
  static const _ink900 = PdfColor.fromInt(0xFF0B0F17);
  static const _ink700 = PdfColor.fromInt(0xFF1F2937);
  static const _ink600 = PdfColor.fromInt(0xFF374151);
  static const _gray = PdfColor.fromInt(0xFF6B7280);
  static const _gray600 = PdfColor.fromInt(0xFF4B5563);
  static const _line = PdfColor.fromInt(0xFFD1D5DB);
  static const _rowHome = PdfColor.fromInt(0xFFF0FDF4);
  static const _rowAway = PdfColor.fromInt(0xFFFFFBEB);
  static const _rowTraining = PdfColor.fromInt(0xFFF0F9FF);
  static const _amber = PdfColor.fromInt(0xFFD97706);
  static const _amberBg = PdfColor.fromInt(0xFFFEF3C7);
  static const _amberText = PdfColor.fromInt(0xFF92400E);

  /// CSS-Pixel → PDF-Punkte (96 dpi → 72 dpi).
  static double px(double v) => v * 0.75;

  static Future<Uint8List> build({
    required PrepPlan plan,
    String? teamName,
    Uint8List? logo,
  }) async {
    final doc = pw.Document(
      title: plan.title,
      author: teamName ?? 'myCoach',
      theme: pw.ThemeData.withFont(
        base: pw.Font.helvetica(),
        bold: pw.Font.helveticaBold(),
        italic: pw.Font.helveticaOblique(),
        boldItalic: pw.Font.helveticaBoldOblique(),
      ),
    );

    pw.ImageProvider? logoImg;
    if (logo != null) {
      try {
        logoImg = pw.MemoryImage(logo);
      } catch (_) {}
    }

    final hint = _richText(plan.hint);
    final footer = _richText(plan.footerText);

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.copyWith(
          marginLeft: 14 * PdfPageFormat.mm,
          marginRight: 14 * PdfPageFormat.mm,
          marginTop: 14 * PdfPageFormat.mm,
          marginBottom: 14 * PdfPageFormat.mm,
        ),
        build: (ctx) => [
          _header(plan, teamName, logoImg),
          if (hint != null)
            pw.Padding(
              padding: pw.EdgeInsets.fromLTRB(px(16), px(8), px(16), px(8)),
              child: hint,
            ),
          pw.SizedBox(height: px(12)),
          if (plan.entries.isEmpty)
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(vertical: 18),
              child: pw.Center(
                child: pw.Text(
                  'Noch keine Termine.',
                  style: pw.TextStyle(color: _gray, fontSize: px(11)),
                ),
              ),
            )
          else
            _table(plan.entries),
          if (footer != null)
            pw.Padding(
              padding: pw.EdgeInsets.fromLTRB(px(16), px(16), px(16), px(8)),
              child: footer,
            ),
          pw.SizedBox(height: px(24)),
          _stats(plan.entries),
        ],
      ),
    );
    return doc.save();
  }

  // ------------------------------------------------------------------ Kopf
  static pw.Widget _header(
    PrepPlan plan,
    String? teamName,
    pw.ImageProvider? logo,
  ) {
    final logoBox = pw.SizedBox(
      width: px(96),
      height: px(96),
      child: logo != null
          ? pw.Image(logo, fit: pw.BoxFit.contain)
          : pw.Center(
              child: pw.Text(
                _safe(
                  (teamName ?? '?')
                      .padRight(2)
                      .substring(0, 2)
                      .trim()
                      .toUpperCase(),
                ),
                style: pw.TextStyle(
                  fontSize: px(20),
                  fontWeight: pw.FontWeight.bold,
                  color: _gray,
                ),
              ),
            ),
    );
    final sub = plan.subtitle?.trim();
    return pw.Container(
      padding: const pw.EdgeInsets.only(bottom: 4 * PdfPageFormat.mm),
      margin: const pw.EdgeInsets.only(bottom: 4 * PdfPageFormat.mm),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          logoBox,
          pw.SizedBox(width: px(20)),
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  _safe(plan.title),
                  style: pw.TextStyle(
                    fontSize: px(22),
                    fontWeight: pw.FontWeight.bold,
                    color: _title,
                    lineSpacing: 1,
                  ),
                ),
                if (sub != null && sub.isNotEmpty) ...[
                  pw.SizedBox(height: 2),
                  pw.Text(
                    _safe(sub.toUpperCase()),
                    style: pw.TextStyle(
                      fontSize: px(9.5),
                      fontWeight: pw.FontWeight.bold,
                      color: _pitch700,
                      letterSpacing: px(9.5) * 0.12,
                    ),
                  ),
                ],
                if (teamName != null && teamName.trim().isNotEmpty) ...[
                  pw.SizedBox(height: px(4)),
                  pw.Text(
                    _safe(teamName.toUpperCase()),
                    style: pw.TextStyle(
                      fontSize: px(9.5),
                      fontWeight: pw.FontWeight.bold,
                      color: _gray600,
                      letterSpacing: px(9.5) * 0.12,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- Tabelle
  static const _colW = <int, pw.TableColumnWidth>{
    0: pw.FixedColumnWidth(72), // Datum 6rem
    1: pw.FixedColumnWidth(84), // Treffpunkt 7rem
    2: pw.FlexColumnWidth(),
    3: pw.FixedColumnWidth(84), // H / A 7rem
    4: pw.FixedColumnWidth(72), // Beginn 6rem
  };

  static pw.Widget _table(List<PrepPlanEntry> entries) {
    final headStyle = pw.TextStyle(
      color: PdfColors.white,
      fontSize: px(9),
      fontWeight: pw.FontWeight.bold,
      letterSpacing: px(9) * 0.14,
    );
    pw.Widget th(String t, {bool first = false}) => pw.Container(
      padding: const pw.EdgeInsets.symmetric(horizontal: 9, vertical: 7),
      decoration: first
          ? null
          : const pw.BoxDecoration(
              border: pw.Border(
                left: pw.BorderSide(color: PdfColor(1, 1, 1, 0.22)),
              ),
            ),
      child: pw.Text(t, style: headStyle),
    );

    final rows = <pw.TableRow>[
      pw.TableRow(
        repeat: true,
        decoration: const pw.BoxDecoration(color: _green),
        children: [
          th('DATUM', first: true),
          th('TREFFPUNKT'),
          th('ANLASS / DETAILS'),
          th('H / A'),
          th('BEGINN'),
        ],
      ),
    ];
    for (var i = 0; i < entries.length; i++) {
      rows.add(_row(entries[i], last: i == entries.length - 1));
    }
    return pw.Table(columnWidths: _colW, children: rows);
  }

  static pw.TableRow _row(PrepPlanEntry e, {required bool last}) {
    final tint = e.venue == PrepVenue.home
        ? _rowHome
        : e.venue == PrepVenue.away
        ? _rowAway
        : e.anlass == PrepAnlass.training
        ? _rowTraining
        : PdfColors.white;
    final tentative = e.tentative;
    final italic = tentative ? pw.FontStyle.italic : pw.FontStyle.normal;
    PdfColor c(PdfColor normal) => tentative ? _gray : normal;

    final bottom = pw.BorderSide(
      color: last ? _green : _line,
      width: last ? 1.125 : 0.75,
    );
    const lineSide = pw.BorderSide(color: _line, width: 0.75);
    pw.Widget cell(
      pw.Widget child, {
      bool first = false,
      bool lastCol = false,
    }) => pw.Container(
      padding: const pw.EdgeInsets.symmetric(horizontal: 9, vertical: 8),
      decoration: pw.BoxDecoration(
        border: pw.Border(
          bottom: bottom,
          // „Fraglich": dicke gestrichelte Amber-Kante links an der Zeile.
          left: first && tentative
              ? const pw.BorderSide(
                  color: _amber,
                  width: 3,
                  style: pw.BorderStyle.dashed,
                )
              : lineSide,
          right: lastCol ? lineSide : pw.BorderSide.none,
        ),
      ),
      child: child,
    );

    final dataStyle = pw.TextStyle(
      fontSize: px(11.5),
      fontWeight: pw.FontWeight.bold,
      color: c(_text),
      fontStyle: italic,
    );
    final bodyStyle = pw.TextStyle(
      fontSize: px(11),
      color: c(_text),
      fontStyle: italic,
    );
    final labelStyle = pw.TextStyle(
      fontSize: px(9),
      color: _gray,
      fontStyle: italic,
    );
    final anlassStyle = pw.TextStyle(
      fontSize: 10.5,
      fontWeight: pw.FontWeight.bold,
      letterSpacing: 10.5 * 0.06,
      color: c(_ink900),
      fontStyle: italic,
    );

    // 1) Datum
    final d = e.day;
    final dateCell = pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        if (tentative)
          pw.Container(
            margin: const pw.EdgeInsets.only(bottom: 3),
            padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 1.5),
            decoration: pw.BoxDecoration(
              color: _amberBg,
              border: pw.Border.all(
                color: _amber,
                width: 0.75,
                style: pw.BorderStyle.dashed,
              ),
              borderRadius: pw.BorderRadius.circular(1.5),
            ),
            child: pw.Text(
              '? FRAGLICH',
              style: pw.TextStyle(
                fontSize: px(8),
                fontWeight: pw.FontWeight.bold,
                color: _amberText,
                letterSpacing: px(8) * 0.1,
              ),
            ),
          ),
        // „DONNERSTAG" passt sonst nicht in die schmale Datumsspalte.
        pw.FittedBox(
          fit: pw.BoxFit.scaleDown,
          alignment: pw.Alignment.centerLeft,
          child: pw.Text(
            d == null
                ? ''
                : _safe(DateFormat('EEEE', 'de_DE').format(d).toUpperCase()),
            style: labelStyle.copyWith(
              fontWeight: pw.FontWeight.bold,
              letterSpacing: px(9) * 0.1,
            ),
          ),
        ),
        pw.SizedBox(height: 2),
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            pw.Text(
              d == null ? '-' : '${d.day}',
              style: pw.TextStyle(
                fontSize: px(20),
                fontWeight: pw.FontWeight.bold,
                color: c(_title),
                fontStyle: italic,
              ),
            ),
            pw.SizedBox(width: px(6)),
            pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 1.5),
              child: pw.Text(
                d == null
                    ? ''
                    : _safe(
                        '${DateFormat('MMM', 'de_DE').format(d)} '
                                '${DateFormat('yy').format(d)}'
                            .toUpperCase(),
                      ),
                style: labelStyle.copyWith(
                  fontWeight: pw.FontWeight.bold,
                  letterSpacing: px(9) * 0.05,
                ),
              ),
            ),
          ],
        ),
      ],
    );

    // 2) Treffpunkt
    final meetT = visiblePrepTime(e.meetTime);
    final meetCell = pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        if (meetT != null) pw.Text('$meetT Uhr', style: dataStyle),
        if (e.meetLocation?.trim().isNotEmpty ?? false) ...[
          if (meetT != null) pw.SizedBox(height: 3),
          pw.Text(_safe(e.meetLocation!.trim()), style: bodyStyle),
        ],
      ],
    );

    // 3) Anlass / Details
    final opp = e.opponent?.trim();
    final anlassCell = pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.RichText(
          text: pw.TextSpan(
            children: [
              pw.TextSpan(
                text: _safe(e.anlassLabel.toUpperCase()),
                style: anlassStyle,
              ),
              if (e.isSpiel) ...[
                pw.TextSpan(
                  text: '  vs. ',
                  style: pw.TextStyle(
                    fontSize: px(11.5),
                    color: _gray600,
                    fontStyle: italic,
                  ),
                ),
                if (opp != null && opp.isNotEmpty)
                  pw.TextSpan(text: _safe(opp), style: dataStyle),
              ],
            ],
          ),
        ),
        if (e.zusatz != null) ...[
          pw.SizedBox(height: 3),
          pw.Text(
            _safe(e.zusatz!),
            style: pw.TextStyle(
              fontSize: px(12),
              color: c(_ink600),
              fontStyle: italic,
            ),
          ),
        ],
        if (e.isAway && (e.address?.trim().isNotEmpty ?? false)) ...[
          pw.SizedBox(height: 3),
          pw.Text(
            _safe(e.address!.trim()),
            style: pw.TextStyle(
              fontSize: px(11),
              color: c(_ink600),
              fontStyle: pw.FontStyle.italic,
            ),
          ),
        ],
      ],
    );

    // 4) Heim / Auswärts
    final venueCell = (e.isSpiel && e.venue != null)
        ? pw.Text(_safe(e.venue!.label.toUpperCase()), style: anlassStyle)
        : pw.SizedBox();

    // 5) Beginn
    final startT = visiblePrepTime(e.time);
    final startCell = startT != null
        ? pw.Text('$startT Uhr', style: dataStyle)
        : pw.SizedBox();

    return pw.TableRow(
      decoration: pw.BoxDecoration(color: tint),
      verticalAlignment: pw.TableCellVerticalAlignment.full,
      children: [
        cell(dateCell, first: true),
        cell(meetCell),
        cell(anlassCell),
        cell(venueCell),
        cell(startCell, lastCol: true),
      ],
    );
  }

  // ----------------------------------------------------------------- Bilanz
  static pw.Widget _stats(List<PrepPlanEntry> entries) {
    bool spiel(PrepPlanEntry e) => e.anlass == PrepAnlass.spiel;
    final total = entries.length;
    final home = entries
        .where((e) => spiel(e) && e.venue == PrepVenue.home)
        .length;
    final away = entries
        .where((e) => spiel(e) && e.venue == PrepVenue.away)
        .length;
    final open = entries
        .where((e) => spiel(e) && (e.venue == PrepVenue.open || e.venue == null))
        .length;
    final training = entries
        .where((e) => e.anlass == PrepAnlass.training)
        .length;
    final sonst = entries
        .where((e) => e.anlass == PrepAnlass.sonstiges)
        .length;
    final fraglich = entries.where((e) => e.tentative).length;

    pw.Widget card(
      String label,
      String value, {
      String? sub,
      required PdfColor bg,
      required PdfColor border,
      bool dashed = false,
      PdfColor? labelColor,
    }) => pw.Expanded(
      child: pw.Container(
        margin: const pw.EdgeInsets.symmetric(horizontal: 3),
        padding: pw.EdgeInsets.symmetric(horizontal: px(8), vertical: px(6)),
        decoration: pw.BoxDecoration(
          color: bg,
          border: pw.Border.all(
            color: border,
            width: 0.75,
            style: dashed ? pw.BorderStyle.dashed : pw.BorderStyle.solid,
          ),
          borderRadius: pw.BorderRadius.circular(3),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.FittedBox(
              fit: pw.BoxFit.scaleDown,
              alignment: pw.Alignment.centerLeft,
              child: pw.Text(
                label.toUpperCase(),
                style: pw.TextStyle(
                  fontSize: px(8),
                  fontWeight: pw.FontWeight.bold,
                  color: labelColor ?? _gray,
                  letterSpacing: px(8) * 0.08,
                ),
              ),
            ),
            pw.SizedBox(height: 2),
            pw.Text(
              value,
              style: pw.TextStyle(
                fontSize: px(18),
                fontWeight: pw.FontWeight.bold,
                color: _title,
              ),
            ),
            if (sub != null)
              pw.Text(
                sub,
                style: pw.TextStyle(
                  fontSize: px(8.5),
                  fontWeight: pw.FontWeight.bold,
                  color: _gray600,
                ),
              ),
          ],
        ),
      ),
    );

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.Container(
          padding: const pw.EdgeInsets.only(bottom: 3),
          margin: const pw.EdgeInsets.only(bottom: 6),
          decoration: const pw.BoxDecoration(
            border: pw.Border(bottom: pw.BorderSide(color: _pitch700, width: 1.5)),
          ),
          child: pw.Text(
            'VORBEREITUNGSBILANZ',
            style: pw.TextStyle(
              fontSize: px(11),
              fontWeight: pw.FontWeight.bold,
              color: _pitch800,
              letterSpacing: px(11) * 0.08,
            ),
          ),
        ),
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            card(
              'Termine gesamt',
              '$total',
              bg: const PdfColor.fromInt(0xFFF9FAFB),
              border: _line,
            ),
            card(
              'Spiele',
              '${home + away + open}',
              sub: '$home H · $away A${open > 0 ? ' · $open O' : ''}',
              bg: _rowHome,
              border: const PdfColor.fromInt(0xFF86EFAC),
            ),
            card(
              'Trainingseinheiten',
              '$training',
              bg: _rowTraining,
              border: const PdfColor.fromInt(0xFF93C5FD),
            ),
            card(
              'Sondertermine',
              '$sonst',
              bg: _rowAway,
              border: const PdfColor.fromInt(0xFFFDE68A),
            ),
            card(
              'Heim / Auswärts',
              '$home / $away',
              bg: const PdfColor.fromInt(0xFFF9FAFB),
              border: _line,
            ),
            card(
              '? Fraglich',
              '$fraglich',
              bg: _amberBg,
              border: _amber,
              dashed: true,
              labelColor: _amberText,
            ),
          ],
        ),
      ],
    );
  }

  // -------------------------------------------------------------- Rich-Text
  /// Quill-Delta-JSON (oder Klartext) → PDF-Absätze mit Fett/Kursiv/
  /// Unterstrichen, Schriftfarbe, Hintergrund, Größe und Listen.
  static pw.Widget? _richText(String? stored) {
    final raw = stored?.trim() ?? '';
    if (raw.isEmpty) return null;
    List<dynamic> ops;
    try {
      final d = jsonDecode(raw);
      ops = d is List ? d : [{'insert': '$raw\n'}];
    } catch (_) {
      ops = [{'insert': raw.endsWith('\n') ? raw : '$raw\n'}];
    }

    const base = 11 * 0.75;
    final lines = <(List<pw.InlineSpan>, Map<String, dynamic>)>[];
    var current = <pw.InlineSpan>[];
    for (final op in ops) {
      if (op is! Map) continue;
      final ins = op['insert'];
      if (ins is! String) continue;
      final attrs = (op['attributes'] is Map)
          ? Map<String, dynamic>.from(op['attributes'] as Map)
          : const <String, dynamic>{};
      final parts = ins.split('\n');
      for (var i = 0; i < parts.length; i++) {
        final t = parts[i];
        if (t.isNotEmpty) current.add(_span(t, attrs, base));
        if (i < parts.length - 1) {
          // Zeilenende: Zeilen-Attribute hängen am "\n".
          lines.add((current, attrs));
          current = <pw.InlineSpan>[];
        }
      }
    }
    if (current.isNotEmpty) lines.add((current, const {}));
    // Leere Schlusszeilen weg.
    while (lines.isNotEmpty && lines.last.$1.isEmpty) {
      lines.removeLast();
    }
    if (lines.isEmpty) return null;

    var ordered = 0;
    final children = <pw.Widget>[];
    for (final (spans, la) in lines) {
      final list = la['list'];
      String? bullet;
      if (list == 'bullet') {
        bullet = '•';
        ordered = 0;
      } else if (list == 'ordered') {
        ordered++;
        bullet = '$ordered.';
      } else if (list == 'checked' || list == 'unchecked') {
        bullet = list == 'checked' ? '[x]' : '[ ]';
        ordered = 0;
      } else {
        ordered = 0;
      }
      final text = pw.RichText(
        text: pw.TextSpan(
          style: const pw.TextStyle(fontSize: base, color: _ink700),
          children: spans.isEmpty ? [const pw.TextSpan(text: ' ')] : spans,
        ),
      );
      children.add(
        bullet == null
            ? text
            : pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.SizedBox(
                    width: 14,
                    child: pw.Text(
                      bullet,
                      style: const pw.TextStyle(fontSize: base, color: _ink700),
                    ),
                  ),
                  pw.Expanded(child: text),
                ],
              ),
      );
    }
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: children,
    );
  }

  static pw.TextSpan _span(String t, Map<String, dynamic> a, double base) {
    PdfColor? col(Object? v) {
      if (v is! String || !v.startsWith('#')) return null;
      try {
        return PdfColor.fromHex(v);
      } catch (_) {
        return null;
      }
    }

    final size = switch (a['size']) {
      'small' => base * 0.85,
      'large' => base * 1.3,
      'huge' => base * 1.6,
      final num n => n * 0.75,
      final String s when double.tryParse(s) != null =>
        double.parse(s) * 0.75,
      _ => null,
    };
    return pw.TextSpan(
      text: _safe(t),
      style: pw.TextStyle(
        fontWeight: a['bold'] == true ? pw.FontWeight.bold : null,
        fontStyle: a['italic'] == true ? pw.FontStyle.italic : null,
        decoration: a['underline'] == true ? pw.TextDecoration.underline : null,
        color: col(a['color']),
        background: col(a['background']) == null
            ? null
            : pw.BoxDecoration(color: col(a['background'])),
        fontSize: size,
      ),
    );
  }

  /// Die eingebaute Helvetica kennt nur Latin-1: typografische Zeichen
  /// ersetzen, alles Übrige (z. B. Emojis) entfernen.
  static String _safe(String s) {
    const map = {
      '„': '"', '“': '"', '”': '"', '‚': "'", '‘': "'", '’': "'",
      '–': '-', '—': '-', '…': '...', '•': '·', '€': 'EUR', ' ': ' ',
    };
    final b = StringBuffer();
    for (final r in s.runes) {
      final ch = String.fromCharCode(r);
      final m = map[ch];
      if (m != null) {
        b.write(m);
      } else if (r == 10 || (r >= 32 && r <= 126) || (r >= 160 && r <= 255)) {
        b.write(ch);
      }
    }
    return b.toString();
  }
}

/// Plan als WhatsApp-Text (wie im Coach Studio): je Tag eine Trennlinie,
/// je Termin Anlass, Treffpunkt, Beginn, Adresse, Vermerk.
String prepPlanWhatsAppText(PrepPlan plan, {String? teamName}) {
  final lines = <String>['*${plan.title.isEmpty ? 'Vorbereitungsplan' : plan.title}*'];
  if (plan.subtitle?.trim().isNotEmpty ?? false) {
    lines.add('_${plan.subtitle!.trim()}_');
  }
  if (teamName != null) lines.add(teamName);
  final hint = richToWhatsApp(plan.hint);
  if (hint.isNotEmpty) lines.addAll(['', hint]);
  lines.add('');

  final sorted = [...plan.entries]..sort((a, b) => a.date.compareTo(b.date));
  var lastDate = '';
  const divider = '━━━━━━━━━━━━━━━━━━━━━';
  for (final e in sorted) {
    if (e.date != lastDate) {
      if (lastDate.isNotEmpty) lines.add('');
      lines.add(divider);
      final d = e.day;
      lines.add(
        d == null
            ? '*${e.date}*'
            : '*${DateFormat('EEE, dd.MM.', 'de_DE').format(d)}*',
      );
      lines.add('');
      lastDate = e.date;
    }
    String headline;
    if (e.isSpiel) {
      final tag = switch (e.venue) {
        PrepVenue.home => '🏠 *HEIMSPIEL*',
        PrepVenue.away => '✈️ *AUSWÄRTSSPIEL*',
        PrepVenue.open => '*Spiel (Venue offen)*',
        null => '*Spiel*',
      };
      final opp = e.opponent?.trim();
      headline = (opp != null && opp.isNotEmpty) ? '$tag vs. *$opp*' : tag;
    } else if (e.anlass == PrepAnlass.training) {
      final extra = e.customAnlassLabel?.trim();
      headline = (extra != null &&
              extra.isNotEmpty &&
              extra.toLowerCase() != 'training')
          ? '*Training* _($extra)_'
          : '*Training*';
    } else {
      headline = '*${e.anlassLabel}*';
    }
    if (e.tentative) headline += '  ❓ _fraglich_';
    lines.add('• $headline');
    final meetT = visiblePrepTime(e.meetTime);
    final startT = visiblePrepTime(e.time);
    final loc = e.meetLocation?.trim() ?? '';
    if (meetT != null || loc.isNotEmpty) {
      lines.add(
        '   Treffpunkt: ${[if (meetT != null) '*$meetT Uhr*', if (loc.isNotEmpty) loc].join(' · ')}',
      );
    }
    if (startT != null) lines.add('   Beginn: *$startT Uhr*');
    if (e.address?.trim().isNotEmpty ?? false) {
      lines.add('   Adresse: ${e.address!.trim()}');
    }
    if (e.notes?.trim().isNotEmpty ?? false) {
      lines.add('   _${e.notes!.trim()}_');
    }
  }
  final footer = richToWhatsApp(plan.footerText);
  if (footer.isNotEmpty) lines.addAll(['', footer]);
  return lines.join('\n');
}

/// Rich-Text (Quill-Delta oder Klartext) → WhatsApp-Markdown.
String richToWhatsApp(String? stored) {
  final raw = stored?.trim() ?? '';
  if (raw.isEmpty) return '';
  List<dynamic> ops;
  try {
    final d = jsonDecode(raw);
    if (d is! List) return raw;
    ops = d;
  } catch (_) {
    return raw;
  }
  final out = StringBuffer();
  var line = StringBuffer();
  var ordered = 0;
  for (final op in ops) {
    if (op is! Map || op['insert'] is! String) continue;
    final a = op['attributes'] is Map
        ? Map<String, dynamic>.from(op['attributes'] as Map)
        : const <String, dynamic>{};
    final parts = (op['insert'] as String).split('\n');
    for (var i = 0; i < parts.length; i++) {
      var t = parts[i];
      if (t.trim().isNotEmpty) {
        if (a['bold'] == true) t = '*$t*';
        if (a['italic'] == true) t = '_${t}_';
      }
      line.write(t);
      if (i < parts.length - 1) {
        final list = a['list'];
        if (list == 'bullet') {
          out.writeln('• $line');
          ordered = 0;
        } else if (list == 'ordered') {
          ordered++;
          out.writeln('$ordered. $line');
        } else {
          ordered = 0;
          out.writeln(line.toString());
        }
        line = StringBuffer();
      }
    }
  }
  if (line.isNotEmpty) out.write(line.toString());
  return out.toString().replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}
