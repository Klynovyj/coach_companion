import '../../models/enums.dart';

/// Importierte Stammdaten eines Spielers (quellneutral).
class PlayerData {
  final String firstName;
  final String lastName;
  final int? number;
  final String? position;

  /// Externe ID aus der Quelle (für Duplikaterkennung), falls vorhanden.
  final String? externalId;

  /// Spielerfoto als Data-URL (bereits heruntergeladen), falls verfügbar.
  final String? photoDataUrl;

  /// Geburtsdatum (von der FuPa-Profilseite), falls verfügbar.
  final DateTime? birthdate;

  /// Rolle im Trainerteam (z.B. „Trainer"); null = Spieler.
  final String? staffRole;

  /// Spitzname (von der FuPa-Profilseite), falls gepflegt.
  final String? nickname;

  const PlayerData({
    required this.firstName,
    required this.lastName,
    this.number,
    this.position,
    this.externalId,
    this.photoDataUrl,
    this.birthdate,
    this.staffRole,
    this.nickname,
  });
}

/// Ein Spiel aus einem importierten Spielplan (quellneutral).
class ScheduledMatchData {
  final String opponentName;
  final String? opponentRef;

  /// Vollständiger FuPa-Teamlink des Gegners (für späteren Kader-Import).
  final String? opponentFupaUrl;

  /// Basis-URL des Gegner-Logos (ohne Größen-Suffix), vor dem Download.
  final String? opponentLogoUrl;

  /// Gegner-Logo als Data-URL (bereits heruntergeladen), falls verfügbar.
  final String? opponentLogoDataUrl;

  final DateTime? kickoff;
  final Venue venue;
  final String? competition;

  /// Spieltag-Nummer (FuPa `round.number`), falls bekannt.
  final int? matchday;
  final String? externalId;

  /// FuPa-Match-Slug (für den Link auf die FuPa-Spielseite).
  final String? fupaMatchSlug;

  /// true = Spiel ist gespielt (Ergebnis vorhanden).
  final bool finished;
  final int? ownGoals;
  final int? opponentGoals;

  const ScheduledMatchData({
    required this.opponentName,
    this.opponentRef,
    this.opponentFupaUrl,
    this.opponentLogoUrl,
    this.opponentLogoDataUrl,
    this.kickoff,
    this.venue = Venue.home,
    this.competition,
    this.matchday,
    this.externalId,
    this.fupaMatchSlug,
    this.finished = false,
    this.ownGoals,
    this.opponentGoals,
  });

  ScheduledMatchData withLogo(String? dataUrl) => ScheduledMatchData(
    opponentName: opponentName,
    opponentRef: opponentRef,
    opponentFupaUrl: opponentFupaUrl,
    opponentLogoUrl: opponentLogoUrl,
    opponentLogoDataUrl: dataUrl,
    kickoff: kickoff,
    venue: venue,
    competition: competition,
    matchday: matchday,
    externalId: externalId,
    fupaMatchSlug: fupaMatchSlug,
    finished: finished,
    ownGoals: ownGoals,
    opponentGoals: opponentGoals,
  );
}

/// Saison-Statistik eines Spielers aus FuPa (quellneutral).
class PlayerStatData {
  final String? externalId;
  final String firstName;
  final String lastName;
  final int matches;
  final int goals;
  final int assists;
  final int yellowCards;
  final int yellowRedCards;
  final int redCards;
  final int minutes;
  final int topEleven;

  const PlayerStatData({
    this.externalId,
    required this.firstName,
    required this.lastName,
    this.matches = 0,
    this.goals = 0,
    this.assists = 0,
    this.yellowCards = 0,
    this.yellowRedCards = 0,
    this.redCards = 0,
    this.minutes = 0,
    this.topEleven = 0,
  });
}

/// Eine Station der FuPa-Laufbahn (eine Saison bei einem Team/Verein).
/// FuPa liefert je Station nur Spiele/Tore/Assists (keine Karten/Minuten).
class FupaCareerStation {
  /// Team-Slug der Station (z.B. `garather-sv-m1-2025-26`).
  final String teamSlug;
  final String clubName;
  final String competition;
  final int matches;
  final int goals;
  final int assists;

  const FupaCareerStation({
    required this.teamSlug,
    required this.clubName,
    required this.competition,
    this.matches = 0,
    this.goals = 0,
    this.assists = 0,
  });

  int get scorerPoints => goals + assists;

  /// Pflichtspiel-Wettbewerb? Liga und Pokal zählen als Pflicht;
  /// Freundschafts-/Testspiele (und Vorbereitung) nicht.
  bool get isCompetitive {
    final c = competition.toLowerCase();
    return !(c.contains('freund') ||
        c.contains('test') ||
        c.contains('vorbereit'));
  }
}

/// Die komplette FuPa-Laufbahn eines Spielers: Gesamt-Bilanz (über alle
/// Vereine) + einzelne Stationen je Saison.
class FupaCareer {
  final List<FupaCareerStation> stations;
  final int totalMatches;
  final int totalGoals;
  final int totalAssists;
  final int totalYellow;
  final int totalYellowRed;
  final int totalRed;
  final int totalTopEleven;

  // Trainer-Bilanz (Karriere) – nur gesetzt, wenn die Person auch Trainer ist.
  final int coachMatches;
  final int coachWins;
  final int coachDraws;
  final int coachLosses;
  final int coachPoints;

  const FupaCareer({
    this.stations = const [],
    this.totalMatches = 0,
    this.totalGoals = 0,
    this.totalAssists = 0,
    this.totalYellow = 0,
    this.totalYellowRed = 0,
    this.totalRed = 0,
    this.totalTopEleven = 0,
    this.coachMatches = 0,
    this.coachWins = 0,
    this.coachDraws = 0,
    this.coachLosses = 0,
    this.coachPoints = 0,
  });

  bool get hasCoachData => coachMatches > 0;

  static String _clubBase(String teamSlug) {
    final m = RegExp(r'^(.*?)-m\d+').firstMatch(teamSlug);
    return m?.group(1) ?? teamSlug;
  }

  /// Start-Jahr einer Saison-/Wettbewerbs-Bezeichnung (z.B. „… 24/25" → 2024,
  /// „Frühjahr 24" → 2024). Null, wenn nicht erkennbar.
  static int? _seasonStartYear(String comp) {
    var m = RegExp(r'(\d{4})/\d{2}').firstMatch(comp);
    if (m != null) return int.tryParse(m.group(1)!);
    m = RegExp(r'(\d{2})/\d{2}').firstMatch(comp);
    if (m != null) return 2000 + int.parse(m.group(1)!);
    m = RegExp(r'\b(\d{2})\b').firstMatch(comp);
    if (m != null) return 2000 + int.parse(m.group(1)!);
    m = RegExp(r'(\d{4})').firstMatch(comp);
    if (m != null) return int.tryParse(m.group(1)!);
    return null;
  }

  /// Aktueller, ununterbrochener Vereins-Lauf: beginnend bei der jüngsten
  /// Station (= aktueller Verein) rückwärts, solange derselbe Verein. Liefert
  /// Beitrittsjahr und Anzahl Saisons; null ohne Stationen.
  FupaClubSpell? currentClubSpell() {
    if (stations.isEmpty) return null;
    final targetBase = _clubBase(stations.first.teamSlug);
    final targetName = stations.first.clubName;
    var count = 0;
    String earliestComp = '';
    for (final s in stations) {
      final same =
          _clubBase(s.teamSlug) == targetBase || s.clubName == targetName;
      if (!same) break;
      count++;
      earliestComp = s.competition; // neueste zuerst → zuletzt = früheste
    }
    return FupaClubSpell(
      clubName: targetName,
      sinceSeason: earliestComp,
      sinceYear: _seasonStartYear(earliestComp),
      seasons: count,
    );
  }

  /// Summiert die Stationen **eines Vereins** (alle Saisons dort) zu
  /// Spiele/Tore/Vorlagen. Ein Verein wird am [clubSlug] (Vereins-Slug ohne
  /// Team-/Saison-Suffix) erkannt; [clubName] dient als Rückfall.
  FupaClubTotal clubTotal({
    String? clubSlug,
    String? clubName,
    bool pflichtOnly = false,
  }) {
    final slug = clubSlug?.trim().toLowerCase();
    final nameL = clubName?.trim().toLowerCase();
    var matches = 0, goals = 0, assists = 0, seasons = 0;
    String? name = clubName;
    for (final s in stations) {
      if (pflichtOnly && !s.isCompetitive) continue;
      final bySlug =
          slug != null &&
          slug.isNotEmpty &&
          (s.teamSlug == slug || s.teamSlug.startsWith('$slug-'));
      final byName =
          nameL != null &&
          nameL.isNotEmpty &&
          s.clubName.trim().toLowerCase() == nameL;
      if (bySlug || byName) {
        matches += s.matches;
        goals += s.goals;
        assists += s.assists;
        seasons++;
        name ??= s.clubName;
      }
    }
    return FupaClubTotal(
      clubName: name ?? clubName ?? '',
      seasons: seasons,
      matches: matches,
      goals: goals,
      assists: assists,
    );
  }
}

/// Vereins-Gesamtwerte eines Spielers aus der FuPa-Laufbahn (alle Saisons bei
/// genau diesem Verein).
class FupaClubTotal {
  final String clubName;
  final int seasons;
  final int matches;
  final int goals;
  final int assists;

  const FupaClubTotal({
    this.clubName = '',
    this.seasons = 0,
    this.matches = 0,
    this.goals = 0,
    this.assists = 0,
  });

  int get scorerPoints => goals + assists;
  bool get hasAny => matches > 0 || goals > 0 || assists > 0;
}

/// Ununterbrochener Vereins-Lauf eines Spielers (seit wann, wie viele Saisons).
class FupaClubSpell {
  final String clubName;
  final String sinceSeason; // Wettbewerb/Saison der ersten Saison des Laufs
  final int? sinceYear; // Start-Kalenderjahr, falls erkannt
  final int seasons; // Anzahl zusammenhängender Saisons beim Verein

  const FupaClubSpell({
    this.clubName = '',
    this.sinceSeason = '',
    this.sinceYear,
    this.seasons = 0,
  });

  /// Jahre beim Verein (Kalenderjahre seit Beitritt, mind. 1).
  int yearsUntil(int nowYear) => sinceYear == null
      ? 0
      : (nowYear - sinceYear! < 1 ? 1 : nowYear - sinceYear!);
}

/// Bündelt die FuPa-Laufbahn eines Spielers mit dem aufgelösten Verein, damit
/// die UI die Vereins-Gesamtwerte live umschalten kann (alle Spiele vs. nur
/// Pflichtspiele), ohne erneut zu laden.
class FupaClubCareer {
  final FupaCareer career;
  final String? clubSlug;
  final String? clubName;

  const FupaClubCareer({required this.career, this.clubSlug, this.clubName});

  /// Vereins-Gesamtwerte; [pflichtOnly] schließt Freundschafts-/Testspiele aus.
  FupaClubTotal total({bool pflichtOnly = false}) => career.clubTotal(
    clubSlug: clubSlug,
    clubName: clubName,
    pflichtOnly: pflichtOnly,
  );
}

/// Ergebnis eines Gegner-Sync-Vorgangs (für Statusmeldungen in der UI).
class ImportResult {
  final ImportStatus status;
  final String message;

  /// Anzahl übernommener Spieler.
  final int importedPlayers;

  const ImportResult({
    required this.status,
    required this.message,
    this.importedPlayers = 0,
  });
}

/// Eine Tabellenzeile (Liga-Standing) eines Teams.
class StandingRow {
  final int rank;
  final int matches;
  final int wins;
  final int draws;
  final int defeats;
  final int goalsFor;
  final int goalsAgainst;
  final int goalDiff;
  final int points;
  final int totalTeams;
  final String teamName;
  final String teamSlug;

  const StandingRow({
    required this.rank,
    required this.matches,
    required this.wins,
    required this.draws,
    required this.defeats,
    required this.goalsFor,
    required this.goalsAgainst,
    required this.goalDiff,
    required this.points,
    required this.totalTeams,
    required this.teamName,
    this.teamSlug = '',
  });
}

/// Ein (abgeschlossenes) Spiel aus Sicht eines Teams – für die Form (letzte 5).
class FormMatch {
  final DateTime? date;
  final String opponentName;
  final int ownGoals;
  final int oppGoals;
  final bool home;

  const FormMatch({
    required this.date,
    required this.opponentName,
    required this.ownGoals,
    required this.oppGoals,
    required this.home,
  });

  /// 'S' Sieg, 'U' Unentschieden, 'N' Niederlage.
  String get result =>
      ownGoals > oppGoals ? 'S' : (ownGoals < oppGoals ? 'N' : 'U');
}

/// Ein kommendes (noch nicht gespieltes) Spiel eines Teams – für die
/// „Nächste 5 Spiele"-Karte in der Gegner-Analyse.
class FixtureMatch {
  final DateTime? date;
  final String opponentName;
  final bool home;

  const FixtureMatch({
    required this.date,
    required this.opponentName,
    required this.home,
  });
}
