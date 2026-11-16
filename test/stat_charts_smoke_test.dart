import 'package:coach_companion/widgets/stat_charts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Balken und Verlauf rendern ohne Fehler', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: const [
              StatBarList(
                items: [
                  StatBarItem(label: 'A', value: 3, text: '3'),
                  StatBarItem(label: 'B', value: -1, text: '-1'),
                  StatBarItem(label: 'C', value: null, text: '–'),
                ],
              ),
              StatLineChart(
                xLabels: ['01.09.', '08.09.', '15.09.'],
                series: [
                  StatLineSeries(
                    label: 'A',
                    color: Colors.green,
                    values: [1, null, 2.5],
                  ),
                  StatLineSeries(
                    label: 'B',
                    color: Colors.red,
                    values: [0, 0, 0],
                  ),
                ],
                decimals: 2,
              ),
              StatLineChart(xLabels: ['x'], series: []),
            ],
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('A'), findsWidgets);
  });
}
