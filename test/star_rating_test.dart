import 'package:coach_companion/widgets/star_rating.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<List<double>> tapStar(WidgetTester tester, int star, bool left) async {
    final taps = <double>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: StarRating(value: 0, size: 30, onTap: taps.add),
          ),
        ),
      ),
    );
    final box = tester.getRect(find.byKey(ValueKey('star_$star')));
    final x = left ? box.left + box.width * 0.25 : box.left + box.width * 0.75;
    await tester.tapAt(Offset(x, box.center.dy));
    return taps;
  }

  testWidgets('Linke Sternhälfte = halber Stern', (tester) async {
    expect(await tapStar(tester, 4, true), [3.5]);
  });

  testWidgets('Rechte Sternhälfte = ganzer Stern', (tester) async {
    expect(await tapStar(tester, 4, false), [4.0]);
  });

  testWidgets('Erster Stern links = 0,5', (tester) async {
    expect(await tapStar(tester, 1, true), [0.5]);
  });

  testWidgets('Anzeige: halber Stern', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: StarDisplay(value: 3.4))),
    );
    expect(find.byIcon(Icons.star), findsNWidgets(3));
    expect(find.byIcon(Icons.star_half), findsOneWidget);
    expect(find.byIcon(Icons.star_border), findsOneWidget);
  });

  test('halfStars/starNumber', () {
    expect(halfStars(3.74), 3.5);
    expect(halfStars(3.76), 4.0);
    expect(halfStars(7), 5.0);
    expect(starNumber(3.5), '3,5');
    expect(starNumber(4), '4');
  });
}
