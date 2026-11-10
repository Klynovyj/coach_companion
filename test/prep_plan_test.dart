import 'dart:convert';
import 'dart:io';

import 'package:coach_companion/models/prep_plan.dart';
import 'package:coach_companion/services/prep_plan_pdf.dart';
import 'package:coach_companion/services/studio_plan_import.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  setUpAll(() => initializeDateFormatting('de_DE'));

  final plan = PrepPlan(
    id: 'plan-1',
    title: 'Vorbereitungsplan Sommer',
    subtitle: 'Saison 26 / 27',
    hint: 'Trainingsstätte noch in Klärung!',
    entries: const [
      PrepPlanEntry(
        id: 'e1',
        date: '2026-07-07',
        anlass: PrepAnlass.sonstiges,
        customAnlassLabel: 'Mannschaftsheim – Präsentation',
        meetTime: '18:45',
        time: '19:00',
        meetLocation: 'Mannschaftsheim',
      ),
      PrepPlanEntry(
        id: 'e2',
        date: '2026-07-07',
        anlass: PrepAnlass.training,
        time: '19:30',
        meetTime: '00:00',
      ),
      PrepPlanEntry(
        id: 'e3',
        date: '2026-07-12',
        anlass: PrepAnlass.spiel,
        opponent: 'TSV Urdenbach',
        venue: PrepVenue.away,
        address: 'Sportanlage Urdenbach',
        tentative: true,
      ),
      PrepPlanEntry(
        id: 'e4',
        date: '2026-07-14',
        anlass: PrepAnlass.sonstiges,
        customAnlassLabel: 'Mannschaftsfoto',
      ),
    ],
  );

  test('JSON hin und zurück (inkl. Altbestand grillen)', () {
    final legacy = PrepPlanEntry.fromJson({
      'id': 'x',
      'date': '2026-07-01',
      'anlass': 'grillen',
    });
    expect(legacy.anlass, PrepAnlass.sonstiges);
    expect(legacy.anlassLabel, 'Grillen');
    final back = PrepPlan.fromJson(jsonDecode(jsonEncode(plan.toJson())));
    expect(back.entries.length, plan.entries.length);
    expect(back.entries[2].venue, PrepVenue.away);
    expect(back.entries[2].tentative, isTrue);
    expect(visiblePrepTime(back.entries[1].meetTime), isNull);
  });

  test('WhatsApp-Text', () {
    final t = prepPlanWhatsAppText(plan, teamName: 'Garather SV');
    expect(t, contains('*Vorbereitungsplan Sommer*'));
    expect(t, contains('✈️ *AUSWÄRTSSPIEL* vs. *TSV Urdenbach*'));
    expect(t, contains('❓ _fraglich_'));
    expect(t, isNot(contains('00:00')));
  });

  test('HTML aus Coach Studio → Klartext', () {
    expect(StudioPlanImport.htmlToPlain('<br>'), '');
    expect(
      StudioPlanImport.htmlToPlain('<b>Wichtig</b><br>Zeile&nbsp;2'),
      'Wichtig\nZeile 2',
    );
  });

  test('PDF wird erzeugt', () async {
    var p = plan;
    // Optional: echten Studio-Plan rendern (PREP_PLAN_JSON) und das PDF
    // ablegen (PREP_PDF_OUT) – zur Sichtprüfung.
    final src = Platform.environment['PREP_PLAN_JSON'];
    if (src != null) {
      final j = jsonDecode(File(src).readAsStringSync()) as Map<String, dynamic>;
      p = PrepPlan.fromJson(j).copyWith(
        hint: StudioPlanImport.htmlToPlain(j['hint'] as String?),
        footerText: StudioPlanImport.htmlToPlain(j['footerText'] as String?),
      );
    }
    final logo = Platform.environment['PREP_LOGO'];
    final bytes = await PrepPlanPdf.build(
      plan: p,
      teamName: 'Garather SV',
      logo: logo == null ? null : File(logo).readAsBytesSync(),
    );
    expect(bytes.length, greaterThan(1000));
    final out = Platform.environment['PREP_PDF_OUT'];
    if (out != null) File(out).writeAsBytesSync(bytes);
  });
}
