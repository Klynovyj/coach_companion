import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:coach_companion/data/app_database.dart';
import 'package:coach_companion/data/coach_repository.dart';
import 'package:coach_companion/models/enums.dart';
import 'package:coach_companion/state/app_state.dart';

void main() {
  late Directory dir;
  late String dbPath;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('cc_test');
    dbPath = p.join(dir.path, 'test.db');
  });
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  AppState open() =>
      AppState(repository: CoachRepository(db: AppDatabase.test(path: dbPath)));

  test('Events/Notizen/Termine überleben einen App-Neustart', () async {
    // Sitzung 1: Daten anlegen
    final db1 = AppDatabase.test(path: dbPath);
    final s1 = AppState(repository: CoachRepository(db: db1));
    await s1.init();
    final team = await s1.ensureOwnTeam();
    await s1.addPlayer(team.id, firstName: 'Max', lastName: 'Mustermann');
    final player = (await s1.playersOf(team.id)).first;
    final match = await s1.addMatch(opponentName: 'Gegner');

    await s1.addEvent(
        matchId: match.id,
        teamId: team.id,
        minute: 10,
        type: MatchEventType.goal,
        playerId: player.id);
    await s1.setNomination(match.id, player.id, NominationStatus.zugesagt);
    await s1.addNote(player.id, 'Beobachtung');
    await s1.addTeamEvent(
        title: 'Weihnachtsfeier',
        type: TeamEventType.feier,
        date: DateTime(2026, 12, 20));
    await db1.close();

    // Sitzung 2: neu öffnen und prüfen
    final db2 = AppDatabase.test(path: dbPath);
    final s2 = AppState(repository: CoachRepository(db: db2));
    await s2.init();

    // Zuerst: überleben die „Import"-artigen Daten den Neustart?
    expect(await s2.repository.getTeams(), isNotEmpty, reason: 'Team');
    expect(await s2.playersOf(team.id), isNotEmpty, reason: 'Spieler');
    expect(s2.matches, isNotEmpty, reason: 'Spiel');

    expect(await s2.eventsOf(match.id), hasLength(1), reason: 'Event');
    expect((await s2.nominationsOf(match.id))[player.id],
        NominationStatus.zugesagt,
        reason: 'Nominierung');
    expect(await s2.notesOf(player.id), hasLength(1), reason: 'Notiz');
    expect(await s2.teamEvents(), hasLength(1), reason: 'Termin');
    await db2.close();
  });

  test('REPLACE auf matches darf Events nicht per Cascade löschen', () async {
    final s = open();
    await s.init();
    final team = await s.ensureOwnTeam();
    await s.addPlayer(team.id, firstName: 'A', lastName: 'B');
    final player = (await s.playersOf(team.id)).first;
    final match = await s.addMatch(opponentName: 'G');

    await s.addEvent(
        matchId: match.id,
        teamId: team.id,
        minute: 5,
        type: MatchEventType.goal,
        playerId: player.id);

    // Nach addEvent (inkl. _recomputeScore -> upsertMatch) muss das Event bleiben.
    expect(await s.eventsOf(match.id), hasLength(1),
        reason: 'Event nach Spielstand-Update');

    // Noch ein Match-Update (wie bei erneutem Spielplan-Import)
    await s.updateMatch(match.copyWith(competition: 'Testliga'));
    expect(await s.eventsOf(match.id), hasLength(1),
        reason: 'Event nach weiterem Match-Update');
  });

  test('In einer Sitzung ist alles sofort lesbar', () async {
    final s = open();
    await s.init();
    final team = await s.ensureOwnTeam();
    await s.addPlayer(team.id, firstName: 'Lea', lastName: 'Vogt');
    final p0 = (await s.playersOf(team.id)).first;
    await s.addNote(p0.id, 'Hallo');
    expect(await s.notesOf(p0.id), hasLength(1));
    await s.addTeamEvent(
        title: 'Grillen', type: TeamEventType.grillen, date: DateTime.now());
    expect(await s.teamEvents(), hasLength(1));
  });

  test('Rubriken und zugeordnete Notizen überleben einen Neustart', () async {
    final db1 = AppDatabase.test(path: dbPath);
    final s1 = AppState(repository: CoachRepository(db: db1));
    await s1.init();
    final team = await s1.ensureOwnTeam();
    await s1.addPlayer(team.id, firstName: 'Nina', lastName: 'Keller');
    final player = (await s1.playersOf(team.id)).first;
    await s1.addNoteCategory('Taktik');
    final cat = (await s1.noteCategories()).single;
    await s1.addNote(player.id, 'Steht gut', categoryId: cat.id);
    await db1.close();

    final db2 = AppDatabase.test(path: dbPath);
    final s2 = AppState(repository: CoachRepository(db: db2));
    await s2.init();
    expect(await s2.noteCategories(), hasLength(1), reason: 'Rubrik');
    final note = (await s2.notesOf(player.id)).single;
    expect(note.categoryId, cat.id, reason: 'Notiz behält Rubrik');

    // Rubrik löschen: Notiz bleibt, aber ohne Rubrik.
    await s2.deleteNoteCategory(cat.id);
    expect(await s2.noteCategories(), isEmpty);
    final after = (await s2.notesOf(player.id)).single;
    expect(after.categoryId, isNull, reason: 'Notiz bleibt, Rubrik entkoppelt');
    await db2.close();
  });

  test('Gesamt-Bewertung ist der Durchschnitt über alle Spiele', () async {
    final s = open();
    await s.init();
    final team = await s.ensureOwnTeam();
    await s.addPlayer(team.id, firstName: 'Tom', lastName: 'Weber');
    final player = (await s.playersOf(team.id)).first;
    final m1 = await s.addMatch(opponentName: 'A');
    final m2 = await s.addMatch(opponentName: 'B');

    await s.setRating(matchId: m1.id, playerId: player.id, rating: 4);
    await s.setRating(matchId: m2.id, playerId: player.id, rating: 2);
    var (avg, count) = await s.ratingAverage(player.id);
    expect(count, 2);
    expect(avg, closeTo(3.0, 0.001), reason: 'Schnitt (4+2)/2');

    // Bewertung ändern (gleiches Spiel) → zählt nur einmal.
    await s.setRating(matchId: m1.id, playerId: player.id, rating: 5);
    (avg, count) = await s.ratingAverage(player.id);
    expect(count, 2, reason: 'weiterhin zwei Spiele');
    expect(avg, closeTo(3.5, 0.001), reason: 'Schnitt (5+2)/2');

    // Entfernen → fällt wieder.
    await s.removeRating(m2.id, player.id);
    (avg, count) = await s.ratingAverage(player.id);
    expect(count, 1);
    expect(avg, closeTo(5.0, 0.001));
  });
}
