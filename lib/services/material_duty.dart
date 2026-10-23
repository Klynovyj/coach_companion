import '../models/player.dart';

/// Logik für den Ball-/Materialdienst – portiert aus coach_studio.
///
/// Reine Funktionen (keine Flutter-Abhängigkeiten), damit alles ohne UI
/// testbar bleibt:
///   - Gruppen (max. 5 Spieler, max. 6 Gruppen), jüngste zuerst
///   - ISO-Kalenderwochen-Berechnung
///   - zyklische Wochen-Rotation ab einem Rotations-Start
///   - Urlaubs-Überlappung je Woche

const int kMaxPerGroup = 5;
const int kMaxGroups = 6;

/// Manuelle Zuteilung eines Spielers in eine feste Gruppe.
class DutyOverride {
  final String playerId;
  final int groupIndex;
  const DutyOverride(this.playerId, this.groupIndex);
}

/// Ein Urlaubs-Zeitraum eines Spielers (aus den „Urlaub"-Abwesenheiten).
class DutyVacation {
  final String playerId;
  final DateTime start;
  final DateTime end;
  const DutyVacation(this.playerId, this.start, this.end);
}

/// Eine Kalenderwoche (Mo–So) mit ISO-KW und -Jahr.
class DutyWeek {
  final DateTime monday;
  final DateTime sunday;
  final int week;
  final int year;
  const DutyWeek(this.monday, this.sunday, this.week, this.year);
}

/// Ein Eintrag im Wochen-Plan: welche Gruppe dient und welche ihrer Spieler
/// in dieser Woche im Urlaub sind.
class ScheduleEntry {
  final DateTime monday;
  final DateTime sunday;
  final int week;
  final int year;
  final int groupIdx;
  final List<String> vacationingIds;
  const ScheduleEntry({
    required this.monday,
    required this.sunday,
    required this.week,
    required this.year,
    required this.groupIdx,
    required this.vacationingIds,
  });
}

// ─── Gruppen ─────────────────────────────────────────────────────────

/// Jüngste zuerst (Geburtsdatum absteigend). Spieler ohne Geburtsdatum ans
/// Ende; Nachname als deterministischer Tie-Breaker.
List<Player> sortPlayersByBirthDesc(List<Player> players) {
  final list = [...players];
  list.sort((a, b) {
    final ad = a.birthdate;
    final bd = b.birthdate;
    if (ad == null && bd == null) {
      return a.lastName.toLowerCase().compareTo(b.lastName.toLowerCase());
    }
    if (ad == null) return 1; // ohne Datum ans Ende
    if (bd == null) return -1;
    final c = bd.compareTo(ad); // absteigend → jüngste zuerst
    if (c != 0) return c;
    return a.lastName.toLowerCase().compareTo(b.lastName.toLowerCase());
  });
  return list;
}

/// Anzahl Gruppen für N Spieler: mind. 1, höchstens [kMaxGroups].
int computeGroupCount(int playerCount) {
  if (playerCount <= 0) return 1;
  final n = (playerCount / kMaxPerGroup).ceil();
  return n < 1 ? 1 : (n > kMaxGroups ? kMaxGroups : n);
}

/// Zielgröße jeder Gruppe: erst sequenziell bis [kMaxPerGroup], dann Überlauf
/// reihum (+1 je Gruppe), damit die Geburtsdaten je Gruppe zusammenhängen.
List<int> groupCapacities(int total, int groupCount) {
  final caps = List<int>.filled(groupCount < 0 ? 0 : groupCount, 0);
  if (groupCount <= 0) return caps;
  var n = total;
  for (var i = 0; i < groupCount && n > 0; i++) {
    final take = n < kMaxPerGroup ? n : kMaxPerGroup;
    caps[i] = take;
    n -= take;
  }
  for (var i = 0; n > 0; i++, n--) {
    caps[i % groupCount] += 1;
  }
  return caps;
}

/// Teilt die (bereits sortierten) Spieler sequenziell in Gruppen. Overrides
/// setzen Spieler in eine feste Gruppe, der Rest füllt die freien Plätze auf.
List<List<Player>> buildGroups(
  List<Player> sortedPlayers, {
  List<DutyOverride> overrides = const [],
}) {
  final total = sortedPlayers.length;
  final groupCount = computeGroupCount(total);
  final caps = groupCapacities(total, groupCount);
  final groups = List.generate(groupCount, (_) => <Player>[]);

  final overrideMap = {for (final o in overrides) o.playerId: o.groupIndex};
  final placed = <String>{};
  for (final p in sortedPlayers) {
    final idx = overrideMap[p.id];
    if (idx == null || idx < 0 || idx >= groupCount) continue;
    if (groups[idx].length >= caps[idx]) continue;
    groups[idx].add(p);
    placed.add(p.id);
  }

  final remaining = sortedPlayers.where((p) => !placed.contains(p.id));
  var cursor = 0;
  for (final p in remaining) {
    while (cursor < groupCount && groups[cursor].length >= caps[cursor]) {
      cursor++;
    }
    if (cursor >= groupCount) break;
    groups[cursor].add(p);
  }
  return groups;
}

// ─── Kalenderwochen (ISO 8601, in UTC gerechnet, DST-frei) ───────────

DateTime _u(DateTime d) => DateTime.utc(d.year, d.month, d.day);

/// Montag der ISO-Woche von [date] (als lokales Kalenderdatum).
DateTime startOfIsoWeek(DateTime date) {
  final d = _u(date);
  final mon = d.subtract(Duration(days: d.weekday - 1));
  return DateTime(mon.year, mon.month, mon.day);
}

/// ISO-Kalenderwoche + ISO-Jahr.
({int week, int year}) isoWeek(DateTime date) {
  final d = _u(date);
  final thursday = d.add(Duration(days: 4 - d.weekday));
  final week1Monday = _u(DateTime.utc(thursday.year, 1, 4))
      .subtract(Duration(days: DateTime.utc(thursday.year, 1, 4).weekday - 1));
  final week = (thursday.difference(week1Monday).inDays / 7).round() + 1;
  return (week: week, year: thursday.year);
}

/// Anzahl ganzer Wochen zwischen den Montagen von [start] und [target].
int weekOffset(DateTime start, DateTime target) {
  final a = _u(startOfIsoWeek(start));
  final b = _u(startOfIsoWeek(target));
  return (b.difference(a).inDays / 7).round();
}

/// Alle Wochen (Mo–So) von [from] bis [to], aufsteigend.
List<DutyWeek> listWeeks(DateTime from, DateTime to) {
  final start = _u(startOfIsoWeek(from));
  final end = _u(startOfIsoWeek(to));
  final result = <DutyWeek>[];
  var cursor = start;
  while (!cursor.isAfter(end)) {
    final sunday = cursor.add(const Duration(days: 6));
    final iw = isoWeek(cursor);
    result.add(DutyWeek(
      DateTime(cursor.year, cursor.month, cursor.day),
      DateTime(sunday.year, sunday.month, sunday.day),
      iw.week,
      iw.year,
    ));
    cursor = cursor.add(const Duration(days: 7));
  }
  return result;
}

/// Gruppen-Index für eine Woche – zyklische Rotation ab [rotationStart].
/// [startGroup] = Gruppe (0-basiert), die in der Start-Woche dran ist.
int groupIndexForWeek(DateTime weekMonday, DateTime rotationStart, int groupCount,
    {int startGroup = 0}) {
  if (groupCount <= 0) return 0;
  final off = weekOffset(rotationStart, weekMonday) + startGroup;
  return ((off % groupCount) + groupCount) % groupCount;
}

bool _vacationOverlapsWeek(
    DutyVacation v, DateTime weekMonday, DateTime weekSunday) {
  final vs = DateTime(v.start.year, v.start.month, v.start.day);
  final ve = DateTime(v.end.year, v.end.month, v.end.day);
  final wm = DateTime(weekMonday.year, weekMonday.month, weekMonday.day);
  final ws = DateTime(weekSunday.year, weekSunday.month, weekSunday.day);
  return !ve.isBefore(wm) && !vs.isAfter(ws);
}

/// Spieler-IDs aus [group], die in der Woche (Mo–So) im Urlaub sind.
List<String> vacationingInWeek(
  List<Player> group,
  DateTime weekMonday,
  DateTime weekSunday,
  List<DutyVacation> vacations,
) {
  final ids = group.map((p) => p.id).toSet();
  final out = <String>{};
  for (final v in vacations) {
    if (!ids.contains(v.playerId)) continue;
    if (_vacationOverlapsWeek(v, weekMonday, weekSunday)) out.add(v.playerId);
  }
  return out.toList();
}

/// Baut den Wochen-Plan: je Woche die diensthabende Gruppe (zyklisch ab
/// [rotationStart]) plus die in dieser Woche beurlaubten Spieler der Gruppe.
List<ScheduleEntry> buildSchedule({
  required List<DutyWeek> weeks,
  required List<List<Player>> groups,
  required DateTime rotationStart,
  required List<DutyVacation> vacations,
  int startGroup = 0,
}) {
  if (groups.isEmpty || weeks.isEmpty) return const [];
  return weeks.map((w) {
    final idx = groupIndexForWeek(w.monday, rotationStart, groups.length,
        startGroup: startGroup);
    return ScheduleEntry(
      monday: w.monday,
      sunday: w.sunday,
      week: w.week,
      year: w.year,
      groupIdx: idx,
      vacationingIds:
          vacationingInWeek(groups[idx], w.monday, w.sunday, vacations),
    );
  }).toList();
}
