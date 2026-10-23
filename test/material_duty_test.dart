import 'package:flutter_test/flutter_test.dart';

import 'package:coach_companion/models/player.dart';
import 'package:coach_companion/services/material_duty.dart';

Player _p(String id, String last, {DateTime? birth}) => Player(
      id: id,
      teamId: 't',
      firstName: 'V',
      lastName: last,
      birthdate: birth,
      createdAt: DateTime(2024),
    );

void main() {
  group('Gruppen', () {
    test('computeGroupCount: max 5/Gruppe, max 6 Gruppen', () {
      expect(computeGroupCount(0), 1);
      expect(computeGroupCount(1), 1);
      expect(computeGroupCount(5), 1);
      expect(computeGroupCount(6), 2);
      expect(computeGroupCount(30), 6);
      expect(computeGroupCount(31), 6);
      expect(computeGroupCount(50), 6);
    });

    test('groupCapacities: sequenziell, Überlauf reihum', () {
      expect(groupCapacities(12, 3), [5, 5, 2]);
      expect(groupCapacities(10, 2), [5, 5]);
      // 31 Spieler, 6 Gruppen: 30 sequenziell, +1 reihum auf G1.
      expect(groupCapacities(31, 6), [6, 5, 5, 5, 5, 5]);
      // 33 Spieler, 6 Gruppen: +1 auf G1, G2, G3.
      expect(groupCapacities(33, 6), [6, 6, 6, 5, 5, 5]);
    });

    test('sortPlayersByBirthDesc: jüngste zuerst, ohne Datum ans Ende', () {
      final players = [
        _p('a', 'Alt', birth: DateTime(1990, 1, 1)),
        _p('b', 'Jung', birth: DateTime(2008, 5, 1)),
        _p('c', 'Ohne'),
        _p('m', 'Mittel', birth: DateTime(2000, 1, 1)),
      ];
      final sorted = sortPlayersByBirthDesc(players);
      expect(sorted.map((p) => p.id).toList(), ['b', 'm', 'a', 'c']);
    });

    test('buildGroups: sequenziell + Override', () {
      final players = [
        for (var i = 0; i < 12; i++)
          _p('p$i', 'N$i', birth: DateTime(2010 - i, 1, 1)),
      ];
      final sorted = sortPlayersByBirthDesc(players);
      final groups = buildGroups(sorted);
      expect(groups.map((g) => g.length).toList(), [5, 5, 2]);

      // Override: p11 (wäre in Gruppe 3) fest in Gruppe 1 (Index 0).
      final withOverride =
          buildGroups(sorted, overrides: const [DutyOverride('p11', 0)]);
      expect(withOverride[0].any((p) => p.id == 'p11'), isTrue);
      // Gesamtzahl bleibt erhalten.
      expect(withOverride.expand((g) => g).length, 12);
    });
  });

  group('Kalenderwochen', () {
    test('isoWeek: bekannte Daten', () {
      expect(isoWeek(DateTime(2026, 1, 1)), (week: 1, year: 2026));
      expect(isoWeek(DateTime(2026, 1, 5)), (week: 2, year: 2026));
      expect(isoWeek(DateTime(2025, 1, 1)), (week: 1, year: 2025));
      // 2024-12-30 (Mo) gehört zur ISO-KW 1/2025.
      expect(isoWeek(DateTime(2024, 12, 30)), (week: 1, year: 2025));
    });

    test('startOfIsoWeek: liefert den Montag', () {
      // 2026-01-07 ist ein Mittwoch → Montag ist 2026-01-05.
      final mon = startOfIsoWeek(DateTime(2026, 1, 7));
      expect([mon.year, mon.month, mon.day], [2026, 1, 5]);
    });

    test('weekOffset & groupIndexForWeek: zyklische Rotation', () {
      final start = DateTime(2026, 1, 5); // Montag
      expect(weekOffset(start, DateTime(2026, 1, 5)), 0);
      expect(weekOffset(start, DateTime(2026, 1, 12)), 1);
      expect(weekOffset(start, DateTime(2026, 1, 19)), 2);
      // Bei 3 Gruppen wiederholt sich der Index alle 3 Wochen.
      expect(groupIndexForWeek(DateTime(2026, 1, 5), start, 3), 0);
      expect(groupIndexForWeek(DateTime(2026, 1, 12), start, 3), 1);
      expect(groupIndexForWeek(DateTime(2026, 1, 26), start, 3), 0);
    });

    test('listWeeks: Mo–So-Spanne inklusive', () {
      final weeks = listWeeks(DateTime(2026, 1, 5), DateTime(2026, 1, 20));
      expect(weeks.length, 3); // KW über drei Montage
      expect([weeks.first.monday.month, weeks.first.monday.day], [1, 5]);
    });
  });

  group('Wochen-Plan', () {
    test('buildSchedule: Rotation + Urlaubs-Markierung', () {
      final players = [
        for (var i = 0; i < 6; i++)
          _p('p$i', 'N$i', birth: DateTime(2010 - i, 1, 1)),
      ];
      final sorted = sortPlayersByBirthDesc(players);
      final groups = buildGroups(sorted); // 6 Spieler → 2 Gruppen à (5,1)
      expect(groups.length, 2);

      final start = DateTime(2026, 1, 5);
      final weeks = listWeeks(start, DateTime(2026, 1, 18)); // 2 Wochen
      // Spieler der Gruppe 0 (p0) ist in KW1 im Urlaub.
      final g0first = groups[0].first;
      final vac = [
        DutyVacation(g0first.id, DateTime(2026, 1, 5), DateTime(2026, 1, 9)),
      ];
      final schedule = buildSchedule(
        weeks: weeks,
        groups: groups,
        rotationStart: start,
        vacations: vac,
      );
      expect(schedule.length, 2);
      // KW1 → Gruppe 0, KW2 → Gruppe 1.
      expect(schedule[0].groupIdx, 0);
      expect(schedule[1].groupIdx, 1);
      // Urlaub nur in KW1 für die diensthabende Gruppe 0 markiert.
      expect(schedule[0].vacationingIds, contains(g0first.id));
      expect(schedule[1].vacationingIds, isEmpty);
    });
  });
}
