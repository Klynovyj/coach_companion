import 'dart:convert';
import 'dart:typed_data';

import 'package:coach_companion/models/sponsor.dart';
import 'package:coach_companion/screens/startelf_graphic_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// Die ENDSTAND-Grafik muss in Story und Post ohne Layout-Fehler rendern und
/// Überschrift, Ergebnis und Torschützen zeigen.
void main() {
  const result = ResultData(
    ownScore: 6,
    oppScore: 2,
    ownGoals: [
      (minute: 35, name: '#7 Ben Kania', photo: null),
      (minute: 40, name: '#7 Ben Kania', photo: null),
      (minute: 82, name: 'Philipp Trappen', photo: null),
    ],
    oppGoals: [(minute: 48, name: 'Gegner', photo: null)],
  );

  Future<void> pump(WidgetTester tester, Widget g, Size s) => tester.pumpWidget(
    MaterialApp(
      home: Center(
        child: SizedBox(width: s.width, height: s.height, child: g),
      ),
    ),
  );

  for (final story in [true, false]) {
    testWidgets('ENDSTAND ${story ? 'Story' : 'Post'} ohne Fehler', (t) async {
      await pump(
        t,
        debugGraphicForTest(result: result, compact: !story),
        Size(360, story ? 640 : 360),
      );
      expect(t.takeException(), isNull);
      expect(find.text('ENDSTAND'), findsOneWidget);
      expect(find.text('6 - 2', findRichText: true), findsNothing); // Heim = Post SV
      expect(find.text('2 - 6'), findsOneWidget);
      expect(find.text('B. KANIA'), findsOneWidget);
    });
  }

  testWidgets('ENDSTAND ohne eigene Tore (0:3) ohne Fehler', (t) async {
    await pump(
      t,
      debugGraphicForTest(
        result: const ResultData(
          ownScore: 0,
          oppScore: 3,
          oppGoals: [(minute: 10, name: 'Gegner', photo: null)],
        ),
      ),
      const Size(360, 640),
    );
    expect(t.takeException(), isNull);
    expect(find.text('ENDSTAND'), findsOneWidget);
  });

  // Wie in der App: Logos, Haupt- und weitere Sponsoren, Foto oben.
  String png(int w, int h) {
    final im = img.Image(width: w, height: h)..clear(img.ColorRgb8(200, 30, 30));
    return 'data:image/png;base64,${base64Encode(Uint8List.fromList(img.encodePng(im)))}';
  }

  for (final story in [true, false]) {
    for (final circle in [true, false]) {
      testWidgets(
        'ENDSTAND mit Logos/Sponsoren/Foto ${story ? 'Story' : 'Post'} '
        '${circle ? 'rund' : 'eckig'}',
        (t) async {
          await pump(
            t,
            debugGraphicForTest(
              result: result,
              compact: !story,
              logo: png(40, 40),
              opponentLogo: png(30, 40),
              logoCircle: circle,
              mainSponsor: Sponsor(
                id: 'm',
                name: 'HeimSpiel',
                logo: png(90, 30),
                isMain: true,
              ),
              barSponsors: [Sponsor(id: 'b', name: 'Prematch', logo: png(30, 30))],
              ftPhoto: png(120, 80),
            ),
            Size(360, story ? 640 : 360),
          );
          await t.pump();
          expect(t.takeException(), isNull);
          expect(find.text('ENDSTAND'), findsOneWidget);
          expect(find.text('2 - 6'), findsOneWidget);
        },
      );
    }
  }

  testWidgets('Gezogene Kastengröße ohne Fehler', (t) async {
    await pump(
      t,
      debugGraphicForTest(
        result: result,
        boxSize: const {'std_ft_scorers': Size(300, 120)},
      ),
      const Size(360, 640),
    );
    expect(t.takeException(), isNull);
  });
}
