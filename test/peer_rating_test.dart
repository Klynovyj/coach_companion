import 'dart:math';

import 'package:coach_companion/models/peer_rating.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Token: 24 Zeichen, URL-sicher, zufällig', () {
    final a = newPeerToken(Random(1));
    final b = newPeerToken(Random(2));
    expect(a.length, 24);
    expect(RegExp(r'^[A-Za-z0-9]+$').hasMatch(a), isTrue);
    expect(a, isNot(b));
    expect(newPeerToken().length, 24);
  });

  test('Link: Token hinter #', () {
    expect(
      peerRatingLink('abc'),
      'https://klynovyj.github.io/coach_companion/bewerten/#t=abc',
    );
  });

  test('PeerSummary.fromJson: Schnitte, Stimmen, Fehlende', () {
    final s = PeerSummary.fromJson({
      'match_id': 'm1',
      'closes_at': '2026-11-18T19:00:00+00:00',
      'open': true,
      'players': [
        {'id': 'p1', 'name': 'Ben Kania', 'number': 9},
        {'id': 'p2', 'name': 'Tim Test', 'number': null},
        {'id': 'p3', 'name': 'Max Muster', 'number': 4},
      ],
      'voters': ['p1', 'p3'],
      'avg': {
        'p1': {'avg': 4.5, 'n': 2},
        'p2': {'avg': 3, 'n': 1},
      },
      'motm': [
        {'id': 'p1', 'votes': 2},
        {'id': 'p2', 'votes': 1},
      ],
      'match_avg': 3.5,
      'match_n': 2,
      'match_notes': ['Starke 2. Halbzeit', '  '],
      'self': [
        {'id': 'p3', 'stars': 4, 'note': 'Gut'},
      ],
    });
    expect(s.open, isTrue);
    expect(s.closesAt.toUtc().hour, 19);
    expect(s.players.length, 3);
    expect(s.players[1].number, isNull);
    expect(s.voters, {'p1', 'p3'});
    expect(s.missing.map((p) => p.id), ['p2']);
    expect(s.avg['p1'], (4.5, 2));
    expect(s.avg['p2'], (3.0, 1));
    expect(s.motm.first, ('p1', 2));
    expect(s.matchAvg, 3.5);
    expect(s.matchCount, 2);
    expect(s.matchNotes, ['Starke 2. Halbzeit']);
    expect(s.self.single.stars, 4);
  });

  test('PeerSummary.fromJson: leere Runde', () {
    final s = PeerSummary.fromJson({
      'match_id': 'm2',
      'closes_at': '2026-11-18T19:00:00Z',
      'open': false,
      'players': [],
      'voters': [],
      'avg': {},
      'motm': [],
      'match_avg': null,
      'match_n': 0,
      'match_notes': [],
      'self': [],
    });
    expect(s.open, isFalse);
    expect(s.avg, isEmpty);
    expect(s.motm, isEmpty);
    expect(s.matchAvg, isNull);
  });

  test('PeerSelfEntry.fromJson', () {
    final e = PeerSelfEntry.fromJson({
      'match_id': 'm1',
      'title': 'GSV – Post SV 6:2',
      'match_date': '2026-11-15T13:00:00Z',
      'stars': 3,
      'note': ' ok ',
    });
    expect(e.title, 'GSV – Post SV 6:2');
    expect(e.matchDate?.year, 2026);
    expect(e.stars, 3);
    expect(e.note, 'ok');
  });

  test('PeerRoundPlayer: JSON hin und zurück', () {
    const p = PeerRoundPlayer(id: 'p1', name: 'Ben', number: 9);
    final q = PeerRoundPlayer.fromJson(p.toJson());
    expect(q.id, 'p1');
    expect(q.name, 'Ben');
    expect(q.number, 9);
  });
}
