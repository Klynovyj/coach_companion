import 'package:coach_companion/widgets/panel_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Schalter sitzen bei kurzem und langem Titel bündig rechts', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(380, 600));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              PanelSwitch(title: 'Kurz', value: true, onChanged: (_) {}),
              PanelSwitch(
                title: 'Ein deutlich längerer Titel mit Erklärung',
                info: 'Hilfe',
                value: false,
                onChanged: (_) {},
              ),
            ],
          ),
        ),
      ),
    );
    final switches = find.byType(Switch);
    expect(switches, findsNWidgets(2));
    final a = tester.getTopRight(switches.at(0));
    final b = tester.getTopRight(switches.at(1));
    expect(a.dx, b.dx);
    expect(a.dx, closeTo(380, 1));
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('Kachel zeigt Auswahl mit Haken', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PanelTiles(
            children: [
              PanelTile(
                preview: const ColoredBox(color: Colors.green),
                label: 'Grün',
                selected: true,
                onTap: () {},
              ),
              PanelTile(
                preview: const ColoredBox(color: Colors.black),
                label: 'Schwarz',
                selected: false,
                onTap: () {},
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.byIcon(Icons.check), findsOneWidget);
    expect(find.text('Grün'), findsOneWidget);
  });
}
