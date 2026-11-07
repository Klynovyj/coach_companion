import 'package:coach_companion/models/designer_data.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Spielstand nach einem Tor zählt alle Tore bis dahin', () {
    final goals = [
      (minute: 10, own: true),
      (minute: 20, own: false),
      (minute: 35, own: true),
      (minute: 60, own: true),
    ];
    expect(scoreAfterGoal(goals, 0), (own: 1, opp: 0));
    expect(scoreAfterGoal(goals, 1), (own: 1, opp: 1));
    expect(scoreAfterGoal(goals, 2), (own: 2, opp: 1));
    expect(scoreAfterGoal(goals, 3), (own: 3, opp: 1));
  });

  test('DesignerData JSON hin und zurück', () {
    final d = DesignerData(
      id: 'designer:abc',
      template: 'goal',
      title: 'Tor Ben Kania',
      headline: 'TOR!',
      infoLine: "B. KANIA · 35' · 1:0",
      matchId: 'm1',
      playerPhoto: 'data:image/png;base64,AAA',
      opponentName: 'Post SV',
      isHome: false,
      matchDate: DateTime.utc(2026, 10, 25, 15),
    );
    final back = DesignerData.fromJson(d.toJson())!;
    expect(back.id, d.id);
    expect(back.template, 'goal');
    expect(back.title, 'Tor Ben Kania');
    expect(back.headline, 'TOR!');
    expect(back.infoLine, d.infoLine);
    expect(back.matchId, 'm1');
    expect(back.opponentName, 'Post SV');
    expect(back.isHome, isFalse);
    expect(back.matchDate, d.matchDate);
    // Startbild wird nicht ins JSON geschrieben (liegt im Design selbst).
    expect(back.playerPhoto, isNull);
  });

  test('FuPa-Foto: Vorlage + verknüpfter Spieler bleiben erhalten', () {
    const d = DesignerData(
      id: 'designer:f1',
      template: 'fupa',
      title: 'FuPa Ben Kania',
      playerId: 'p-7',
    );
    final back = DesignerData.fromJson(d.toJson())!;
    expect(back.template, 'fupa');
    expect(back.playerId, 'p-7');
    expect(back.templateLabel, 'FuPa-Foto');
    expect(DesignerData.templates, contains('fupa'));
  });

  test('Ungültiges JSON → null', () {
    expect(DesignerData.fromJson(null), isNull);
    expect(DesignerData.fromJson({'template': 'goal'}), isNull);
  });
}
