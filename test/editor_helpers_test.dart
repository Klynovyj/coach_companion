import 'package:coach_companion/models/editor_helpers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DesignHistory', () {
    test('merkt Schritte und geht zurück/vor', () {
      final h = DesignHistory()..reset('a');
      expect(h.canUndo, isFalse);
      expect(h.record('a'), isFalse); // unverändert → kein Schritt
      expect(h.record('b'), isTrue);
      expect(h.record('c'), isTrue);
      expect(h.undo(), 'b');
      expect(h.undo(), 'a');
      expect(h.undo(), isNull);
      expect(h.redo(), 'b');
      expect(h.current, 'b');
      expect(h.canRedo, isTrue);
    });

    test('neue Änderung nach Rückgängig verwirft Wiederholen', () {
      final h = DesignHistory()..reset('a');
      h.record('b');
      h.undo();
      h.record('x');
      expect(h.canRedo, isFalse);
      expect(h.undo(), 'a');
    });

    test('replaceCurrent legt keinen Schritt an', () {
      final h = DesignHistory()..reset('a');
      h.record('b');
      h.undo();
      h.replaceCurrent('a2'); // normalisierter Stand nach dem Einspielen
      expect(h.canRedo, isTrue);
      expect(h.redo(), 'b');
      expect(h.undo(), 'a2');
    });

    test('Kappung auf limit', () {
      final h = DesignHistory(limit: 3)..reset('0');
      for (var i = 1; i <= 6; i++) {
        h.record('$i');
      }
      var n = 0;
      while (h.undo() != null) {
        n++;
      }
      expect(n, 3);
      expect(h.current, '3');
    });
  });

  group('snapAxis', () {
    test('rastet die Mitte an der Mittellinie ein', () {
      final r = snapAxis(center: 176, half: 20, centerLines: [180]);
      expect(r.offset, 4);
      expect(r.line, 180);
    });

    test('außerhalb der Schwelle passiert nichts', () {
      final r = snapAxis(center: 170, half: 20, centerLines: [180]);
      expect(r.offset, 0);
      expect(r.line, isNull);
    });

    test('Kanten rasten an Randlinien, nächste gewinnt', () {
      // linke Kante bei 18 → Rand 16 (−2); Mitte 38 → Linie 43 (+5)
      final r = snapAxis(
        center: 38,
        half: 20,
        centerLines: [43],
        edgeLines: [16, 344],
      );
      expect(r.offset, -2);
      expect(r.line, 16);
    });
  });
}
