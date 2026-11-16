import 'package:coach_companion/models/graphic_anim.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Einblenden: Start unsichtbar, Ende voll da', () {
    final e = ElementAnim(fx: 'slideUp', start: 1, len: 0.5);
    final a = animState(e, 0.5);
    expect(a.opacity, 0);
    expect(a.offset.dy, greaterThan(0));
    final b = animState(e, 2);
    expect(b.opacity, 1);
    expect(b.offset.dy, closeTo(0, 1e-9));
    expect(animState(null, 0).opacity, 1);
  });

  test('Pop endet bei Skalierung 1', () {
    final e = ElementAnim(fx: 'pop', start: 0, len: 0.5);
    expect(animState(e, 0).scale, closeTo(0, 1e-9));
    expect(animState(e, 0.5).scale, closeTo(1, 1e-9));
  });

  test('Zähler: hochzählen und rollen enden exakt', () {
    final up = ElementAnim(count: 'up', start: 0, len: 2);
    expect(countText('100', up, 0), '0');
    final mid = int.parse(countText('100', up, 1));
    expect(mid, inInclusiveRange(1, 99));
    expect(countText('100', up, 2), '100');

    final roll = ElementAnim(count: 'roll', start: 0.5, len: 1.5);
    expect(countText('6:1', roll, 2.0), '6:1');
    expect(countText('6 - 1', roll, 5), '6 - 1');
    // Während des Rollens: gleiche Form, deterministisch.
    final r1 = countText('6:1', roll, 1, seed: 'x');
    expect(r1, matches(RegExp(r'^\d+:\d+$')));
    expect(countText('6:1', roll, 1, seed: 'x'), r1);
    expect(countText('ohne Zahl', roll, 1), 'ohne Zahl');
  });

  test('Glanz und Hintergrund', () {
    final e = ElementAnim(shine: true, start: 0, len: 0.5);
    expect(shineAt(e, 0.2), isNull);
    expect(shineAt(e, 0.5), closeTo(-0.3, 1e-9));
    expect(shineAt(e, 2), isNull);
    expect(bgTransform('zoom', 8, 8).scale, closeTo(1.08, 1e-9));
    expect(bgTransform('none', 3, 8).scale, 1);
  });

  test('Vorlagen staffeln und erkennen Zahlen', () {
    final a = applyPreset('stagger', [
      (id: 'headline', type: 'text', text: 'HEIMSPIEL'),
      (id: 'logos', type: 'logo', text: null),
      (id: 'text_1', type: 'text', text: '100'),
    ], kind: 'Spieltag');
    expect(a.bg, 'zoom');
    expect(a.items['headline']!.start, closeTo(0.2, 1e-9));
    expect(a.items['logos']!.fx, 'pop');
    expect(a.items['text_1']!.count, 'up');
    expect(a.items['text_1']!.start, greaterThan(a.items['logos']!.start));
    final r = applyPreset('reveal', [
      (id: 'std_score', type: 'score', text: null),
    ], kind: 'Ergebnis');
    expect(r.items['std_score']!.count, 'roll');
  });

  test('JSON und KI-Antwort werden streng gelesen', () {
    final a = applyPreset(
      'zoom',
      [(id: 'a', type: 'text', text: 'X')],
      kind: 'Spieltag',
      seconds: 10,
    );
    final b = GraphicAnim.fromJson(a.toJson());
    expect(b.seconds, 10);
    expect(b.items['a']!.fx, 'zoomIn');
    final ai = GraphicAnim.fromJson(
      {
        'bg': 'wackel',
        'items': {
          'a': {'fx': 'pop', 'start': 99, 'count': 'up'},
          'fremd': {'fx': 'fade'},
          'b': {'fx': 'quatsch'},
        },
      },
      ids: {'a', 'b'},
      seconds: 8,
    );
    expect(ai.bg, 'none');
    expect(ai.items.keys, ['a']);
    expect(ai.items['a']!.start, lessThanOrEqualTo(8));
  });
}
