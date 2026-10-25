import 'package:uuid/uuid.dart';

import '../../data/coach_repository.dart';
import '../../models/enums.dart';
import '../../models/match.dart';
import '../../models/player.dart';
import '../../models/team.dart';
import 'fupa_dtos.dart';
import 'fupa_redux_importer.dart';

/// Gemeinsame Übernahme importierter Daten in die Datenbank, inkl.
/// Duplikatschutz für Spieler und Spiele. Wird von Import- und Sync-Service
/// genutzt, damit die Dedup-Regeln an genau einer Stelle leben.
class FupaPersistence {
  FupaPersistence(this._repo);
  final CoachRepository _repo;
  final _uuid = const Uuid();

  /// Übernimmt die Spieler eines [TeamData] in das Team und verhindert dabei
  /// Dubletten: zuerst über die externe ID, sonst über den normalisierten
  /// Namen. Vorhandene Spieler werden aktualisiert statt neu angelegt.
  ///
  /// Gibt die Anzahl NEU angelegter Spieler zurück.
  Future<int> syncPlayers(String teamId, List<PlayerData> incoming,
      DataSource source) async {
    final existing = await _repo.getPlayers(teamId);
    final byExternal = <String, Player>{};
    final byName = <String, Player>{};
    for (final p in existing) {
      if (p.externalId != null && p.externalId!.isNotEmpty) {
        byExternal[p.externalId!] = p;
      }
      byName[p.dedupKey] = p;
    }

    var added = 0;
    for (final data in incoming) {
      final nameKey =
          '${data.firstName.trim().toLowerCase()}|${data.lastName.trim().toLowerCase()}';
      Player? match;
      if (data.externalId != null && data.externalId!.isNotEmpty) {
        match = byExternal[data.externalId!];
      }
      match ??= byName[nameKey];

      if (match != null) {
        // Vorhandenen Spieler mit frischen Stammdaten aktualisieren.
        final updated = match.copyWith(
          firstName: data.firstName.trim().isEmpty
              ? match.firstName
              : data.firstName.trim(),
          lastName: data.lastName.trim().isEmpty
              ? match.lastName
              : data.lastName.trim(),
          number: data.number ?? match.number,
          position: data.position ?? match.position,
          externalId: data.externalId ?? match.externalId,
          photoPath: data.photoDataUrl,
          // Vorhandenes Geburtsdatum behalten, wenn FuPa keins liefert.
          birthdate: data.birthdate ?? match.birthdate,
          staffRole: data.staffRole ?? match.staffRole,
          // Spitzname nur übernehmen, wenn FuPa einen liefert (sonst behalten).
          nickname: (data.nickname != null && data.nickname!.isNotEmpty)
              ? data.nickname
              : match.nickname,
        );
        await _repo.upsertPlayer(updated);
        // Maps mitführen, damit ein doppelter Eintrag im selben Import (z.B.
        // derselbe Spieler einmal mit, einmal ohne FuPa-ID) nicht als neue
        // Zeile landet, sondern diese aktualisiert.
        byName[updated.dedupKey] = updated;
        if (updated.externalId != null && updated.externalId!.isNotEmpty) {
          byExternal[updated.externalId!] = updated;
        }
      } else {
        final created = Player(
          id: _uuid.v4(),
          teamId: teamId,
          firstName: data.firstName.trim(),
          lastName: data.lastName.trim(),
          number: data.number,
          position: data.position,
          externalId: data.externalId,
          photoPath: data.photoDataUrl,
          birthdate: data.birthdate,
          staffRole: data.staffRole,
          nickname: data.nickname,
          source: source,
          createdAt: DateTime.now(),
        );
        await _repo.upsertPlayer(created);
        byName[created.dedupKey] = created;
        if (created.externalId != null && created.externalId!.isNotEmpty) {
          byExternal[created.externalId!] = created;
        }
        added++;
      }
    }
    return added;
  }

  /// Legt das eigene Team an oder aktualisiert es mit den FuPa-Vereinsdaten
  /// (Name/Kurzname/Logo/Link). Der Kader wird separat (mit Fotos) übernommen.
  Future<Team> saveOwnTeam(String url, FupaTeamImport data) async {
    final existing = await _repo.getOwnTeam();
    final base = existing ??
        Team(
          id: _uuid.v4(),
          name: data.name ?? 'Meine Mannschaft',
          isOwnTeam: true,
          source: DataSource.fupaApproved,
          createdAt: DateTime.now(),
        );
    final team = base.copyWith(
      name: data.name ?? base.name,
      shortName: data.shortName,
      logoPath: data.logoDataUrl,
      fupaUrl: url,
      fupaRef: _slug(url),
      source: DataSource.fupaApproved,
      lastSyncedAt: DateTime.now(),
    );
    await _repo.upsertTeam(team);
    return team;
  }

  String _slug(String url) {
    final m = RegExp(r'/team/([^/?#]+)', caseSensitive: false).firstMatch(url);
    return (m?.group(1) ?? '').toLowerCase();
  }

  /// Findet oder erstellt ein Gegner-Team (dedupliziert über Ref/Name).
  Future<Team> ensureOpponentTeam({
    required String name,
    String? fupaRef,
    DataSource source = DataSource.schedulePlaceholder,
  }) async {
    final found = await _repo.findOpponentTeam(fupaRef: fupaRef, name: name);
    if (found != null) {
      // Ggf. Ref nachtragen.
      if ((found.fupaRef == null || found.fupaRef!.isEmpty) &&
          fupaRef != null) {
        final updated = found.copyWith(fupaRef: fupaRef);
        await _repo.upsertTeam(updated);
        return updated;
      }
      return found;
    }
    final team = Team(
      id: _uuid.v4(),
      name: name,
      fupaRef: fupaRef,
      isOwnTeam: false,
      source: source,
      createdAt: DateTime.now(),
    );
    await _repo.upsertTeam(team);
    return team;
  }

  /// Übernimmt einen importierten Spielplan für das eigene Team und verhindert
  /// doppelte Spiele (über externe ID, sonst Gegnername + Anstoßzeit).
  Future<int> syncSchedule(
      String ownTeamId, List<ScheduledMatchData> incoming) async {
    final existing = await _repo.getMatches(ownTeamId);
    final byExternal = <String, GameMatch>{};
    final byKey = <String, GameMatch>{};
    for (final m in existing) {
      if (m.externalId != null && m.externalId!.isNotEmpty) {
        byExternal[m.externalId!] = m;
      }
      byKey[_matchKey(m.opponentName, m.kickoff)] = m;
    }

    var added = 0;
    for (final data in incoming) {
      GameMatch? match;
      if (data.externalId != null && data.externalId!.isNotEmpty) {
        match = byExternal[data.externalId!];
      }
      match ??= byKey[_matchKey(data.opponentName, data.kickoff)];

      final status = data.finished ? MatchStatus.finished : null;
      if (match != null) {
        // Selbst verwaltete Spiele (zurückgesetzt/live getrackt): Metadaten
        // aktualisieren, aber Status/Ergebnis NICHT aus FuPa überschreiben.
        final managed = match.locallyManaged;
        await _repo.upsertMatch(match.copyWith(
          opponentName: data.opponentName,
          opponentFupaUrl: data.opponentFupaUrl,
          opponentLogoPath: data.opponentLogoDataUrl,
          kickoff: data.kickoff,
          venue: data.venue,
          competition: data.competition,
          matchday: data.matchday ?? match.matchday,
          externalId: data.externalId,
          fupaMatchSlug: data.fupaMatchSlug ?? match.fupaMatchSlug,
          // Live/beendete/selbst verwaltete Spiele nicht zurücksetzen.
          status: !managed && data.finished && match.status != MatchStatus.live
              ? MatchStatus.finished
              : null,
          ownScore: !managed && data.finished ? data.ownGoals : null,
          opponentScore: !managed && data.finished ? data.opponentGoals : null,
        ));
      } else {
        await _repo.upsertMatch(GameMatch(
          id: _uuid.v4(),
          ownTeamId: ownTeamId,
          opponentName: data.opponentName,
          opponentFupaUrl: data.opponentFupaUrl,
          opponentLogoPath: data.opponentLogoDataUrl,
          kickoff: data.kickoff,
          venue: data.venue,
          competition: data.competition,
          matchday: data.matchday,
          externalId: data.externalId,
          fupaMatchSlug: data.fupaMatchSlug,
          status: status ?? MatchStatus.scheduled,
          ownScore: data.finished ? (data.ownGoals ?? 0) : 0,
          opponentScore: data.finished ? (data.opponentGoals ?? 0) : 0,
          createdAt: DateTime.now(),
        ));
        added++;
      }
    }
    return added;
  }

  String _matchKey(String opponent, DateTime? kickoff) {
    final day = kickoff == null
        ? ''
        : '${kickoff.year}-${kickoff.month}-${kickoff.day}';
    return '${opponent.trim().toLowerCase()}@$day';
  }
}
