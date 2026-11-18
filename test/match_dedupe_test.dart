import 'dart:io';

import 'package:coach_companion/data/app_database.dart';
import 'package:coach_companion/data/coach_repository.dart';
import 'package:coach_companion/models/enums.dart';
import 'package:coach_companion/models/match.dart';
import 'package:coach_companion/models/nomination.dart';
import 'package:coach_companion/models/player.dart';
import 'package:coach_companion/models/team.dart';
import 'package:coach_companion/services/fupa/fupa_dtos.dart';
import 'package:coach_companion/services/fupa/fupa_persistence.dart';
import 'package:coach_companion/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;
  late CoachRepository repo;
  const slug = 'garather-sv-m1-sv-hilden-ost-m2-261119';
  final kickoff = DateTime(2026, 11, 19, 19, 30);

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('cc_dedupe');
    repo = CoachRepository(
      db: AppDatabase.test(path: p.join(dir.path, 'test.db')),
    );
    await repo.upsertTeam(
      Team(
        id: 'own',
        name: 'Garather SV',
        isOwnTeam: true,
        source: DataSource.manual,
        createdAt: DateTime(2026),
      ),
    );
    await repo.upsertPlayer(
      Player(
        id: 'p1',
        teamId: 'own',
        firstName: 'Test',
        lastName: 'Spieler',
        createdAt: DateTime(2026),
      ),
    );
  });
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  GameMatch match(String id, {String? opp, String? slugV}) => GameMatch(
    id: id,
    ownTeamId: 'own',
    opponentName: opp ?? 'SV Hilden-Ost',
    kickoff: kickoff,
    fupaMatchSlug: slugV ?? slug,
    createdAt: DateTime(2026, 11, 18),
  );

  test('Spielplan-Import erkennt Cloud-Spiel am FuPa-Slug', () async {
    // Kam von einem anderen Gerät: kein external_id, abweichender Name.
    await repo.upsertMatch(match('cloud-1', opp: 'Hilden Ost 2'));
    final added = await FupaPersistence(repo).syncSchedule('own', [
      ScheduledMatchData(
        opponentName: 'SV Hilden-Ost',
        kickoff: kickoff,
        externalId: 'ext-1',
        fupaMatchSlug: slug,
        competition: 'Testspiele',
      ),
    ]);
    expect(added, 0);
    final all = await repo.getMatches('own');
    expect(all, hasLength(1));
    expect(all.single.externalId, 'ext-1');
  });

  test('leeres Duplikat wird entfernt, Spiel mit Inhalt bleibt', () async {
    await repo.upsertMatch(match('aaa'));
    await repo.upsertMatch(match('zzz'));
    await repo.upsertNomination(
      Nomination(
        id: 'n1',
        matchId: 'zzz',
        playerId: 'p1',
        status: NominationStatus.zugesagt,
        updatedAt: DateTime.now(),
      ),
    );
    final removed = await AppState(repository: repo).dedupeFupaMatches('own');
    expect(removed, 1);
    final all = await repo.getMatches('own');
    expect(all.map((m) => m.id), ['zzz']);
  });

  test('ohne Inhalte bleibt deterministisch die kleinste ID', () async {
    await repo.upsertMatch(match('bbb'));
    await repo.upsertMatch(match('aaa'));
    await repo.upsertMatch(match('ccc', slugV: 'anderes-spiel'));
    final removed = await AppState(repository: repo).dedupeFupaMatches('own');
    expect(removed, 1);
    final ids = (await repo.getMatches('own')).map((m) => m.id).toSet();
    expect(ids, {'aaa', 'ccc'});
  });
}
