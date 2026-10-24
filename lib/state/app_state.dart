import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show RealtimeChannel;
import 'package:uuid/uuid.dart';

import '../data/coach_repository.dart';
import '../models/card_entry.dart';
import '../models/enums.dart';
import '../models/lineup.dart';
import '../models/match.dart';
import '../models/match_event.dart';
import '../models/material_duty_config.dart';
import '../models/nomination.dart';
import '../models/note_category.dart';
import '../models/player.dart';
import '../models/player_absence.dart';
import '../models/player_note.dart';
import '../models/scout_marker.dart';
import '../models/team_event.dart';
import '../models/player_rating.dart';
import '../models/player_stat.dart';
import '../models/team.dart';
import '../models/player_talk.dart';
import '../models/todo.dart';
import '../models/todo_topic.dart';
import '../services/cloud_service.dart';
import '../services/fupa/fupa_dtos.dart';
import '../services/fupa/fupa_persistence.dart';
import '../services/material_duty.dart';
import '../services/fupa/fupa_redux_importer.dart';
import '../services/opponent_sync_service.dart';

/// Zusammenfassung eines kompletten FuPa-Imports (für die Status-Anzeige).
class ConnectSummary {
  final String teamName;
  final int players;
  final int matches;
  final int newMatches;
  final int stats;
  const ConnectSummary({
    required this.teamName,
    required this.players,
    required this.matches,
    required this.newMatches,
    required this.stats,
  });
}

/// Art eines offenen „Nachholen"-Punkts.
enum NachholenKind { rating, nomination, lineup }

/// Ein offener Punkt für die „Nachholen"-Liste (verknüpft mit einem Spiel).
class NachholenItem {
  final NachholenKind kind;
  final String matchId;
  final String title;
  final String detail;
  final DateTime? kickoff;
  const NachholenItem({
    required this.kind,
    required this.matchId,
    required this.title,
    required this.detail,
    this.kickoff,
  });
}

/// Zentraler Anwendungszustand. Verdrahtet Persistenz, FuPa-Import und
/// Gegner-Sync und stellt der UI alle Operationen bereit.
class AppState extends ChangeNotifier {
  AppState({CoachRepository? repository})
      : _repo = repository ?? CoachRepository() {
    // Jede team-relevante Schreiboperation in die Cloud spiegeln.
    _repo.onCloudSync = _onRepoWrite;
  }

  final CoachRepository _repo;
  final _uuid = const Uuid();
  late final FupaPersistence _persist = FupaPersistence(_repo);
  final FupaReduxImporter _importer = FupaReduxImporter();

  CoachRepository get repository => _repo;

  bool _loading = true;
  bool get loading => _loading;

  Team? _ownTeam;
  Team? get ownTeam => _ownTeam;

  /// Aktives Cloud-Team (lokale IDs == Cloud-IDs). Nur wenn gesetzt, werden
  /// lokale Schreibzugriffe in die Cloud gespiegelt.
  String? _activeCloudTeamId;
  String? get activeCloudTeamId => _activeCloudTeamId;

  /// Bereichstabellen mit eigener Cloud-Tabelle (Push + Pull). Reihenfolge =
  /// Pull-Reihenfolge (Eltern vor Kindern wegen Fremdschlüsseln im Cache).
  static const _auxTables = <String>[
    'note_categories',
    'todo_topics',
    'lineups',
    'lineup_entries',
    'match_nominations',
    'card_entries',
    'player_notes',
    'player_ratings',
    'todos',
    'player_talks',
    'player_absences',
    // Nach den Ereignissen (siehe _pullEventsFromCloud), damit die
    // referenzierten lokalen match_events bereits vorhanden sind.
    'event_mentions',
  ];
  static const _auxTableSet = <String>{..._auxTables};

  /// Tabellen ohne `id`-Primärschlüssel (zusammengesetzter PK) – beim Pull
  /// immer ersetzend einfügen statt per id zu aktualisieren.
  static const _noIdTables = <String>{'event_mentions'};

  /// Konflikt-Spalten für Upserts, wo der Primärschlüssel nicht die fachliche
  /// Eindeutigkeit abbildet.
  static const _auxOnConflict = <String, String>{
    'match_nominations': 'match_id,player_id',
  };

  /// Spiegelt eine Schreiboperation des Repositorys in die Cloud (best effort).
  void _onRepoWrite(String table, Map<String, Object?>? upsertRow,
      Map<String, Object?>? deleteFilter) {
    // Pulls nutzen hook-freie Roh-Methoden; jede Hook-Auslösung ist also eine
    // echte Nutzer-/App-Eingabe und MUSS gespiegelt werden (nicht blockieren).
    final team = _activeCloudTeamId;
    if (team == null || !CloudService.ready || !CloudService.signedIn) return;
    if (!_auxTableSet.contains(table)) return;
    if (upsertRow != null) {
      final row = <String, dynamic>{...upsertRow, 'team_id': team};
      CloudService.upsertRow(table, row, onConflict: _auxOnConflict[table])
          .catchError((_) {});
    } else if (deleteFilter != null) {
      CloudService.deleteWhere(table, Map<String, dynamic>.from(deleteFilter))
          .catchError((_) {});
    }
  }

  /// Lädt alle Bereichstabellen eines Cloud-Teams in den lokalen Cache.
  /// [replace] = true nach einem Wipe (reines Einfügen), sonst Update-oder-
  /// Insert für den laufenden Realtime-Abgleich.
  Future<void> _pullAuxFromCloud(String teamId, {required bool replace}) async {
    if (!CloudService.ready || !CloudService.signedIn) return;
    for (final table in _auxTables) {
      try {
        final rows = await CloudService.fetchForTeam(table, teamId);
        final ids = <String>[];
        for (final r in rows) {
          final map = Map<String, Object?>.from(r);
          // Nur 'lineups' hat lokal selbst eine team_id-Spalte.
          if (table != 'lineups') map.remove('team_id');
          final id = r['id'] as String?;
          if (id != null) ids.add(id);
          try {
            if (replace || _noIdTables.contains(table)) {
              await _repo.insertRawForPull(table, map);
            } else {
              await _repo.upsertRawById(table, map);
            }
          } catch (_) {
            // Einzelne Zeile (z.B. fehlender Fremdschlüssel) überspringen.
          }
        }
        // Löschungen anderer Geräte übernehmen: lokale Zeilen entfernen, die in
        // der Cloud nicht mehr existieren (id-Tabellen; Cache = genau dies Team).
        // Nach einem Wipe (replace) nicht nötig.
        if (!replace && !_noIdTables.contains(table)) {
          await _repo.deleteRowsNotIn(table, ids);
        }
      } catch (_) {
        // Tabelle nicht erreichbar/vorhanden – überspringen.
      }
    }
  }

  /// Lädt die Cloud-Ereignisse eines Teams in den lokalen Cache. Gegner-
  /// Ereignisse (is_opponent) werden dem lokalen Gegner-Team des Spiels
  /// zugeordnet; fehlt es, wird das Ereignis übersprungen.
  Future<void> _pullEventsFromCloud(String teamId,
      {required bool replace}) async {
    if (!CloudService.ready || !CloudService.signedIn) return;
    final ownId = _ownTeam?.id ?? teamId;
    List<Map<String, dynamic>> rows;
    try {
      rows = await CloudService.fetchForTeam('match_events', teamId);
    } catch (_) {
      return;
    }
    for (final r in rows) {
      try {
        String? localTeam;
        if (r['is_opponent'] == true) {
          final m = await _repo.getMatch(r['match_id'] as String);
          localTeam = m?.opponentTeamId;
          if (localTeam == null) continue; // nicht zuzuordnen
        } else {
          localTeam = ownId;
        }
        final map = <String, Object?>{
          'id': r['id'],
          'match_id': r['match_id'],
          'team_id': localTeam,
          'minute': (r['minute'] as num?)?.toInt() ?? 0,
          'minute_extra': (r['minute_extra'] as num?)?.toInt() ?? 0,
          'type': r['type'],
          'player_id': r['player_id'],
          'assist_player_id': r['assist_player_id'],
          'note': r['note'],
          'created_at':
              (r['created_at'] as String?) ?? DateTime.now().toIso8601String(),
        };
        if (replace) {
          await _repo.insertRawForPull('match_events', map);
        } else {
          await _repo.upsertRawById('match_events', map);
        }
      } catch (_) {
        // Einzelnes Ereignis überspringen.
      }
    }
  }

  /// Realtime-Abgleich der Bereichsdaten (ohne Wipe). Löschungen anderer Geräte
  /// greifen erst beim nächsten vollständigen Team-Download.
  Future<void> resyncCloudAuxData(String teamId) async {
    if (_activeCloudTeamId != teamId) return;
    await _pullEventsFromCloud(teamId, replace: false);
    await _pullAuxFromCloud(teamId, replace: false);
    notifyListeners();
  }

  // ---------------------------------------------------- Globaler Realtime-Sync
  // Hält bei aktivem Cloud-Team den gesamten lokalen Cache (Spiele, Kader,
  // Ereignisse, Bereiche) überall aktuell – nicht nur im Cloud-Bildschirm.
  List<RealtimeChannel> _teamChannels = [];
  String? _syncedTeamId;
  Future<void> _applyQueue = Future.value(); // serialisiert per-Zeile-Updates
  Timer? _fupaTimer;
  Timer? _fullTimer;
  bool _autoRefreshing = false;

  /// Startet (oder behält) das Realtime-Abo + die periodische FuPa-Auffrischung
  /// für das aktive Cloud-Team.
  void ensureTeamSync(String teamId) {
    if (_syncedTeamId == teamId && _teamChannels.isNotEmpty) return;
    _stopTeamSync();
    if (!CloudService.ready || !CloudService.signedIn) return;
    _syncedTeamId = teamId;
    _teamChannels = CloudService.subscribeTeam(teamId, _onRemoteRowChange);
    // Einmaliger Voll-Abgleich beim Start (fängt verpasste Änderungen).
    _refreshActiveTeamFromCloud(teamId);
    // FuPa (Spielplan/Ergebnisse) regelmäßig automatisch auffrischen.
    _fupaTimer = Timer.periodic(
        const Duration(minutes: 30), (_) => maybeAutoRefreshFupa());
    // Voll-Import (Kader, Fotos, Logos, Statistik) seltener.
    _fullTimer = Timer.periodic(
        const Duration(hours: 6), (_) => maybeAutoFullRefresh());
    maybeAutoFullRefresh();
    maybeAutoRefreshFupa();
  }

  void _stopTeamSync() {
    final chs = _teamChannels;
    _teamChannels = [];
    _syncedTeamId = null;
    _fupaTimer?.cancel();
    _fupaTimer = null;
    _fullTimer?.cancel();
    _fullTimer = null;
    if (chs.isNotEmpty) CloudService.removeChannels(chs);
  }

  /// Frischt den Spielplan (inkl. Ergebnisse) des aktiven Cloud-Teams still aus
  /// FuPa auf und spiegelt ihn in die Cloud – ohne Nutzeraktion, gedrosselt auf
  /// höchstens alle 30 Minuten. Leichter Import (ohne Fotos).
  Future<void> maybeAutoRefreshFupa() async {
    if (_autoRefreshing) return;
    final team = _ownTeam;
    final url = team?.fupaUrl;
    if (_activeCloudTeamId == null || url == null || url.isEmpty) return;
    final last = await _repo.getSetting('last_fupa_autosync');
    final lastT = last == null ? null : DateTime.tryParse(last);
    if (lastT != null &&
        DateTime.now().difference(lastT) < const Duration(minutes: 30)) {
      return;
    }
    _autoRefreshing = true;
    try {
      await importSchedule(url); // Spielplan/Ergebnisse + pushTeamToCloud
      await _repo.setSetting(
          'last_fupa_autosync', DateTime.now().toIso8601String());
    } catch (_) {
      // Offline/FuPa-Fehler: später erneut.
    } finally {
      _autoRefreshing = false;
    }
  }

  /// Voller FuPa-Import (Kader + Fotos + Logo + Spielplan + Statistik) des
  /// aktiven Cloud-Teams → spiegelt ALLES in die Cloud. Schwer (Fotos), daher
  /// nur gedrosselt (alle 6 h) und still im Hintergrund.
  Future<void> maybeAutoFullRefresh() async {
    if (_autoRefreshing) return;
    final team = _ownTeam;
    final url = team?.fupaUrl;
    if (_activeCloudTeamId == null || url == null || url.isEmpty) return;
    final last = await _repo.getSetting('last_fupa_full');
    final lastT = last == null ? null : DateTime.tryParse(last);
    if (lastT != null &&
        DateTime.now().difference(lastT) < const Duration(hours: 6)) {
      return;
    }
    _autoRefreshing = true;
    try {
      await connectOwnTeam(url); // inkl. Fotos/Logo/Statistik → pushTeamToCloud
      final nowIso = DateTime.now().toIso8601String();
      await _repo.setSetting('last_fupa_full', nowIso);
      await _repo.setSetting('last_fupa_autosync', nowIso);
    } catch (_) {
      // Offline/FuPa-Fehler: später erneut.
    } finally {
      _autoRefreshing = false;
    }
  }

  /// Manueller Voll-Import aus FuPa (Kader, Fotos, Logo, Spielplan, Statistik,
  /// Geburtsdatum) – umgeht die 6h-Drossel. Für den „Jetzt aktualisieren"-
  /// Button. [url] = Cloud-FuPa-Link des Teams (fällt sonst auf den lokalen
  /// zurück). Gibt die Zusammenfassung zurück bzw. null, wenn kein Link/kein
  /// aktives Cloud-Team.
  Future<ConnectSummary?> refreshFromFupaNow(
      {String? url, void Function(String)? onProgress}) async {
    final link = (url != null && url.isNotEmpty) ? url : _ownTeam?.fupaUrl;
    if (_activeCloudTeamId == null || link == null || link.isEmpty) return null;
    if (_autoRefreshing) return null;
    _autoRefreshing = true;
    try {
      final summary = await connectOwnTeam(link, onProgress: onProgress);
      final nowIso = DateTime.now().toIso8601String();
      await _repo.setSetting('last_fupa_full', nowIso);
      await _repo.setSetting('last_fupa_autosync', nowIso);
      return summary;
    } finally {
      _autoRefreshing = false;
    }
  }

  /// Realtime: GENAU die geänderte Zeile anwenden (sofortige Updates, kein
  /// Voll-Reload). Serialisiert, damit sich die Schreibzugriffe nicht überholen.
  void _onRemoteRowChange(
      String table, String eventType, Map<String, dynamic> record) {
    _applyQueue = _applyQueue
        .then((_) => _applyRemoteChange(table, eventType, record))
        .catchError((_) {});
  }

  Future<void> _applyRemoteChange(
      String table, String eventType, Map<String, dynamic> record) async {
    final teamId = _activeCloudTeamId;
    if (teamId == null) return;
    final now = DateTime.now();
    try {
      if (eventType == 'delete') {
        final id = record['id'] as String?;
        if (id != null) await _repo.deleteByIdRaw(table, id);
      } else {
        switch (table) {
          case 'players':
            await _applyCloudPlayer(record, teamId, now);
          case 'matches':
            final id = record['id'] as String?;
            if (id != null) {
              final local = await _repo.getMatch(id);
              // Selbst verwaltete Spiele (zurückgesetzt/live) nicht überschreiben.
              if (local != null && local.locallyManaged) break;
            }
            await _repo.upsertRawById(
                'matches', _matchFromCloud(record, teamId, now).toMap());
          case 'match_events':
            await _applyRemoteEvent(record, teamId, now);
          case 'player_stats':
            await _pullStatsFromCloud(teamId);
          case 'teams':
            // Eigene Team-Zeile (Name/Kurzname/Logo/Materialdienst).
            await _applyCloudTeamRow(Map<String, dynamic>.from(record), teamId);
          case 'opponent_teams':
          case 'opponent_players':
            await _pullOpponentsFromCloud(teamId);
          default:
            // Bereichstabellen (Nominierung, Karten, Notizen, …).
            final map = Map<String, Object?>.from(record);
            if (table != 'lineups') map.remove('team_id');
            if (_noIdTables.contains(table)) {
              await _repo.insertRawForPull(table, map);
            } else {
              await _repo.upsertRawById(table, map);
            }
        }
      }
    } catch (_) {
      // Einzelne Änderung überspringen – der Voll-Abgleich holt sie später.
    }
    await _reload();
    notifyListeners();
  }

  /// Wendet ein einzelnes Cloud-Ereignis lokal an (Eigen/Gegner-Zuordnung).
  Future<void> _applyRemoteEvent(
      Map<String, dynamic> r, String teamId, DateTime now) async {
    String? localTeam;
    if (r['is_opponent'] == true) {
      final m = await _repo.getMatch(r['match_id'] as String);
      localTeam = m?.opponentTeamId;
      if (localTeam == null) return;
    } else {
      localTeam = _ownTeam?.id ?? teamId;
    }
    await _repo.upsertRawById('match_events', {
      'id': r['id'],
      'match_id': r['match_id'],
      'team_id': localTeam,
      'minute': (r['minute'] as num?)?.toInt() ?? 0,
      'minute_extra': (r['minute_extra'] as num?)?.toInt() ?? 0,
      'type': r['type'],
      'player_id': r['player_id'],
      'assist_player_id': r['assist_player_id'],
      'note': r['note'],
      'created_at':
          (r['created_at'] as String?) ?? DateTime.now().toIso8601String(),
    });
  }

  /// Zieht Spiele, Kader, Ereignisse und Bereiche des aktiven Teams frisch aus
  /// der Cloud in den lokalen Cache (ohne Wipe) und benachrichtigt die UI.
  Future<void> _refreshActiveTeamFromCloud(String teamId) async {
    if (_activeCloudTeamId != teamId ||
        !CloudService.ready ||
        !CloudService.signedIn) {
      return;
    }
    try {
      final now = DateTime.now();
      // Eigene Team-Zeile (Name/Kurzname/Logo/Materialdienst) mitziehen.
      try {
        await _applyCloudTeamRow(await CloudService.teamById(teamId), teamId);
      } catch (_) {}
      final players = await CloudService.players(teamId);
      for (final p in players) {
        await _applyCloudPlayer(p, teamId, now);
      }
      // Gegner VOR den Spielen (matches.opponent_team_id → teams-FK).
      await _pullOpponentsFromCloud(teamId);
      final matches = await CloudService.matches(teamId);
      for (final m in matches) {
        final mid = m['id'] as String?;
        if (mid != null) {
          final local = await _repo.getMatch(mid);
          // Selbst verwaltete Spiele (zurückgesetzt/live) nicht überschreiben.
          if (local != null && local.locallyManaged) continue;
        }
        await _repo.upsertRawById('matches',
            _matchFromCloud(m, teamId, now).toMap());
      }
      await _pullEventsFromCloud(teamId, replace: false);
      await _pullAuxFromCloud(teamId, replace: false);
      await _pullStatsFromCloud(teamId);
    } catch (_) {
      // Offline/Teilfehler – lokaler Stand bleibt gültig.
    }
    await _reload();
    notifyListeners();
  }

  /// Übernimmt eine Cloud-Team-Zeile (Name/Kurzname/Logo + Materialdienst-JSON)
  /// in den lokalen Cache des eigenen Teams. fupa_url wird bewusst NICHT
  /// gespiegelt, damit nur das Trainer-Gerät mit Link automatisch importiert.
  Future<void> _applyCloudTeamRow(
      Map<String, dynamic> t, String teamId) async {
    final existing = await _repo.getTeam(teamId);
    if (existing != null) {
      final name = t['name'] as String?;
      final shortName = t['short_name'] as String?;
      final logo = t['logo'] as String?;
      await _repo.upsertTeam(existing.copyWith(
        name: (name == null || name.isEmpty) ? existing.name : name,
        shortName: (shortName == null || shortName.isEmpty) ? null : shortName,
        logoPath: (logo == null || logo.isEmpty) ? null : logo,
      ));
    }
    // Ball-/Materialdienst-Konfiguration (JSON) lokal spiegeln.
    if (t.containsKey('material_duty')) {
      final md = t['material_duty'] as String?;
      await _repo.setSetting(
          'material_duty_$teamId', (md == null || md.isEmpty) ? null : md);
    }
  }

  /// Lädt die Cloud-Statistik eines Teams in den lokalen Cache (ersetzt).
  Future<void> _pullStatsFromCloud(String teamId) async {
    if (!CloudService.ready || !CloudService.signedIn) return;
    try {
      final rows = await CloudService.fetchForTeam('player_stats', teamId);
      final stats = [
        for (final r in rows)
          PlayerStat(
            id: (r['id'] as String?) ?? _uuid.v4(),
            teamId: teamId,
            externalId: r['external_id'] as String?,
            firstName: (r['first_name'] as String?) ?? '',
            lastName: (r['last_name'] as String?) ?? '',
            matches: (r['matches'] as num?)?.toInt() ?? 0,
            goals: (r['goals'] as num?)?.toInt() ?? 0,
            assists: (r['assists'] as num?)?.toInt() ?? 0,
            yellowCards: (r['yellow_cards'] as num?)?.toInt() ?? 0,
            yellowRedCards: (r['yellow_red_cards'] as num?)?.toInt() ?? 0,
            redCards: (r['red_cards'] as num?)?.toInt() ?? 0,
            minutes: (r['minutes'] as num?)?.toInt() ?? 0,
            topEleven: (r['top_eleven'] as num?)?.toInt() ?? 0,
          )
      ];
      await _repo.replaceStats(teamId, stats);
    } catch (_) {}
  }

  /// Spiegelt den Gegner eines Spiels (Team-Meta + Kader) in die Cloud und
  /// setzt die Verknüpfung am Cloud-Spiel – damit das ganze Team denselben
  /// Gegnerkader sieht.
  Future<void> _pushOpponentToCloud(String matchId) async {
    final cloudTeam = _activeCloudTeamId;
    if (cloudTeam == null || !CloudService.ready || !CloudService.signedIn) {
      return;
    }
    try {
      final m = await _repo.getMatch(matchId);
      final oppId = m?.opponentTeamId;
      if (oppId == null) return;
      final opp = await _repo.getTeam(oppId);
      if (opp == null) return;
      await CloudService.uploadOpponentTeam(cloudTeam, {
        'id': opp.id,
        'name': opp.name,
        'short_name': opp.shortName,
        'logo': opp.logoPath,
        'fupa_url': opp.fupaUrl,
      });
      final players = await _repo.getPlayers(oppId);
      await CloudService.uploadOpponentPlayers(cloudTeam, oppId, [
        for (final p in players)
          {
            'id': p.id,
            'first_name': p.firstName,
            'last_name': p.lastName,
            'number': p.number,
            'position': p.position,
            'photo': p.photoPath,
          }
      ]);
      await CloudService.updateMatch(matchId, {'opponent_team_id': oppId});
    } catch (_) {
      // Offline/keine Rechte – lokaler Stand bleibt gültig.
    }
  }

  /// Lädt geteilte Gegner-Teams + -Kader aus der Cloud in den lokalen Cache.
  /// Muss VOR den Spielen laufen (matches.opponent_team_id → teams-FK).
  Future<void> _pullOpponentsFromCloud(String teamId) async {
    if (!CloudService.ready || !CloudService.signedIn) return;
    final now = DateTime.now();
    try {
      final teams = await CloudService.fetchForTeam('opponent_teams', teamId);
      for (final t in teams) {
        await _repo.upsertRawById('teams', {
          'id': t['id'],
          'name': (t['name'] as String?) ?? 'Gegner',
          'short_name': t['short_name'],
          'fupa_url': t['fupa_url'],
          'logo_path': t['logo'],
          'is_own_team': 0,
          'source': DataSource.fupaApproved.storageKey,
          'created_at': now.toIso8601String(),
        });
      }
      final players =
          await CloudService.fetchForTeam('opponent_players', teamId);
      for (final p in players) {
        try {
          await _repo.upsertRawById('players', {
            'id': p['id'],
            'team_id': p['opponent_team_id'],
            'first_name': (p['first_name'] as String?) ?? '',
            'last_name': (p['last_name'] as String?) ?? '',
            'number': p['number'],
            'position': p['position'],
            'photo_path': p['photo'],
            'source': DataSource.fupaApproved.storageKey,
            'active': 1,
            'created_at': now.toIso8601String(),
          });
        } catch (_) {}
      }
    } catch (_) {}
  }

  List<GameMatch> _matches = [];
  List<GameMatch> get matches => List.unmodifiable(_matches);

  late final OpponentSyncService opponentSync =
      OpponentSyncService(repository: _repo, importer: _importer);

  // ------------------------------------------------------------- Lifecycle
  Future<void> init() async {
    await _reload();
    // Aktives Cloud-Team wiederherstellen (für Schreib-Sync nach Neustart).
    _activeCloudTeamId = await _repo.getSetting('active_cloud_team');
    await _autoRevertAbsences();
    _loading = false;
    notifyListeners();
    // Realtime-Sync fortsetzen, falls ein Cloud-Team aktiv ist (und bereit).
    if (_activeCloudTeamId != null) ensureTeamSync(_activeCloudTeamId!);
  }

  Future<void> _reload() async {
    _ownTeam = await _repo.getOwnTeam();
    _matches = _ownTeam == null ? [] : await _repo.getMatches(_ownTeam!.id);
  }

  Future<void> refresh() async {
    await _reload();
    notifyListeners();
  }

  @override
  void dispose() {
    _stopTeamSync();
    super.dispose();
  }

  // ----------------------------------------------------------- FuPa-Import
  /// Verbindet das eigene Team über einen FuPa-Teamlink und lädt alles:
  /// Vereinsdaten + Logo, Kader + Fotos, Spielplan + Ergebnisse, Statistik.
  Future<ConnectSummary> connectOwnTeam(String url,
      {void Function(String)? onProgress}) async {
    onProgress?.call('Mannschaft & Kader werden geladen …');
    final teamImport = await _importer.importTeam(url);
    final team = await _persist.saveOwnTeam(url, teamImport);

    onProgress?.call('Spielerfotos werden geladen …');
    final playerData =
        await _importer.toPlayerDataWithPhotos(teamImport.players);
    await _persist.syncPlayers(team.id, playerData, DataSource.fupaApproved);

    onProgress?.call('Spielplan wird geladen (ganze Saison) …');
    final matches = await _fullSchedule(url);
    final newMatches = await _persist.syncSchedule(team.id, matches);

    onProgress?.call('Statistik wird geladen …');
    var statsCount = 0;
    try {
      statsCount = await _importStatsInto(team.id, url);
    } catch (_) {
      // Statistik ist optional – Rest des Imports bleibt gültig.
    }

    await _reload();
    notifyListeners();
    // Falls dieses Team ein Cloud-Team ist: Aktualisierung direkt teilen.
    await pushTeamToCloud();
    return ConnectSummary(
      teamName: team.name,
      players: playerData.length,
      matches: matches.length,
      newMatches: newMatches,
      stats: statsCount,
    );
  }

  /// Lädt ein Cloud-Team komplett in den lokalen Cache (ersetzt bestehende
  /// lokale Teamdaten). cloud-first: das lokale Abbild der geteilten Daten.
  Future<void> downloadCloudTeam(
    String cloudTeamId,
    String name, {
    required List<Map<String, dynamic>> players,
    required List<Map<String, dynamic>> matches,
    String? fupaUrl,
    String? logoPath,
    String? shortName,
  }) async {
    await _repo.wipeTeams();
    _activeCloudTeamId = cloudTeamId; // ab jetzt Schreib-Sync in die Cloud
    await _repo.setSetting('active_cloud_team', cloudTeamId);
    final now = DateTime.now();
    await _repo.upsertTeam(Team(
      id: cloudTeamId,
      name: name,
      shortName: (shortName == null || shortName.isEmpty) ? null : shortName,
      isOwnTeam: true,
      source: DataSource.fupaApproved,
      fupaUrl: (fupaUrl == null || fupaUrl.isEmpty) ? null : fupaUrl,
      logoPath: (logoPath == null || logoPath.isEmpty) ? null : logoPath,
      createdAt: now,
    ));
    for (final p in players) {
      await _repo.upsertPlayer(_playerFromCloud(p, cloudTeamId, now));
    }
    // Gegner VOR den Spielen (matches.opponent_team_id → teams-FK).
    await _pullOpponentsFromCloud(cloudTeamId);
    for (final m in matches) {
      await _repo.upsertMatch(_matchFromCloud(m, cloudTeamId, now));
    }
    // Ereignisse (für Chronik/Erwähnungen) vor den Bereichsdaten laden,
    // damit event_mentions die lokalen match_events referenzieren können.
    await _pullEventsFromCloud(cloudTeamId, replace: true);
    // Alle geteilten Bereiche (Nominierung, Aufstellung, Karten, Notizen,
    // Bewertungen, Aufgaben, Gespräche, Abwesenheiten, Erwähnungen) mitladen.
    await _pullAuxFromCloud(cloudTeamId, replace: true);
    await _pullStatsFromCloud(cloudTeamId);
    await _reload();
    notifyListeners();
    // Ab jetzt Änderungen dieses Teams überall live übernehmen.
    ensureTeamSync(cloudTeamId);
  }

  /// Aktualisiert den lokalen Cache mit frischen Cloud-Spielen – ohne Wipe,
  /// nur ergänzend/überschreibend (für Realtime-Auto-Sync). Wirkt nur, wenn
  /// dieses Team das aktive Cloud-Team ist.
  Future<void> syncCloudMatchesToCache(
      String cloudTeamId, List<Map<String, dynamic>> matches) async {
    if (_activeCloudTeamId != cloudTeamId) return;
    final now = DateTime.now();
    for (final m in matches) {
      await _repo.upsertMatch(_matchFromCloud(m, cloudTeamId, now));
    }
    await _reload();
    notifyListeners();
  }

  /// Aktualisiert den lokalen Kader-Cache mit frischen Cloud-Spielern – ohne
  /// Wipe. Wirkt nur, wenn dieses Team das aktive Cloud-Team ist.
  Future<void> syncCloudPlayersToCache(
      String cloudTeamId, List<Map<String, dynamic>> players) async {
    if (_activeCloudTeamId != cloudTeamId) return;
    final now = DateTime.now();
    for (final p in players) {
      await _applyCloudPlayer(p, cloudTeamId, now);
    }
    notifyListeners();
  }

  Player _playerFromCloud(Map<String, dynamic> p, String teamId, DateTime now) =>
      Player(
        id: p['id'] as String,
        teamId: teamId,
        firstName: (p['first_name'] as String?) ?? '',
        lastName: (p['last_name'] as String?) ?? '',
        number: (p['number'] as num?)?.toInt(),
        position: p['position'] as String?,
        photoPath: p['photo'] as String?,
        birthdate: DateTime.tryParse((p['birthdate'] as String?) ?? ''),
        status: PlayerStatus.fromKey(p['status'] as String?),
        captainRole: CaptainRole.fromKey(p['captain_role'] as String?),
        active: (p['active'] as bool?) ?? true,
        nickname: p['nickname'] as String?,
        positions: ((p['positions'] as String?) ?? '')
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList(),
        wishPosition: p['wish_position'] as String?,
        staffRole: p['staff_role'] as String?,
        source: DataSource.fupaApproved,
        createdAt: now,
      );

  /// Geteilte Spielerfelder für die Cloud. Der Kader ist mannschaftsweit
  /// geteilt: Name, Nr., Position(en), Foto, Geburtsdatum, Status (inkl.
  /// Deaktivierung), Kapitän, Spitzname, Wunsch-/Aktuelle Positionen, Staff.
  Map<String, dynamic> _playerCloudMap(Player p) => {
        'id': p.id,
        'first_name': p.firstName,
        'last_name': p.lastName,
        'number': p.number,
        'position': p.position,
        'photo': p.photoPath,
        'birthdate': p.birthdate?.toIso8601String(),
        'status': p.status.storageKey,
        'active': p.active,
        'captain_role': p.captainRole.storageKey,
        'nickname': p.nickname,
        'positions': p.positions.join(','),
        'wish_position': p.wishPosition,
        'staff_role': p.staffRole,
      };

  /// Übernimmt einen Cloud-Spieler in den lokalen Cache. Felder werden nur
  /// übernommen, wenn die Cloud sie liefert (null = lokalen Wert behalten) –
  /// so clobbern alte Zeilen ohne diese Spalten nichts.
  Future<void> _applyCloudPlayer(
      Map<String, dynamic> record, String teamId, DateTime now) async {
    final id = record['id'] as String?;
    if (id == null) return;
    final existing = await _repo.getPlayer(id);
    if (existing == null) {
      await _repo.upsertPlayer(_playerFromCloud(record, teamId, now));
      return;
    }
    final statusRaw = record['status'] as String?;
    final captainRaw = record['captain_role'] as String?;
    final activeRaw = record['active'];
    final positionsRaw = record['positions'] as String?;
    await _repo.upsertPlayer(existing.copyWith(
      firstName: record['first_name'] as String?,
      lastName: record['last_name'] as String?,
      number: (record['number'] as num?)?.toInt(),
      position: record['position'] as String?,
      photoPath: record['photo'] as String?,
      birthdate: DateTime.tryParse((record['birthdate'] as String?) ?? ''),
      status: statusRaw == null ? null : PlayerStatus.fromKey(statusRaw),
      captainRole: captainRaw == null ? null : CaptainRole.fromKey(captainRaw),
      active: activeRaw is bool
          ? activeRaw
          : (activeRaw is num ? activeRaw != 0 : null),
      nickname: record['nickname'] as String?,
      positions: positionsRaw
          ?.split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList(),
      wishPosition: record['wish_position'] as String?,
      staffRole: record['staff_role'] as String?,
    ));
  }

  GameMatch _matchFromCloud(Map<String, dynamic> m, String teamId, DateTime now) {
    final kickoffStr = m['kickoff'] as String?;
    final oppTeamId = m['opponent_team_id'] as String?;
    return GameMatch(
      id: m['id'] as String,
      ownTeamId: teamId,
      opponentName: (m['opponent'] as String?) ?? 'Gegner',
      opponentLogoPath: m['opponent_logo'] as String?,
      opponentTeamId: oppTeamId,
      // Verknüpfter Gegner → Kader liegt (geteilt) vor, kein „manuell"-Hinweis.
      opponentImported: oppTeamId != null,
      kickoff:
          kickoffStr == null ? null : DateTime.tryParse(kickoffStr)?.toLocal(),
      venue: (m['venue'] == 'Auswärts') ? Venue.away : Venue.home,
      ownScore: (m['own_score'] as num?)?.toInt() ?? 0,
      opponentScore: (m['opponent_score'] as num?)?.toInt() ?? 0,
      status: MatchStatus.fromKey(m['status'] as String?),
      locallyManaged: m['locally_managed'] == true,
      createdAt: now,
    );
  }

  /// Spiegelt den aktuellen Kader + Spielplan des aktiven Cloud-Teams nach
  /// einem FuPa-Import/-Resync in die Cloud. IDs bleiben stabil; bestehende
  /// Spiele werden aktualisiert (Ergebnis/Status), nicht gelöscht. Nur wirksam,
  /// wenn ein Cloud-Team aktiv ist – sonst (reiner Lokalbetrieb) ein No-op.
  Future<void> pushTeamToCloud() async {
    final cloudTeam = _activeCloudTeamId;
    final team = _ownTeam;
    if (cloudTeam == null || team == null) return;
    if (!CloudService.ready || !CloudService.signedIn) return;
    try {
      final players = await _repo.getPlayers(team.id);
      final roster = [
        for (final p in players.where((p) => !p.isStaffOnly))
          _playerCloudMap(p)
      ];
      await CloudService.uploadRoster(cloudTeam, roster);
      final matchRows = [
        for (final m in _matches)
          {
            'id': m.id,
            'team_id': cloudTeam,
            'opponent': m.opponentName,
            'opponent_logo': m.opponentLogoPath,
            'opponent_team_id': m.opponentTeamId,
            'kickoff': m.kickoff?.toUtc().toIso8601String(),
            'venue': m.venue == Venue.home ? 'Heim' : 'Auswärts',
            'own_score': m.ownScore,
            'opponent_score': m.opponentScore,
            'status': m.status.storageKey,
            'locally_managed': m.locallyManaged,
          }
      ];
      await CloudService.upsertMatches(matchRows);
      // Eigenes Logo + Name am Cloud-Team aktualisieren.
      await CloudService.updateTeam(cloudTeam, {
        'name': team.name,
        'short_name': team.shortName,
        'logo': team.logoPath,
      });
      // Statistik spiegeln.
      final stats = await _repo.getStats(team.id);
      await CloudService.uploadStats(cloudTeam, [
        for (final s in stats)
          {
            'id': s.id,
            'external_id': s.externalId,
            'first_name': s.firstName,
            'last_name': s.lastName,
            'matches': s.matches,
            'goals': s.goals,
            'assists': s.assists,
            'yellow_cards': s.yellowCards,
            'yellow_red_cards': s.yellowRedCards,
            'red_cards': s.redCards,
            'minutes': s.minutes,
            'top_eleven': s.topEleven,
          }
      ]);
    } catch (_) {
      // Offline / keine Trainer-Rechte – lokaler Stand bleibt gültig.
    }
  }

  /// Lädt alles für das bereits verbundene Team erneut.
  Future<ConnectSummary> resyncOwnTeam({void Function(String)? onProgress}) async {
    final url = _ownTeam?.fupaUrl;
    if (url == null || url.isEmpty) {
      throw StateError('Kein verbundenes Team mit FuPa-Link.');
    }
    return connectOwnTeam(url, onProgress: onProgress);
  }

  /// Importiert den Spielplan (inkl. Ergebnisse, Gegner-Link und -Logo) aus
  /// einem FuPa-Team-/Matches-Link. Gibt die Anzahl NEUER Spiele zurück.
  Future<int> importSchedule(String url) async {
    final team = await ensureOwnTeam();
    final matches = await _fullSchedule(url);
    final added = await _persist.syncSchedule(team.id, matches);
    await _reload();
    notifyListeners();
    await pushTeamToCloud();
    return added;
  }

  /// Team-Spielplan (ab aktuellem Spieltag) + ganze Saison aus der Liga-API
  /// (inkl. vergangener Spieltage), dedupliziert pro Gegner und Spieltag.
  Future<List<ScheduledMatchData>> _fullSchedule(String url) async {
    final teamMatches = await _importer.importSchedule(url);
    var leagueMatches = const <ScheduledMatchData>[];
    try {
      leagueMatches = await _importer.importLeagueScheduleForTeam(url);
    } catch (_) {
      // Liga-Nachladen ist optional (z.B. ohne Liga-Kontext).
    }
    final seen = <String>{};
    final out = <ScheduledMatchData>[];
    for (final m in [...teamMatches, ...leagueMatches]) {
      final day = m.kickoff?.toIso8601String().substring(0, 10) ??
          m.externalId ??
          '';
      final key = '${m.opponentName.trim().toLowerCase()}|$day';
      if (seen.add(key)) out.add(m);
    }
    return out;
  }

  /// Importiert die Spieler-Saison-Statistik aus einem FuPa-Link und ersetzt
  /// den bisherigen Stand des Teams. Gibt die Anzahl Spieler zurück.
  Future<int> importStats(String teamId, String url) async {
    final n = await _importStatsInto(teamId, url);
    notifyListeners();
    return n;
  }

  /// Stellt sicher, dass für ein (Gegner-)Team eine Statistik vorliegt: fehlt
  /// sie und ist ein FuPa-Link hinterlegt, wird sie nachgeladen. So zeigt die
  /// Gegner-Analyse Torjäger & Co. auch ohne manuelles Neu-Synchronisieren.
  Future<void> ensureOpponentStats(String teamId) async {
    final existing = await _repo.getStats(teamId);
    if (existing.isNotEmpty) return;
    final team = await _repo.getTeam(teamId);
    final url = team?.fupaUrl;
    if (url == null || url.isEmpty) return;
    try {
      await _importStatsInto(teamId, url);
      notifyListeners();
    } catch (_) {
      // Statistik ist optional.
    }
  }

  Future<int> _importStatsInto(String teamId, String url) async {
    final data = await _importer.importStats(url);
    final stats = data
        .map((d) => PlayerStat(
              id: _uuid.v4(),
              teamId: teamId,
              externalId: d.externalId,
              firstName: d.firstName,
              lastName: d.lastName,
              matches: d.matches,
              goals: d.goals,
              assists: d.assists,
              yellowCards: d.yellowCards,
              yellowRedCards: d.yellowRedCards,
              redCards: d.redCards,
              minutes: d.minutes,
              topEleven: d.topEleven,
            ))
        .toList();
    await _repo.replaceStats(teamId, stats);
    return stats.length;
  }

  Future<List<PlayerStat>> statsOf(String teamId) => _repo.getStats(teamId);

  // -------------------------------------------------------- Team / Players
  Future<Team> ensureOwnTeam() async {
    _ownTeam ??= await _repo.getOwnTeam();
    if (_ownTeam == null) {
      final t = Team(
        id: _uuid.v4(),
        name: 'Meine Mannschaft',
        isOwnTeam: true,
        source: DataSource.manual,
        createdAt: DateTime.now(),
      );
      await _repo.upsertTeam(t);
      _ownTeam = t;
      notifyListeners();
    }
    return _ownTeam!;
  }

  Future<void> renameTeam(String teamId, String name, {String? shortName}) async {
    final t = await _repo.getTeam(teamId);
    if (t == null) return;
    await _repo.upsertTeam(t.copyWith(name: name, shortName: shortName));
    await _reload();
    notifyListeners();
    // Umbenennung teilen, wenn dies das aktive Cloud-Team ist.
    if (_activeCloudTeamId == teamId &&
        CloudService.ready &&
        CloudService.signedIn) {
      try {
        await CloudService.updateTeam(
            teamId, {'name': name, 'short_name': shortName});
      } catch (_) {}
    }
  }

  /// Übernimmt importierte Vereinsdaten (Name/Kurzname/Logo) in ein Team.
  Future<void> updateTeamMeta(
    String teamId, {
    String? name,
    String? shortName,
    String? logoPath,
  }) async {
    final t = await _repo.getTeam(teamId);
    if (t == null) return;
    await _repo.upsertTeam(t.copyWith(
      name: (name != null && name.isNotEmpty) ? name : null,
      shortName: (shortName != null && shortName.isNotEmpty) ? shortName : null,
      logoPath: (logoPath != null && logoPath.isNotEmpty) ? logoPath : null,
    ));
    await _reload();
    notifyListeners();
  }

  Future<List<Player>> playersOf(String teamId, {bool onlyActive = false}) =>
      _repo.getPlayers(teamId, onlyActive: onlyActive);

  Future<void> addPlayer(
    String teamId, {
    required String firstName,
    required String lastName,
    int? number,
    String? position,
    String? wishPosition,
    PlayerStatus status = PlayerStatus.fit,
    CaptainRole captainRole = CaptainRole.none,
  }) async {
    final player = Player(
      id: _uuid.v4(),
      teamId: teamId,
      firstName: firstName.trim(),
      lastName: lastName.trim(),
      number: number,
      position: position,
      wishPosition: wishPosition,
      status: status,
      captainRole: captainRole,
      source: DataSource.manual,
      createdAt: DateTime.now(),
    );
    await _repo.upsertPlayer(player);
    await _enforceCaptainUniqueness(player);
    notifyListeners();
  }

  Future<void> updatePlayer(Player player) async {
    await _repo.upsertPlayer(player);
    await _enforceCaptainUniqueness(player);
    notifyListeners();
    // Geteilte Felder (Name/Nr/Position/Foto/Geburtsdatum) in die Cloud – nur
    // für das eigene aktive Cloud-Team (lokale id == Cloud-id).
    final cloudTeam = _activeCloudTeamId;
    if (cloudTeam != null &&
        player.teamId == cloudTeam &&
        CloudService.ready &&
        CloudService.signedIn) {
      try {
        await CloudService.uploadRoster(cloudTeam, [_playerCloudMap(player)]);
      } catch (_) {}
    }
  }

  // ---------------------------------------------------------- Abwesenheiten
  Future<List<PlayerAbsence>> absencesOf(String playerId) =>
      _repo.getAbsences(playerId);

  /// Legt eine Abwesenheit an (Zeitraum + Grund) und setzt den Spielerstatus.
  Future<void> addAbsence({
    required Player player,
    required PlayerStatus status,
    required DateTime from,
    required DateTime until,
    String? note,
  }) async {
    await _repo.upsertAbsence(PlayerAbsence(
      id: _uuid.v4(),
      playerId: player.id,
      status: status,
      from: from,
      until: until,
      note: note,
      createdAt: DateTime.now(),
    ));
    await updatePlayer(player.copyWith(status: status));
  }

  Future<void> updateAbsence(PlayerAbsence a) async {
    await _repo.upsertAbsence(a);
    notifyListeners();
  }

  Future<void> deleteAbsence(String id) async {
    await _repo.deleteAbsence(id);
    notifyListeners();
  }

  /// FuPa-Saisonstatistik eines Spielers (über den Namen zugeordnet).
  Future<PlayerStat?> playerSeasonStat(String teamId, String dedupKey) async {
    final stats = await _repo.getStats(teamId);
    for (final s in stats) {
      final key =
          '${s.firstName.trim().toLowerCase()}|${s.lastName.trim().toLowerCase()}';
      if (key == dedupKey) return s;
    }
    return null;
  }

  /// Setzt Spieler, deren Abwesenheit abgelaufen ist, automatisch auf „Fit".
  Future<void> _autoRevertAbsences() async {
    final team = _ownTeam;
    if (team == null) return;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final players = await _repo.getPlayers(team.id);
    for (final p in players) {
      if (!p.status.isAbsence) continue;
      final abs = await _repo.getAbsences(p.id);
      PlayerAbsence? current;
      for (final a in abs) {
        if (a.status == p.status) {
          current = a;
          break;
        }
      }
      // Abgelaufen (letzter Tag liegt vor heute) -> wieder Fit.
      if (current != null && current.until.isBefore(today)) {
        await _repo.upsertPlayer(p.copyWith(status: PlayerStatus.fit));
      }
    }
  }

  /// Sorgt dafür, dass jede Kapitäns-Rolle pro Team nur einmal vergeben ist.
  Future<void> _enforceCaptainUniqueness(Player player) async {
    if (player.captainRole == CaptainRole.none) return;
    final mates = await _repo.getPlayers(player.teamId);
    for (final other in mates) {
      if (other.id != player.id && other.captainRole == player.captainRole) {
        await _repo.upsertPlayer(other.copyWith(captainRole: CaptainRole.none));
      }
    }
  }

  Future<void> deletePlayer(String id) async {
    await _repo.deletePlayer(id);
    notifyListeners();
  }

  /// Übernimmt per Einfügen erkannte Spieler mit Duplikatschutz
  /// (gleiche Dedup-Regeln wie der FuPa-Import). Gibt die Anzahl NEU
  /// angelegter Spieler zurück.
  Future<int> importPastedPlayers(
      String teamId, List<PlayerData> players) async {
    if (players.isEmpty) return 0;
    final persist = FupaPersistence(_repo);
    final added =
        await persist.syncPlayers(teamId, players, DataSource.manual);
    await _reload();
    notifyListeners();
    return added;
  }

  // ---------------------------------------------------------------- Matches
  Future<GameMatch> addMatch({
    required String opponentName,
    DateTime? kickoff,
    Venue venue = Venue.home,
    String? competition,
  }) async {
    final team = await ensureOwnTeam();
    final match = GameMatch(
      id: _uuid.v4(),
      ownTeamId: team.id,
      opponentName: opponentName.trim(),
      kickoff: kickoff,
      venue: venue,
      competition: competition,
      createdAt: DateTime.now(),
    );
    await _repo.upsertMatch(match);
    await _reload();
    notifyListeners();
    return match;
  }

  Future<void> updateMatch(GameMatch match) async {
    await _repo.upsertMatch(match);
    await _reload();
    notifyListeners();
  }

  Future<void> deleteMatch(String id) async {
    await _repo.deleteMatch(id);
    await _reload();
    notifyListeners();
  }

  Future<GameMatch?> getMatch(String id) => _repo.getMatch(id);

  /// Zusatz-Infos je Spiel für die Mannschafts-Kadernachricht (Spielstätte,
  /// Adresse, Treffpunkt). Pro Spiel als JSON in den Settings gehalten.
  Future<Map<String, String>> matchShareInfo(String matchId) async {
    final s = await _repo.getSetting('share_info_$matchId');
    if (s == null || s.isEmpty) return {};
    try {
      final m = jsonDecode(s) as Map<String, Object?>;
      return m.map((k, v) => MapEntry(k, (v ?? '').toString()));
    } catch (_) {
      return {};
    }
  }

  Future<void> saveMatchShareInfo(
      String matchId, Map<String, String> info) async {
    await _repo.setSetting('share_info_$matchId', jsonEncode(info));
  }

  /// Abweichende Rückennummern für genau ein Spiel (Spieler-ID → Nummer).
  /// Fehlt ein Eintrag, gilt die Standard-Nummer des Spielers.
  Future<Map<String, int>> matchNumbers(String matchId) async {
    final s = await _repo.getSetting('match_numbers_$matchId');
    if (s == null || s.isEmpty) return {};
    try {
      final m = jsonDecode(s) as Map<String, Object?>;
      final out = <String, int>{};
      m.forEach((k, v) {
        final n = v is num ? v.toInt() : int.tryParse('$v');
        if (n != null) out[k] = n;
      });
      return out;
    } catch (_) {
      return {};
    }
  }

  Future<void> setMatchNumber(
      String matchId, String playerId, int? number) async {
    final map = await matchNumbers(matchId);
    if (number == null) {
      map.remove(playerId);
    } else {
      map[playerId] = number;
    }
    await _repo.setSetting('match_numbers_$matchId', jsonEncode(map));
    notifyListeners();
  }

  /// Spieltags-Ankündigung je Spiel (Spieltag, Trikot, Adresse, Treffpunkte,
  /// Einleitungstext). Als JSON in den Settings.
  Future<Map<String, String>> matchAnnouncement(String matchId) async {
    final s = await _repo.getSetting('announce_$matchId');
    if (s == null || s.isEmpty) return {};
    try {
      final m = jsonDecode(s) as Map<String, Object?>;
      return m.map((k, v) => MapEntry(k, (v ?? '').toString()));
    } catch (_) {
      return {};
    }
  }

  Future<void> saveMatchAnnouncement(
      String matchId, Map<String, String> info) async {
    await _repo.setSetting('announce_$matchId', jsonEncode(info));
  }

  // ------------------------------------------------------------- Nominations
  /// Status je Spieler für ein Spiel (Spieler ohne Datensatz = offen).
  Future<Map<String, NominationStatus>> nominationsOf(String matchId) async {
    final rows = await _repo.getNominations(matchId);
    return {for (final n in rows) n.playerId: n.status};
  }

  Future<void> setNomination(
      String matchId, String playerId, NominationStatus status) async {
    if (status == NominationStatus.open) {
      await _repo.deleteNomination(matchId, playerId);
    } else {
      await _repo.upsertNomination(Nomination(
        id: _uuid.v4(),
        matchId: matchId,
        playerId: playerId,
        status: status,
        updatedAt: DateTime.now(),
      ));
    }
    notifyListeners();
  }

  /// Setzt für mehrere Spieler denselben Status (Bulk, z.B. „alle zusagen").
  Future<void> setNominationBulk(
      String matchId, List<String> playerIds, NominationStatus status) async {
    for (final id in playerIds) {
      if (status == NominationStatus.open) {
        await _repo.deleteNomination(matchId, id);
      } else {
        await _repo.upsertNomination(Nomination(
          id: _uuid.v4(),
          matchId: matchId,
          playerId: id,
          status: status,
          updatedAt: DateTime.now(),
        ));
      }
    }
    notifyListeners();
  }

  /// Wird beim Öffnen eines Spiels aufgerufen (Gegner sicherstellen).
  Future<ImportResult> openMatch(GameMatch match, {bool force = false}) async {
    final result =
        await opponentSync.ensureOpponentForMatch(match, force: force);
    // Bei frischem Gegner-Import auch die Torschützen-Statistik laden,
    // damit das Scouting die Toranzahl zeigen und Torjäger markieren kann.
    if (result.status == ImportStatus.success) {
      final updated = await _repo.getMatch(match.id);
      final url = updated?.opponentFupaUrl;
      final oppId = updated?.opponentTeamId;
      if (url != null && url.isNotEmpty && oppId != null) {
        try {
          await _importStatsInto(oppId, url);
        } catch (_) {
          // Statistik ist optional.
        }
      }
    }
    await _reload();
    notifyListeners();
    // Gegner (Team + Kader) teilen, damit alle denselben Gegnerkader sehen.
    await _pushOpponentToCloud(match.id);
    return result;
  }

  // ---------------------------------------------------------------- Lineups
  Future<Lineup> ensureLineup(String matchId, String teamId,
      {String formation = '4-4-2'}) async {
    final existing = await _repo.getLineup(matchId, teamId);
    if (existing != null) return existing;
    final lineup = Lineup(
      id: _uuid.v4(),
      matchId: matchId,
      teamId: teamId,
      formation: formation,
      createdAt: DateTime.now(),
    );
    await _repo.upsertLineup(lineup);
    return lineup;
  }

  Future<List<LineupEntry>> lineupEntries(String lineupId) =>
      _repo.getLineupEntries(lineupId);

  Future<void> saveLineup(Lineup lineup, List<LineupEntry> entries) async {
    await _repo.upsertLineup(lineup);
    await _repo.replaceLineupEntries(lineup.id, entries);
    notifyListeners();
  }

  String newEntryId() => _uuid.v4();

  // ----------------------------------------------------------------- Events
  Future<List<MatchEvent>> eventsOf(String matchId) => _repo.getEvents(matchId);

  /// Fügt ein Ereignis hinzu und aktualisiert bei Toren den Spielstand.
  /// Karten-Ereignisse mit bekanntem Spieler werden zusätzlich in den
  /// Spieler-Kartenverlauf übernommen (verknüpft über die Ereignis-ID).
  Future<void> addEvent({
    required String matchId,
    required String teamId,
    required int minute,
    int minuteExtra = 0,
    required MatchEventType type,
    String? playerId,
    String? assistPlayerId,
    String? note,
    List<String> mentions = const [],
  }) async {
    final eventId = _uuid.v4();
    final event = MatchEvent(
      id: eventId,
      matchId: matchId,
      teamId: teamId,
      minute: minute,
      minuteExtra: minuteExtra,
      type: type,
      playerId: playerId,
      assistPlayerId: assistPlayerId,
      note: note,
      createdAt: DateTime.now(),
    );
    await _repo.upsertEvent(event);
    if (mentions.isNotEmpty) {
      await _repo.setEventMentions(eventId, mentions);
    }

    final cardType = CardType.fromEvent(type);
    if (cardType != null && playerId != null) {
      final match = await _repo.getMatch(matchId);
      await _repo.upsertCard(CardEntry(
        id: _uuid.v4(),
        playerId: playerId,
        type: cardType,
        date: match?.kickoff ?? DateTime.now(),
        matchId: matchId,
        matchEventId: eventId,
        minute: minute,
        minuteExtra: minuteExtra,
        note: note,
      ));
    }

    await _recomputeScore(matchId);
    await _mirrorEventToCloud(event);
    notifyListeners();
  }

  /// Spiegelt ein Ereignis in die Cloud (Insert ODER Update per lokaler ID, nur
  /// bei aktivem Cloud-Team und Verbindung). Gegner-Ereignisse werden markiert
  /// (is_opponent) und ohne Spieler-Bezug gespiegelt.
  Future<void> _mirrorEventToCloud(MatchEvent e) async {
    final cloudTeam = _activeCloudTeamId;
    if (cloudTeam == null || !CloudService.ready || !CloudService.signedIn) {
      return;
    }
    final isOwn = e.teamId == _ownTeam?.id;
    try {
      await CloudService.addEvent(
        id: e.id,
        matchId: e.matchId,
        teamId: cloudTeam,
        type: e.type.storageKey,
        minute: e.minute,
        minuteExtra: e.minuteExtra,
        playerId: isOwn ? e.playerId : null,
        assistPlayerId: isOwn ? e.assistPlayerId : null,
        note: e.note ?? (isOwn ? null : 'Gegner'),
        isOpponent: !isOwn,
        createdAt: e.createdAt.toUtc().toIso8601String(),
      );
      final m = await _repo.getMatch(e.matchId);
      if (m != null) {
        await CloudService.setScore(e.matchId, m.ownScore, m.opponentScore);
      }
    } catch (_) {
      // Offline/kein Cloud-Spiel – später synchronisieren.
    }
  }

  Future<void> updateEvent(MatchEvent event) async {
    await _repo.upsertEvent(event);
    await _recomputeScore(event.matchId);
    await _mirrorEventToCloud(event);
    notifyListeners();
  }

  Future<void> deleteEvent(String matchId, String eventId) async {
    await _repo.deleteEvent(eventId);
    await _repo.deleteCardByEvent(eventId);
    await _recomputeScore(matchId);
    await _mirrorEventDeleteToCloud(eventId, matchId);
    notifyListeners();
  }

  /// Löschung eines Ereignisses in die Cloud spiegeln (inkl. neuem Spielstand).
  Future<void> _mirrorEventDeleteToCloud(String eventId, String matchId) async {
    final cloudTeam = _activeCloudTeamId;
    if (cloudTeam == null || !CloudService.ready || !CloudService.signedIn) {
      return;
    }
    try {
      await CloudService.deleteEvent(eventId);
      final m = await _repo.getMatch(matchId);
      if (m != null) {
        await CloudService.setScore(matchId, m.ownScore, m.opponentScore);
      }
    } catch (_) {}
  }

  // ------------------------------------------------------------------- Cards
  Future<List<CardEntry>> cardsOf(String playerId) => _repo.getCards(playerId);

  Future<Map<String, Map<CardType, int>>> cardCountsForTeam(String teamId) =>
      _repo.cardCountsForTeam(teamId);

  Future<List<MatchEvent>> playerMatchEvents(String playerId) =>
      _repo.getPlayerMatchEvents(playerId);

  /// Kommentare, in denen der Spieler erwähnt wurde.
  Future<List<MatchEvent>> mentionComments(String playerId) =>
      _repo.getMentionComments(playerId);

  /// Spiele eines Teams als Map (matchId -> Spiel), zum Auflösen von Gegner/Datum.
  Future<Map<String, GameMatch>> matchMap(String teamId) async {
    final list = await _repo.getMatches(teamId);
    return {for (final m in list) m.id: m};
  }

  Future<void> addCard({
    required String playerId,
    required CardType type,
    required DateTime date,
    String? matchId,
    int? minute,
    String? note,
  }) async {
    await _repo.upsertCard(CardEntry(
      id: _uuid.v4(),
      playerId: playerId,
      type: type,
      date: date,
      matchId: matchId,
      minute: minute,
      note: note,
    ));
    notifyListeners();
  }

  Future<void> updateCard(CardEntry card) async {
    await _repo.upsertCard(card);
    notifyListeners();
  }

  Future<void> deleteCard(String id) async {
    await _repo.deleteCard(id);
    notifyListeners();
  }

  // ------------------------------------------------------------- Player notes
  Future<List<PlayerNote>> notesOf(String playerId) => _repo.getNotes(playerId);

  Future<void> addNote(String playerId, String text,
      {String? categoryId, String? matchId}) async {
    await _repo.upsertNote(PlayerNote(
      id: _uuid.v4(),
      playerId: playerId,
      text: text.trim(),
      createdAt: DateTime.now(),
      categoryId: categoryId,
      matchId: matchId,
    ));
    notifyListeners();
  }

  Future<void> updateNote(PlayerNote note) async {
    await _repo.upsertNote(note);
    notifyListeners();
  }

  Future<void> deleteNote(String id) async {
    await _repo.deleteNote(id);
    notifyListeners();
  }

  // --------------------------------------------------------- Note categories
  Future<List<NoteCategory>> noteCategories() => _repo.getNoteCategories();

  Future<void> addNoteCategory(String name) async {
    final existing = await _repo.getNoteCategories();
    await _repo.upsertNoteCategory(NoteCategory(
      id: _uuid.v4(),
      name: name.trim(),
      sortOrder: existing.length,
    ));
    notifyListeners();
  }

  Future<void> updateNoteCategory(NoteCategory cat) async {
    await _repo.upsertNoteCategory(cat);
    notifyListeners();
  }

  Future<void> deleteNoteCategory(String id) async {
    await _repo.deleteNoteCategory(id);
    notifyListeners();
  }

  // ------------------------------------------------------------- Team events
  Future<List<TeamEvent>> teamEvents() async {
    final team = await _repo.getOwnTeam();
    if (team == null) return [];
    return _repo.getTeamEvents(team.id);
  }

  Future<TeamEvent> addTeamEvent({
    required String title,
    required TeamEventType type,
    required DateTime date,
    String? location,
    String? note,
  }) async {
    final team = await ensureOwnTeam();
    final event = TeamEvent(
      id: _uuid.v4(),
      teamId: team.id,
      title: title.trim(),
      type: type,
      date: date,
      location: location,
      note: note,
      createdAt: DateTime.now(),
    );
    await _repo.upsertTeamEvent(event);
    notifyListeners();
    return event;
  }

  Future<TeamEvent?> getTeamEvent(String id) => _repo.getTeamEvent(id);

  Future<void> updateTeamEvent(TeamEvent event) async {
    await _repo.upsertTeamEvent(event);
    notifyListeners();
  }

  Future<void> deleteTeamEvent(String id) async {
    await _repo.deleteTeamEvent(id);
    notifyListeners();
  }

  Future<Map<String, NominationStatus>> eventAttendance(String eventId) async {
    final rows = await _repo.getEventAttendance(eventId);
    return {for (final a in rows) a.playerId: a.status};
  }

  Future<void> setEventAttendance(
      String eventId, String playerId, NominationStatus status) async {
    if (status == NominationStatus.open) {
      await _repo.deleteEventAttendance(eventId, playerId);
    } else {
      await _repo.upsertEventAttendance(EventAttendance(
        id: _uuid.v4(),
        eventId: eventId,
        playerId: playerId,
        status: status,
        updatedAt: DateTime.now(),
      ));
    }
    notifyListeners();
  }

  /// Leitet den Spielstand aus den Tor-Ereignissen ab und speichert ihn.
  Future<void> _recomputeScore(String matchId) async {
    final match = await _repo.getMatch(matchId);
    if (match == null) return;
    final counts = await _repo.goalCountByTeam(matchId);
    final own = counts[match.ownTeamId] ?? 0;
    var opp = 0;
    counts.forEach((teamId, c) {
      if (teamId != match.ownTeamId) opp += c;
    });
    await _repo.upsertMatch(match.copyWith(ownScore: own, opponentScore: opp));
    await _reload();
  }

  /// Setzt ausgewählte Teile eines Spiels zurück.
  Future<void> resetMatchParts(
    String matchId,
    String teamId, {
    bool verlauf = true,
    bool aufstellung = false,
    bool nominierung = false,
  }) async {
    if (verlauf) {
      await _repo.resetMatchEvents(matchId);
      final match = await _repo.getMatch(matchId);
      if (match != null) {
        await _repo.upsertMatch(match.copyWith(
          status: MatchStatus.scheduled,
          ownScore: 0,
          opponentScore: 0,
          // Ab jetzt selbst verwaltet – FuPa setzt das Spiel nicht wieder
          // auf „beendet" (sonst käme es sofort zurück ins Nachholen).
          locallyManaged: true,
        ));
      }
      // Cloud: Ereignisse + zugehörige Karten dieses Spiels leeren, Stand 0:0.
      if (_activeCloudTeamId != null &&
          CloudService.ready &&
          CloudService.signedIn) {
        try {
          await CloudService.deleteEventsForMatch(matchId);
          await CloudService.deleteWhere('card_entries', {'match_id': matchId});
          await CloudService.updateMatch(matchId, {
            'status': MatchStatus.scheduled.storageKey,
            'own_score': 0,
            'opponent_score': 0,
            'locally_managed': true,
          });
        } catch (_) {}
      }
    }
    if (aufstellung) await _repo.deleteLineup(matchId, teamId);
    if (nominierung) await _repo.deleteNominationsForMatch(matchId);
    await _reload();
    notifyListeners();
  }

  /// Hebt die Selbstverwaltung eines Spiels auf (z.B. nach einem Reset) und
  /// zieht das Ergebnis wieder aus FuPa – damit ein zurückgesetztes Spiel das
  /// echte FuPa-Ergebnis anzeigt. Mit FuPa-Link wird sofort nachgezogen,
  /// sonst holt es der nächste Auto-Sync des Trainer-Geräts.
  Future<void> adoptFupaResult(String matchId) async {
    final m = await _repo.getMatch(matchId);
    if (m == null) return;
    await _repo.upsertMatch(m.copyWith(locallyManaged: false));
    if (_activeCloudTeamId != null &&
        CloudService.ready &&
        CloudService.signedIn) {
      try {
        await CloudService.updateMatch(matchId, {'locally_managed': false});
      } catch (_) {}
    }
    final url = _ownTeam?.fupaUrl;
    if (url != null && url.isNotEmpty) {
      try {
        await importSchedule(url); // reconciliert jetzt das Ergebnis + pusht
        return;
      } catch (_) {}
    }
    await _reload();
    notifyListeners();
  }

  Future<void> setMatchStatus(String matchId, MatchStatus status) async {
    final match = await _repo.getMatch(matchId);
    if (match == null) return;
    await _repo.upsertMatch(match.copyWith(status: status));
    await _reload();
    notifyListeners();
    // Status (z.B. „live"/„beendet") teilen, damit das Live-Spiel bei allen
    // sichtbar ist (Menü „Live-Spiel läuft") und mitgeschrieben werden kann.
    if (_activeCloudTeamId != null &&
        CloudService.ready &&
        CloudService.signedIn) {
      try {
        await CloudService.updateMatch(
            matchId, {'status': status.storageKey});
      } catch (_) {}
    }
  }

  // ---------------------------------------------------------------- Ratings
  Future<List<PlayerRating>> ratingsOf(String matchId) =>
      _repo.getRatings(matchId);

  /// Bewertungen eines Spiels als Map spielerId -> Bewertung.
  Future<Map<String, PlayerRating>> ratingsMapOf(String matchId) async {
    final list = await _repo.getRatings(matchId);
    return {for (final r in list) r.playerId: r};
  }

  Future<void> setRating({
    required String matchId,
    required String playerId,
    required double rating,
    String? note,
    bool keepNote = true,
  }) async {
    final existing = await _repo.getRatings(matchId);
    final prior =
        existing.where((r) => r.playerId == playerId).firstOrNull;
    await _repo.upsertRating(PlayerRating(
      id: prior?.id ?? _uuid.v4(),
      matchId: matchId,
      playerId: playerId,
      rating: rating,
      note: note ?? (keepNote ? prior?.note : null),
      createdAt: prior?.createdAt ?? DateTime.now(),
    ));
    notifyListeners();
  }

  /// Entfernt die Bewertung eines Spielers für ein Spiel (falls vorhanden).
  Future<void> removeRating(String matchId, String playerId) async {
    final existing = await _repo.getRatings(matchId);
    for (final r in existing.where((r) => r.playerId == playerId)) {
      await _repo.deleteRating(r.id);
    }
    notifyListeners();
  }

  /// Bewertungen eines Spielers je Spiel (matchId -> Sterne) – fürs Nachholen
  /// und Korrigieren im Profil.
  Future<Map<String, double>> playerRatingsByMatch(String playerId) =>
      _repo.ratingsByPlayer(playerId);

  /// Vollständige Bewertungen je Spiel (inkl. Kommentar) – fürs Profil.
  Future<Map<String, PlayerRating>> playerRatingsFull(String playerId) =>
      _repo.ratingsFullByPlayer(playerId);

  /// Gesamtschnitt eines Spielers über alle Spiele: (Durchschnitt, Anzahl).
  Future<(double?, int)> ratingAverage(String playerId) =>
      _repo.ratingAverage(playerId);

  Future<Map<String, (double, int)>> ratingAveragesForTeam(String teamId) =>
      _repo.ratingAveragesForTeam(teamId);

  // --------------------------------------------------------------- Scouting
  Future<Set<ScoutMarker>> scoutMarkersOf(String playerId) async {
    final keys = await _repo.getMarkers(playerId);
    return keys.map(ScoutMarker.fromKey).whereType<ScoutMarker>().toSet();
  }

  Future<Map<String, Set<ScoutMarker>>> scoutMarkersForTeam(
      String teamId) async {
    final raw = await _repo.markersForTeam(teamId);
    return raw.map((pid, keys) => MapEntry(
        pid, keys.map(ScoutMarker.fromKey).whereType<ScoutMarker>().toSet()));
  }

  /// Kommentare je Spieler eines Teams (playerId -> neuester Text).
  Future<Map<String, String>> scoutCommentsForTeam(String teamId) =>
      _repo.commentsForTeam(teamId);

  /// Liga-Tabelle (komplett) + Platz + Form (letzte 5) des Gegners.
  Future<(StandingRow?, List<FormMatch>, List<StandingRow>)> opponentAnalysis(
      String ownTeamId, String opponentTeamId) async {
    final own = await _repo.getTeam(ownTeamId);
    final opp = await _repo.getTeam(opponentTeamId);
    final oppSlug = FupaReduxImporter.teamSlugFromUrl(opp?.fupaUrl);
    const empty = (null, <FormMatch>[], <StandingRow>[]);
    if (oppSlug == null) return empty;
    // Liga-Slug aus Einstellungen (Cache) oder aus dem eigenen Team ableiten.
    var leagueSlug = await _repo.getSetting('league_slug');
    if (leagueSlug == null || leagueSlug.isEmpty) {
      final url = own?.fupaUrl;
      if (url != null) {
        leagueSlug = await _importer.leagueSlugForTeam(url);
        if (leagueSlug != null) {
          await _repo.setSetting('league_slug', leagueSlug);
        }
      }
    }
    if (leagueSlug == null) return empty;
    var table = const <StandingRow>[];
    var form = const <FormMatch>[];
    try {
      table = await _importer.fetchStanding(leagueSlug);
    } catch (_) {}
    try {
      // Mehr Spiele laden, damit die Niederlagen der ganzen Saison vorliegen;
      // die „letzte 5"-Karte nimmt sich davon die ersten fünf.
      form = await _importer.fetchTeamForm(leagueSlug, oppSlug, limit: 50);
    } catch (_) {}
    StandingRow? standing;
    for (final r in table) {
      if (r.teamSlug == oppSlug) {
        standing = r;
        break;
      }
    }
    return (standing, form, table);
  }

  /// Komplette Liga-Tabelle + die Zeile unseres Teams (für die Statistik).
  Future<(StandingRow?, List<StandingRow>)> leagueTable(String ownTeamId) async {
    final own = await _repo.getTeam(ownTeamId);
    final ownSlug = FupaReduxImporter.teamSlugFromUrl(own?.fupaUrl);
    const empty = (null, <StandingRow>[]);
    var leagueSlug = await _repo.getSetting('league_slug');
    if (leagueSlug == null || leagueSlug.isEmpty) {
      final url = own?.fupaUrl;
      if (url != null) {
        leagueSlug = await _importer.leagueSlugForTeam(url);
        if (leagueSlug != null) {
          await _repo.setSetting('league_slug', leagueSlug);
        }
      }
    }
    if (leagueSlug == null) return empty;
    var table = const <StandingRow>[];
    try {
      table = await _importer.fetchStanding(leagueSlug);
    } catch (_) {}
    StandingRow? ours;
    if (ownSlug != null) {
      for (final r in table) {
        if (r.teamSlug == ownSlug) {
          ours = r;
          break;
        }
      }
    }
    return (ours, table);
  }

  // ---------------------------------------------------- Ball-/Materialdienst
  Future<MaterialDutyConfig> materialDutyConfig(String teamId) async {
    final s = await _repo.getSetting('material_duty_$teamId');
    return MaterialDutyConfig.decode(s);
  }

  Future<void> saveMaterialDutyConfig(
      String teamId, MaterialDutyConfig config) async {
    await _repo.setSetting('material_duty_$teamId', config.encode());
    notifyListeners();
    // Materialdienst teilen, wenn dies das aktive Cloud-Team ist.
    if (_activeCloudTeamId == teamId &&
        CloudService.ready &&
        CloudService.signedIn) {
      try {
        await CloudService.updateTeam(teamId, {'material_duty': config.encode()});
      } catch (_) {}
    }
  }

  /// Urlaube der Team-Spieler (aus den „Urlaub"-Abwesenheiten) als Zeiträume.
  Future<List<DutyVacation>> materialDutyVacations(String teamId) async {
    final abs =
        await _repo.absencesForTeam(teamId, status: PlayerStatus.urlaub);
    return abs
        .map((a) => DutyVacation(a.playerId, a.from, a.until))
        .toList();
  }

  Future<void> toggleScoutMarker(
      String playerId, ScoutMarker m, bool on) async {
    if (on) {
      await _repo.setMarker(playerId, m.storageKey);
    } else {
      await _repo.removeMarker(playerId, m.storageKey);
    }
    notifyListeners();
  }

  /// Einzelner Scouting-Kommentar (Klartext) zu einem Gegner-Spieler.
  Future<String> scoutCommentOf(String playerId) async {
    final notes = await _repo.getNotes(playerId);
    return notes.isEmpty ? '' : notes.first.text;
  }

  Future<void> setScoutComment(String playerId, String text) async {
    final existing = await _repo.getNotes(playerId);
    final t = text.trim();
    if (t.isEmpty) {
      for (final n in existing) {
        await _repo.deleteNote(n.id);
      }
    } else {
      final id = existing.isNotEmpty ? existing.first.id : _uuid.v4();
      await _repo.upsertNote(PlayerNote(
        id: id,
        playerId: playerId,
        text: t,
        createdAt:
            existing.isNotEmpty ? existing.first.createdAt : DateTime.now(),
      ));
      // Nur ein Kommentar behalten – ältere Einträge entfernen.
      for (final n in existing.skip(1)) {
        await _repo.deleteNote(n.id);
      }
    }
    notifyListeners();
  }

  /// Tore je Spieler (dedupKey „vorname|nachname" -> Tore) aus der Statistik.
  Future<Map<String, int>> scoutGoals(String teamId) async {
    final stats = await _repo.getStats(teamId);
    final map = <String, int>{};
    for (final s in stats) {
      final key =
          '${s.firstName.trim().toLowerCase()}|${s.lastName.trim().toLowerCase()}';
      map[key] = (map[key] ?? 0) + s.goals;
    }
    return map;
  }

  // --------------------------------------------------------------- Nachholen
  Future<List<Todo>> todos() => _repo.getTodos();

  Future<List<Todo>> archivedTodos() => _repo.getArchivedTodos();

  Future<void> addTodo(
    String text, {
    DateTime? dueDate,
    String? topicId,
    List<TodoResponsible> responsible = const [],
  }) async {
    final t = text.trim();
    if (t.isEmpty) return;
    await _repo.upsertTodo(Todo(
      id: _uuid.v4(),
      text: t,
      createdAt: DateTime.now(),
      dueDate: dueDate,
      topicId: topicId,
      responsible: responsible,
    ));
    notifyListeners();
  }

  /// Komplette Aufgabe speichern (z.B. nach dem Bearbeiten im Dialog).
  Future<void> saveTodo(Todo todo) async {
    await _repo.upsertTodo(todo);
    notifyListeners();
  }

  // -------------------------------------------------------- Aufgaben-Themen
  Future<List<TodoTopic>> todoTopics() => _repo.getTodoTopics();

  Future<TodoTopic> addTodoTopic(String title) async {
    final topics = await _repo.getTodoTopics();
    final topic = TodoTopic(
      id: _uuid.v4(),
      title: title.trim(),
      sortOrder: topics.length,
      createdAt: DateTime.now(),
    );
    await _repo.upsertTodoTopic(topic);
    notifyListeners();
    return topic;
  }

  Future<void> renameTodoTopic(TodoTopic topic, String title) async {
    final t = title.trim();
    if (t.isEmpty) return;
    await _repo.upsertTodoTopic(topic.copyWith(title: t));
    notifyListeners();
  }

  Future<void> deleteTodoTopic(String id) async {
    await _repo.deleteTodoTopic(id);
    notifyListeners();
  }

  // ----------------------------------------------------- Spielergespräche
  Future<List<PlayerTalk>> talks() => _repo.getTalks();

  Future<List<PlayerTalk>> talksForPlayer(String playerId) =>
      _repo.getTalksForPlayer(playerId);

  Future<void> addTalk({
    required String playerId,
    required String title,
    required DateTime scheduledAt,
    String? notes,
    bool done = false,
  }) async {
    await _repo.upsertTalk(PlayerTalk(
      id: _uuid.v4(),
      playerId: playerId,
      title: title.trim(),
      scheduledAt: scheduledAt,
      notes: notes,
      done: done,
      createdAt: DateTime.now(),
    ));
    notifyListeners();
  }

  Future<void> saveTalk(PlayerTalk talk) async {
    await _repo.upsertTalk(talk);
    notifyListeners();
  }

  Future<void> deleteTalk(String id) async {
    await _repo.deleteTalk(id);
    notifyListeners();
  }

  /// Abhaken/aufmachen – beim Abhaken wird der Zeitpunkt festgehalten.
  Future<void> toggleTodo(Todo todo, bool done) async {
    await _repo.upsertTodo(done
        ? todo.copyWith(done: true, completedAt: DateTime.now())
        : todo.copyWith(done: false, clearCompletedAt: true));
    notifyListeners();
  }

  /// Fälligkeitsdatum setzen (null entfernt es).
  Future<void> setTodoDueDate(Todo todo, DateTime? dueDate) async {
    await _repo.upsertTodo(dueDate == null
        ? todo.copyWith(clearDueDate: true)
        : todo.copyWith(dueDate: dueDate));
    notifyListeners();
  }

  Future<void> setTodoArchived(Todo todo, bool archived) async {
    await _repo.upsertTodo(todo.copyWith(archived: archived));
    notifyListeners();
  }

  Future<void> updateTodoText(Todo todo, String text) async {
    final t = text.trim();
    if (t.isEmpty) {
      await deleteTodo(todo.id);
      return;
    }
    await _repo.upsertTodo(todo.copyWith(text: t));
    notifyListeners();
  }

  Future<void> deleteTodo(String id) async {
    await _repo.deleteTodo(id);
    notifyListeners();
  }

  /// Offene Punkte (Bewertungen / Nominierung / Aufstellung) zum Nachholen.
  Future<List<NachholenItem>> nachholen() async {
    final team = _ownTeam;
    if (team == null) return [];
    final matches = await _repo.getMatches(team.id);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    // Ende der aktuellen Woche (kommender Sonntag, 23:59). Nominierung/
    // Aufstellung nur bis dahin anzeigen – nicht für weit entfernte Spiele.
    final endOfWeek = today
        .add(Duration(days: 7 - now.weekday))
        .add(const Duration(hours: 23, minutes: 59, seconds: 59));
    final items = <NachholenItem>[];
    for (final m in matches) {
      final finished = m.status == MatchStatus.finished;
      if (finished) {
        // Offene Bewertungen: eingesetzte Spieler ohne Bewertung.
        final roster = await _ratingRoster(m);
        if (roster.isNotEmpty) {
          final rated =
              (await _repo.getRatings(m.id)).map((r) => r.playerId).toSet();
          final open = roster.where((id) => !rated.contains(id)).length;
          if (open > 0) {
            items.add(NachholenItem(
              kind: NachholenKind.rating,
              matchId: m.id,
              title: 'vs ${m.opponentName}',
              detail: '$open von ${roster.length} Spielern noch zu bewerten',
              kickoff: m.kickoff,
            ));
          }
        }
      } else {
        // Nominierung/Aufstellung nur für anstehende Spiele (heute bis Ende der
        // Woche) – NICHT für vergangene (z.B. zurückgesetzte) Spiele.
        final k = m.kickoff;
        final relevant =
            k != null && !k.isBefore(today) && !k.isAfter(endOfWeek);
        if (!relevant) continue;
        final noms = await _repo.getNominations(m.id);
        if (noms.isEmpty) {
          items.add(NachholenItem(
            kind: NachholenKind.nomination,
            matchId: m.id,
            title: 'vs ${m.opponentName}',
            detail: 'Noch keine Nominierung',
            kickoff: m.kickoff,
          ));
        } else {
          final zugesagt =
              noms.where((n) => n.status == NominationStatus.zugesagt).length;
          if (zugesagt > 0) {
            final lineup = await _repo.getLineup(m.id, team.id);
            var starters = 0;
            if (lineup != null) {
              starters = (await _repo.getLineupEntries(lineup.id))
                  .where((e) => e.role == LineupRole.starter)
                  .length;
            }
            if (starters == 0) {
              items.add(NachholenItem(
                kind: NachholenKind.lineup,
                matchId: m.id,
                title: 'vs ${m.opponentName}',
                detail: 'Aufstellung fehlt',
                kickoff: m.kickoff,
              ));
            }
          }
        }
      }
    }
    return items;
  }

  Future<Set<String>> _ratingRoster(GameMatch m) =>
      playedPlayerIds(m.id, m.ownTeamId);

  /// Spieler, die im Spiel tatsächlich gespielt haben: Startelf + Eingewechselte
  /// (aus den Wechsel-Ereignissen). Ohne Aufstellung ersatzweise die Zugesagten
  /// – nur diese Spieler lassen sich für das Spiel bewerten.
  Future<Set<String>> playedPlayerIds(String matchId, String ownTeamId) async {
    final lineup = await _repo.getLineup(matchId, ownTeamId);
    if (lineup != null) {
      final played = <String>{
        for (final e in await _repo.getLineupEntries(lineup.id))
          if (e.role == LineupRole.starter) e.playerId,
      };
      for (final e in await _repo.getEvents(matchId)) {
        if (e.type == MatchEventType.substitution && e.playerId != null) {
          played.add(e.playerId!); // eingewechselt
        }
      }
      if (played.isNotEmpty) return played;
    }
    final noms = await _repo.getNominations(matchId);
    return noms
        .where((n) => n.status == NominationStatus.zugesagt)
        .map((n) => n.playerId)
        .toSet();
  }

  /// Spiele, in denen ein Spieler tatsächlich gespielt hat (für die Bewertung).
  Future<Set<String>> playedMatchIdsForPlayer(
      String playerId, String teamId) async {
    final matches = await _repo.getMatches(teamId);
    final out = <String>{};
    for (final m in matches) {
      final played = await playedPlayerIds(m.id, teamId);
      if (played.contains(playerId)) out.add(m.id);
    }
    return out;
  }

  /// Anzahl offener Nachhol-Punkte (Bewertungen/Nominierung/Aufstellung) –
  /// ohne To-Dos, die haben einen eigenen Menüpunkt.
  Future<int> nachholenCount() async => (await nachholen()).length;

  /// Anzahl offener (nicht erledigter) eigener Aufgaben – fürs Menü-Badge.
  Future<int> openTodoCount() => _repo.openTodoCount();
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}
