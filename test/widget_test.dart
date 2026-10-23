import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:coach_companion/theme.dart';

void main() {
  testWidgets('App-Theme baut ohne Fehler', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: const Scaffold(body: Center(child: Text('Coach Companion'))),
    ));
    expect(find.text('Coach Companion'), findsOneWidget);
  });
}
