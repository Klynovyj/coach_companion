import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show RealtimeChannel;
import 'package:uuid/uuid.dart';

import '../data/coach_repository.dart';
import '../models/activity.dart';
import '../models/inbox_message.dart';
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
import '../models/graphic_settings.dart';
import '../models/match_rating.dart';
import '../models/player_of_month.dart';
import '../models/player_talk.dart';
import '../models/sponsor.dart';
import '../models/todo.dart';
import '../models/todo_topic.dart';
import '../services/birthday_notifications.dart';
import '../services/cloud_service.dart';
import '../services/live_clock.dart';
import '../services/push_service.dart';
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
    'sponsors',
    'graphic_settings',
    'match_ratings',
    'player_of_month',
    'activities',
    // Persönlicher Posteingang: Pull liefert dank RLS nur die eigenen Zeilen.
    'inbox',
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
    // Bewertungen sind pro Trainer: Upsert über die fachliche Eindeutigkeit,
    // damit zwei Trainer-Noten nebeneinander bestehen (nicht per id kollidieren).
    'player_ratings': 'match_id,player_id,user_id',
    'match_ratings': 'match_id,user_id',
  };

  /// Spiegelt eine Schreiboperation des Repositorys in die Cloud (best effort).
  void _onRepoWrite(
    String table,
    Map<String, Object?>? upsertRow,
    Map<String, Object?>? deleteFilter,
  ) {
    // Pulls nutzen hook-freie Roh-Methoden; jede Hook-Auslösung ist also eine
    // echte Nutzer-/App-Eingabe und MUSS gespiegelt werden (nicht blockieren).
    final team = _activeCloudTeamId;
    if (team == null || !CloudService.ready || !CloudService.signedIn) return;
    if (!_auxTableSet.contains(table)) return;
    if (upsertRow != null) {
      final row = <String, dynamic>{...upsertRow, 'team_id': team};
      CloudService.upsertRow(
        table,
        row,
        onConflict: _auxOnConflict[table],
      ).catchError((_) {});
    } else if (deleteFilter != null) {
      CloudService.deleteWhere(
        table,
        Map<String, dynamic>.from(deleteFilter),
      ).catchError((_) {});
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
  Future<void> _pullEventsFromCloud(
    String teamId, {
    required bool replace,
  }) async {
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
  Timer? _liveTimer;
  bool _autoRefreshing = false;

  /// Startet (oder behält) das Realtime-Abo + die periodische FuPa-Auffrischung
  /// für das aktive Cloud-Team.
  void ensureTeamSync(String teamId) {
    if (_syncedTeamId == teamId && _teamChannels.isNotEmpty) return;
    _stopTeamSync();
    if (!CloudService.ready || !CloudService.signedIn) return;
    _syncedTeamId = teamId;
    _teamChannels = CloudService.subscribeTeam(teamId, _onRemoteRowChange);
    // Eigene Live-Rolle (Mitschreiben vs. Zuschauer) bestimmen.
    refreshLiveRole();
    // FCM-Token registrieren (jetzt sicher angemeldet).
    PushService.registerToken();
    // Einmaliger Voll-Abgleich beim Start (fängt verpasste Änderungen).
    _refreshActiveTeamFromCloud(teamId);
    // FuPa (Spielplan/Ergebnisse) regelmäßig automatisch auffrischen.
    _fupaTimer = Timer.periodic(
      const Duration(minutes: 30),
      (_) => maybeAutoRefreshFupa(),
    );
    // Voll-Import (Kader, Fotos, Logos, Statistik) seltener.
    _fullTimer = Timer.periodic(
      const Duration(hours: 6),
      (_) => maybeAutoFullRefresh(),
    );
    maybeAutoFullRefresh();
    maybeAutoRefreshFupa();
    // Status/Ergebnis (live gehen, Abpfiff, zurücksetzen) zuverlässig abgleichen
    // – auch falls ein Realtime-Event verloren geht (z.B. Hintergrund/Android).
    _liveTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _pollMatchSync(),
    );
    _pollMatchSync();
  }

  /// Gleicht Status + Ergebnis aller Spiele mit der Cloud ab (leichtgewichtig).
  /// Fängt verlorene Realtime-Events: Live-Spiel/Abpfiff/Zurücksetzen erscheinen
  /// so bei allen. Beim Wechsel auf „live" kommt eine Info-Benachrichtigung.
  Future<void> _pollMatchSync() async {
    final teamId = _activeCloudTeamId;
    if (teamId == null || !CloudService.ready || !CloudService.signedIn) return;
    try {
      final rows = await CloudService.matchSyncRows(teamId);
      var changed = false;
      for (final r in rows) {
        final id = r['id'] as String?;
        if (id == null) continue;
        final local = await _repo.getMatch(id);
        if (local == null) continue;
        final st = MatchStatus.fromKey(r['status'] as String?);
        final own = (r['own_score'] as num?)?.toInt() ?? local.ownScore;
        final opp =
            (r['opponent_score'] as num?)?.toInt() ?? local.opponentScore;
        final ctrl = r['live_controller'] as String?;
        final ctrlName = r['live_controller_name'] as String?;
        final ctrlChanged = (local.liveController ?? '') != (ctrl ?? '');
        if (local.status == st &&
            local.ownScore == own &&
            local.opponentScore == opp &&
            !ctrlChanged) {
          continue;
        }
        if (st == MatchStatus.live && local.status != MatchStatus.live) {
          final name = (r['opponent'] as String?) ?? local.opponentName;
          LiveClock.showInfo('Live-Spiel läuft', 'vs $name');
        }
        await _repo.upsertMatch(
          local.copyWith(
            status: st,
            ownScore: own,
            opponentScore: opp,
            liveController: ctrl,
            liveControllerName: ctrlName,
            clearController: ctrl == null,
          ),
        );
        // Reset eines anderen Geräts (→ „angesetzt"): lokalen Verlauf leeren,
        // damit die Live-Uhr/Ticker auch ohne Realtime-DELETE zurückgehen.
        if (st == MatchStatus.scheduled &&
            local.status != MatchStatus.scheduled) {
          await _repo.resetMatchEvents(id);
        }
        changed = true;
      }
      if (changed) {
        await _reload();
        notifyListeners();
      }
    } catch (_) {
      // Offline/Teilfehler – nächster Tick versucht es erneut.
    }
  }

  /// Darf der aktuelle Nutzer im Live-Spiel mitschreiben? Ohne aktives Cloud-
  /// Team (rein lokal) immer true; mit Cloud-Team nur Trainer/Admin oder
  /// Ticker-berechtigte Spieler. Zuschauer sehen den Ticker nur.
  bool _canLiveEdit = true;
  bool get canLiveEdit => _canLiveEdit;

  /// Rolle im aktiven Cloud-Team: true = Trainer/Admin (voller Zugriff), false =
  /// Spieler (nur Ansicht). Ohne aktives Cloud-Team (rein lokal) immer true.
  bool _isTrainerHere = true;
  bool get isTrainerHere => _isTrainerHere;

  /// Die mit dem eigenen Konto verknüpften Spieler-IDs im aktiven Cloud-Team
  /// (für die Spieler-Sicht, z.B. eigene Gespräche). Leer bei Trainer/lokal.
  List<String> _myPlayerIds = const [];
  List<String> get myPlayerIds => List.unmodifiable(_myPlayerIds);

  Future<void> refreshLiveRole() async {
    final teamId = _activeCloudTeamId;
    if (teamId == null || !CloudService.ready || !CloudService.signedIn) {
      if (!_canLiveEdit || !_isTrainerHere || _myPlayerIds.isNotEmpty) {
        _canLiveEdit = true;
        _isTrainerHere = true;
        _myPlayerIds = const [];
        notifyListeners();
      }
      return;
    }
    try {
      final teams = await CloudService.myTeams();
      final mine = teams.firstWhere(
        (t) => t['id'] == teamId,
        orElse: () => <String, dynamic>{},
      );
      final isAdmin = mine['created_by'] == CloudService.user?.id;
      final isTrainer = mine['role'] == 'trainer' || isAdmin;
      final canEdit = isTrainer || mine['can_ticker'] == true;
      // Eigene Spieler-Zuordnung nur für Spieler laden (Trainer sehen alles).
      List<String> myPlayers = const [];
      if (!isTrainer) {
        try {
          myPlayers = await CloudService.myPlayerIds(teamId);
        } catch (_) {}
      }
      final changed =
          canEdit != _canLiveEdit ||
          isTrainer != _isTrainerHere ||
          !_sameIds(myPlayers, _myPlayerIds);
      _canLiveEdit = canEdit;
      _isTrainerHere = isTrainer;
      _myPlayerIds = myPlayers;
      if (changed) notifyListeners();
    } catch (_) {
      // Bei Fehler Rechte nicht entziehen.
    }
  }

  bool _sameIds(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _stopTeamSync() {
    final chs = _teamChannels;
    _teamChannels = [];
    _syncedTeamId = null;
    _fupaTimer?.cancel();
    _fupaTimer = null;
    _fullTimer?.cancel();
    _fullTimer = null;
    _liveTimer?.cancel();
    _liveTimer = null;
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
        'last_fupa_autosync',
        DateTime.now().toIso8601String(),
      );
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
  Future<ConnectSummary?> refreshFromFupaNow({
    String? url,
    void Function(String)? onProgress,
  }) async {
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
    String table,
    String eventType,
    Map<String, dynamic> record,
  ) {
    _applyQueue = _applyQueue
        .then((_) => _applyRemoteChange(table, eventType, record))
        .catchError((_) {});
  }

  Future<void> _applyRemoteChange(
    String table,
    String eventType,
    Map<String, dynamic> record,
  ) async {
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
            // Cloud = geteilte Wahrheit: Status (live/beendet), Ergebnis und
            // „zurückgesetzt" anderer Trainer immer übernehmen, damit ein
            // laufendes Spiel bei allen erscheint. FuPa-Schutz sitzt separat
            // in syncSchedule (locallyManaged wird dort geprüft).
            await _applyCloudMatch(record, teamId, now);
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
    Map<String, dynamic> r,
    String teamId,
    DateTime now,
  ) async {
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
        // Cloud = geteilte Wahrheit (Status/Ergebnis/zurückgesetzt). So sieht
        // ein zuschauendes Gerät ein laufendes Spiel auch nach dem Aktivieren.
        await _applyCloudMatch(m, teamId, now);
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
  Future<void> _applyCloudTeamRow(Map<String, dynamic> t, String teamId) async {
    final existing = await _repo.getTeam(teamId);
    if (existing != null) {
      final name = t['name'] as String?;
      final shortName = t['short_name'] as String?;
      final logo = t['logo'] as String?;
      await _repo.upsertTeam(
        existing.copyWith(
          name: (name == null || name.isEmpty) ? existing.name : name,
          shortName: (shortName == null || shortName.isEmpty)
              ? null
              : shortName,
          logoPath: (logo == null || logo.isEmpty) ? null : logo,
        ),
      );
    }
    // Ball-/Materialdienst-Konfiguration (JSON) lokal spiegeln.
    if (t.containsKey('material_duty')) {
      final md = t['material_duty'] as String?;
      await _repo.setSetting(
        'material_duty_$teamId',
        (md == null || md.isEmpty) ? null : md,
      );
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
          ),
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
          },
      ]);
      await CloudService.updateMatch(matchId, {'opponent_team_id': oppId});
    } catch (_) {
      // Offline/keine Rechte – lokaler Stand bleibt gültig.
    }
  }

  /// Einmalige Bereinigung: entfernt doppelte Gegnerspieler-Zeilen (gleicher
  /// Name) und spiegelt den bereinigten Kader in die Cloud (ersetzend). Behält
  /// je Spieler die FuPa-verlinkte/vollständigere Zeile. Gibt die Anzahl
  /// entfernter Zeilen zurück. Doppelte Gegnerkader entstanden früher über
  /// Cloud/mehrere Geräte (eine Zeile mit, eine ohne FuPa-ID).
  Future<int> cleanupDuplicateOpponents() async {
    final teams = await _repo.getTeams();
    final cloudTeam = _activeCloudTeamId;
    final canPush =
        cloudTeam != null && CloudService.ready && CloudService.signedIn;
    var removed = 0;
    for (final t in teams.where((t) => !t.isOwnTeam)) {
      final players = await _repo.getPlayers(t.id);
      final deduped = dedupePlayersByName(players);
      if (deduped.length == players.length) continue;
      final keep = {for (final p in deduped) p.id};
      for (final p in players) {
        if (!keep.contains(p.id)) {
          await _repo.deletePlayer(p.id);
          removed++;
        }
      }
      if (canPush) {
        try {
          await CloudService.uploadOpponentPlayers(cloudTeam, t.id, [
            for (final p in deduped)
              {
                'id': p.id,
                'first_name': p.firstName,
                'last_name': p.lastName,
                'number': p.number,
                'position': p.position,
                'photo': p.photoPath,
              },
          ]);
        } catch (_) {
          // Offline/keine Rechte – lokale Bereinigung bleibt gültig.
        }
      }
    }
    if (removed > 0) notifyListeners();
    return removed;
  }

  /// Selbstheilende Bereinigung doppelter EIGENER Spieler-/Trainer-Zeilen:
  /// gleiche Person zweimal (eine mit FuPa-`external_id`, eine ohne – entstanden
  /// über Cloud/mehrere Geräte, da Cloud-Zeilen nur über die id gematcht
  /// werden). Behält je Name die FuPa-verlinkte/vollständigere Zeile und löscht
  /// die Klone lokal UND in der Cloud. Räumt nur dort auf, wo eine FuPa-Zeile
  /// existiert (sonst könnten zwei echte Gleichnamige fälschlich wegfallen).
  /// Gibt die Anzahl entfernter Zeilen zurück; bei sauberen Daten ein No-op.
  Future<int> cleanupDuplicateOwnPlayers() async {
    final own = await _repo.getOwnTeam();
    if (own == null) return 0;
    final players = await _repo.getPlayers(own.id);
    final deduped = dedupePlayersByName(players);
    if (deduped.length == players.length) return 0;
    final keep = {for (final p in deduped) p.id};
    // Nur Namen bereinigen, deren behaltene Zeile eine FuPa-ID hat – so werden
    // ausschließlich die Nicht-FuPa-Klone entfernt, nie zwei echte Gleichnamige.
    final safeNames = {
      for (final p in deduped)
        if (p.externalId != null && p.externalId!.isNotEmpty) p.dedupKey,
    };
    final canPush =
        _activeCloudTeamId != null &&
        CloudService.ready &&
        CloudService.signedIn;
    var removed = 0;
    for (final p in players) {
      if (keep.contains(p.id)) continue;
      // Mehrdeutig (keine FuPa-Zeile im Namen) → stehen lassen.
      if (!safeNames.contains(p.dedupKey)) continue;
      await _repo.deletePlayer(p.id);
      removed++;
      if (canPush) {
        try {
          await CloudService.deleteWhere('players', {'id': p.id});
        } catch (_) {
          // Offline/keine Rechte – lokale Bereinigung bleibt gültig.
        }
      }
    }
    if (removed > 0) notifyListeners();
    return removed;
  }

  /// Lädt geteilte Gegner-Teams + -Kader aus der Cloud in den lokalen Cache.
  /// Muss VOR den Spielen laufen (matches.opponent_team_id → teams-FK).
  Future<void> _pullOpponentsFromCloud(String teamId) async {
    if (!CloudService.ready || !CloudService.signedIn) return;
    final now = DateTime.now();
    try {
      final teams = await CloudService.fetchForTeam('opponent_teams', teamId);
      for (final t in teams) {
        final id = t['id'] as String?;
        if (id == null) continue;
        // Lokale Werte (v.a. FuPa-Link für die Gegner-Statistik) NICHT mit
        // null überschreiben, wenn die Cloud-Zeile sie (noch) nicht hat.
        final existing = await _repo.getTeam(id);
        final cloudFupa = t['fupa_url'] as String?;
        final cloudLogo = t['logo'] as String?;
        final cloudShort = t['short_name'] as String?;
        await _repo.upsertRawById('teams', {
          'id': id,
          'name': (t['name'] as String?) ?? existing?.name ?? 'Gegner',
          'short_name': (cloudShort != null && cloudShort.isNotEmpty)
              ? cloudShort
              : existing?.shortName,
          'fupa_url': (cloudFupa != null && cloudFupa.isNotEmpty)
              ? cloudFupa
              : existing?.fupaUrl,
          'logo_path': (cloudLogo != null && cloudLogo.isNotEmpty)
              ? cloudLogo
              : existing?.logoPath,
          'is_own_team': 0,
          'source': DataSource.fupaApproved.storageKey,
          'created_at': now.toIso8601String(),
        });
      }
      final players = await CloudService.fetchForTeam(
        'opponent_players',
        teamId,
      );
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

  late final OpponentSyncService opponentSync = OpponentSyncService(
    repository: _repo,
    importer: _importer,
  );

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
    // Geburtstags-Benachrichtigungen (neu) planen.
    unawaited(rescheduleBirthdayNotifications());
    // Doppelte Gegnerspieler bereinigen (selbstheilend, bei sauberen Daten
    // ein No-op). Räumt lokale Altlasten weg und spiegelt sie in die Cloud.
    unawaited(cleanupDuplicateOpponents());
    unawaited(cleanupDuplicateOwnPlayers());
    // Eigene Bewertungen erneut in die Cloud spiegeln (damit beide Trainer-
    // Noten nach Cloud-Stufe 24 zusammenlaufen) + lokale Null-Zeilen entfernen.
    unawaited(_resyncMyRatingsToCloud());
  }

  Future<void> _reload() async {
    _ownTeam = await _repo.getOwnTeam();
    _matches = _ownTeam == null ? [] : await _repo.getMatches(_ownTeam!.id);
  }

  Future<void> refresh() async {
    await _reload();
    notifyListeners();
  }

  /// Plant lokale Geburtstags-Benachrichtigungen (8:00 am Geburtstag) für alle
  /// aktiven Spieler + Betreuer mit Geburtsdatum neu. Best effort, nur Android.
  Future<void> rescheduleBirthdayNotifications() async {
    final team = _ownTeam;
    if (team == null) return;
    try {
      final people = (await _repo.getPlayers(
        team.id,
      )).where((p) => p.active && p.birthdate != null).toList();
      await BirthdayNotifications.reschedule(people);
    } catch (e) {
      debugPrint('Geburtstage neu planen: $e');
    }
  }

  @override
  void dispose() {
    _stopTeamSync();
    super.dispose();
  }

  // ----------------------------------------------------------- FuPa-Import
  /// Verbindet das eigene Team über einen FuPa-Teamlink und lädt alles:
  /// Vereinsdaten + Logo, Kader + Fotos, Spielplan + Ergebnisse, Statistik.
  Future<ConnectSummary> connectOwnTeam(
    String url, {
    void Function(String)? onProgress,
  }) async {
    onProgress?.call('Mannschaft & Kader werden geladen …');
    final teamImport = await _importer.importTeam(url);
    final team = await _persist.saveOwnTeam(url, teamImport);

    onProgress?.call('Spielerfotos werden geladen …');
    final playerData = await _importer.toPlayerDataWithPhotos(
      teamImport.players,
    );
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
    // Kader kann sich geändert haben → Geburtstage neu planen.
    unawaited(rescheduleBirthdayNotifications());
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
    await _repo.upsertTeam(
      Team(
        id: cloudTeamId,
        name: name,
        shortName: (shortName == null || shortName.isEmpty) ? null : shortName,
        isOwnTeam: true,
        source: DataSource.fupaApproved,
        fupaUrl: (fupaUrl == null || fupaUrl.isEmpty) ? null : fupaUrl,
        logoPath: (logoPath == null || logoPath.isEmpty) ? null : logoPath,
        createdAt: now,
      ),
    );
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
    // Geburtstage des neu geladenen Kaders planen.
    unawaited(rescheduleBirthdayNotifications());
  }

  /// Aktualisiert den lokalen Cache mit frischen Cloud-Spielen – ohne Wipe,
  /// nur ergänzend/überschreibend (für Realtime-Auto-Sync). Wirkt nur, wenn
  /// dieses Team das aktive Cloud-Team ist.
  Future<void> syncCloudMatchesToCache(
    String cloudTeamId,
    List<Map<String, dynamic>> matches,
  ) async {
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
    String cloudTeamId,
    List<Map<String, dynamic>> players,
  ) async {
    if (_activeCloudTeamId != cloudTeamId) return;
    final now = DateTime.now();
    for (final p in players) {
      await _applyCloudPlayer(p, cloudTeamId, now);
    }
    notifyListeners();
  }

  /// Altbestand aus der Cloud: Torwart-Position „Tor" → „Torwart".
  static String? _normPos(String? p) => p == 'Tor' ? 'Torwart' : p;

  Player _playerFromCloud(
    Map<String, dynamic> p,
    String teamId,
    DateTime now,
  ) => Player(
    id: p['id'] as String,
    teamId: teamId,
    firstName: (p['first_name'] as String?) ?? '',
    lastName: (p['last_name'] as String?) ?? '',
    number: (p['number'] as num?)?.toInt(),
    position: _normPos(p['position'] as String?),
    fupaPhoto: p['photo_fupa'] as String?,
    // Abwärtskompat: Altschema ohne neue Spalten → aktives Foto als eigenes.
    customPhoto: (p['photo_custom'] as String?) ?? (p['photo'] as String?),
    useCustomPhoto: (p['use_custom_photo'] as num?)?.toInt() != 0,
    birthdate: DateTime.tryParse((p['birthdate'] as String?) ?? ''),
    status: PlayerStatus.fromKey(p['status'] as String?),
    baseStatus: p['base_status'] != null
        ? PlayerStatus.fromKey(p['base_status'] as String?)
        : (PlayerStatus.fromKey(p['status'] as String?) == PlayerStatus.inaktiv
              ? PlayerStatus.inaktiv
              : PlayerStatus.fit),
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
    suspendedGames: (p['suspended_games'] as num?)?.toInt() ?? 0,
    suspensionCompetition: p['suspension_competition'] as String?,
    suspensionFrom: DateTime.tryParse(p['suspension_from'] as String? ?? ''),
    // Herkunft aus der Cloud übernehmen; Altzeilen ohne Spalte = FuPa.
    source: p['source'] != null
        ? DataSource.fromKey(p['source'] as String?)
        : DataSource.fupaApproved,
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
    // Aktives Foto (Abwärtskompat) + beide Slots + Auswahl.
    'photo': p.photoPath,
    'photo_fupa': p.fupaPhoto,
    'photo_custom': p.customPhoto,
    'use_custom_photo': p.useCustomPhoto ? 1 : 0,
    'birthdate': p.birthdate?.toIso8601String(),
    'status': p.status.storageKey,
    'base_status': p.baseStatus.storageKey,
    'active': p.active,
    'captain_role': p.captainRole.storageKey,
    'nickname': p.nickname,
    'positions': p.positions.join(','),
    'wish_position': p.wishPosition,
    'staff_role': p.staffRole,
    'suspended_games': p.suspendedGames,
    'suspension_competition': p.suspensionCompetition,
    'suspension_from': p.suspensionFrom?.toIso8601String(),
    'source': p.source.storageKey,
  };

  /// true, wenn die Cloud-Zeile die Zwei-Foto-Spalten hat (stage30). Ohne diese
  /// Spalten (Altschema) werden die Fotos beim Pull NICHT angetastet.
  bool _hasPhotoCols(Map<String, dynamic> r) =>
      r.containsKey('photo_fupa') || r.containsKey('photo_custom');

  /// Übernimmt einen Cloud-Spieler in den lokalen Cache. Felder werden nur
  /// übernommen, wenn die Cloud sie liefert (null = lokalen Wert behalten) –
  /// so clobbern alte Zeilen ohne diese Spalten nichts.
  Future<void> _applyCloudPlayer(
    Map<String, dynamic> record,
    String teamId,
    DateTime now,
  ) async {
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
    await _repo.upsertPlayer(
      existing.copyWith(
        firstName: record['first_name'] as String?,
        lastName: record['last_name'] as String?,
        number: (record['number'] as num?)?.toInt(),
        position: _normPos(record['position'] as String?),
        // Fotos: neue Spalten spiegeln (null = löschen); Altschema ohne die
        // Spalten lässt das eigene Foto unangetastet (kein Datenverlust).
        fupaPhoto: _hasPhotoCols(record)
            ? record['photo_fupa'] as String?
            : null,
        clearFupaPhoto: _hasPhotoCols(record) && record['photo_fupa'] == null,
        customPhoto: _hasPhotoCols(record)
            ? record['photo_custom'] as String?
            : record['photo'] as String?,
        clearCustomPhoto:
            _hasPhotoCols(record) && record['photo_custom'] == null,
        useCustomPhoto: record['use_custom_photo'] == null
            ? null
            : (record['use_custom_photo'] as num).toInt() != 0,
        birthdate: DateTime.tryParse((record['birthdate'] as String?) ?? ''),
        status: statusRaw == null ? null : PlayerStatus.fromKey(statusRaw),
        baseStatus: record['base_status'] == null
            ? null
            : PlayerStatus.fromKey(record['base_status'] as String?),
        captainRole: captainRaw == null
            ? null
            : CaptainRole.fromKey(captainRaw),
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
        suspendedGames: (record['suspended_games'] as num?)?.toInt(),
        suspensionCompetition: record['suspension_competition'] as String?,
        clearSuspensionCompetition:
            record.containsKey('suspension_competition') &&
            record['suspension_competition'] == null,
        suspensionFrom: DateTime.tryParse(
          record['suspension_from'] as String? ?? '',
        ),
        clearSuspensionFrom:
            record.containsKey('suspension_from') &&
            record['suspension_from'] == null,
        source: record['source'] != null
            ? DataSource.fromKey(record['source'] as String?)
            : null,
      ),
    );
  }

  GameMatch _matchFromCloud(
    Map<String, dynamic> m,
    String teamId,
    DateTime now,
  ) {
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
      kickoff: kickoffStr == null
          ? null
          : DateTime.tryParse(kickoffStr)?.toLocal(),
      venue: (m['venue'] == 'Auswärts') ? Venue.away : Venue.home,
      ownScore: (m['own_score'] as num?)?.toInt() ?? 0,
      opponentScore: (m['opponent_score'] as num?)?.toInt() ?? 0,
      status: MatchStatus.fromKey(m['status'] as String?),
      locallyManaged: m['locally_managed'] == true,
      liveController: m['live_controller'] as String?,
      liveControllerName: m['live_controller_name'] as String?,
      fupaMatchSlug: m['fupa_match_slug'] as String?,
      createdAt: now,
    );
  }

  /// Übernimmt ein Cloud-Spiel in den lokalen Cache, ohne die Gegner-
  /// Anreicherung (Logo, Team-Verknüpfung, FuPa-Link) mit null zu überschreiben
  /// – ein reines Status-/Ergebnis-Update aus der Cloud trägt diese meist nicht
  /// mit, sonst „verschwindet" z.B. das Gegner-Logo.
  Future<void> _applyCloudMatch(
    Map<String, dynamic> record,
    String teamId,
    DateTime now,
  ) async {
    final cm = _matchFromCloud(record, teamId, now);
    final existing = await _repo.getMatch(cm.id);
    // Wechsel auf „live" (von einem anderen Gerät) → Info-Benachrichtigung.
    if (cm.status == MatchStatus.live &&
        (existing == null || existing.status != MatchStatus.live)) {
      LiveClock.showInfo('Live-Spiel läuft', 'vs ${cm.opponentName}');
    }
    if (existing == null) {
      await _repo.upsertRawById('matches', cm.toMap());
      return;
    }
    final oppTeamId = cm.opponentTeamId ?? existing.opponentTeamId;
    final merged = cm.copyWith(
      opponentLogoPath: cm.opponentLogoPath ?? existing.opponentLogoPath,
      opponentTeamId: oppTeamId,
      opponentFupaUrl: cm.opponentFupaUrl ?? existing.opponentFupaUrl,
      opponentImported: oppTeamId != null,
      // FuPa-Metadaten liegen nicht in der Cloud-matches-Zeile und wären in cm
      // null – lokal bewahren, sonst gehen Spieltag/Wettbewerb und v.a. die
      // external_id (FuPa-Zuordnung beim nächsten Spielplan-Sync) verloren.
      competition: cm.competition ?? existing.competition,
      matchday: cm.matchday ?? existing.matchday,
      externalId: cm.externalId ?? existing.externalId,
      fupaMatchSlug: cm.fupaMatchSlug ?? existing.fupaMatchSlug,
    );
    await _repo.upsertRawById('matches', merged.toMap());
    // Zurücksetzen auf einem anderen Gerät (Status wechselt live/beendet →
    // „angesetzt"): lokalen Verlauf (Ereignisse + Karten) sofort leeren, damit
    // Ticker und Live-Uhr bei allen zurückgehen – nicht nur auf die
    // unzuverlässigen Realtime-DELETEs angewiesen.
    if (cm.status == MatchStatus.scheduled &&
        existing.status != MatchStatus.scheduled) {
      await _repo.resetMatchEvents(cm.id);
    }
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
          _playerCloudMap(p),
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
            'fupa_match_slug': m.fupaMatchSlug,
          },
      ];
      await CloudService.upsertMatches(matchRows);
      // Eigenes Logo + Name + FuPa-Link am Cloud-Team aktualisieren.
      await CloudService.updateTeam(cloudTeam, {
        'name': team.name,
        'short_name': team.shortName,
        'logo': team.logoPath,
        if (team.fupaUrl != null && team.fupaUrl!.isNotEmpty)
          'fupa_url': team.fupaUrl,
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
          },
      ]);
    } catch (_) {
      // Offline / keine Trainer-Rechte – lokaler Stand bleibt gültig.
    }
  }

  /// Lädt alles für das bereits verbundene Team erneut.
  Future<ConnectSummary> resyncOwnTeam({
    void Function(String)? onProgress,
  }) async {
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
      final day =
          m.kickoff?.toIso8601String().substring(0, 10) ?? m.externalId ?? '';
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
    var url = team?.fupaUrl;
    // Fehlt der Link am Gegner-Team (z.B. durch Sync verloren), aus einem Spiel
    // dieses Gegners nachziehen und wieder am Team hinterlegen.
    if (url == null || url.isEmpty) {
      for (final m in _matches) {
        if (m.opponentTeamId == teamId &&
            m.opponentFupaUrl != null &&
            m.opponentFupaUrl!.isNotEmpty) {
          url = m.opponentFupaUrl;
          break;
        }
      }
      if (url != null && url.isNotEmpty && team != null) {
        await _repo.upsertTeam(team.copyWith(fupaUrl: url));
      }
    }
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
        .map(
          (d) => PlayerStat(
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
          ),
        )
        .toList();
    await _repo.replaceStats(teamId, stats);
    return stats.length;
  }

  Future<List<PlayerStat>> statsOf(String teamId) => _repo.getStats(teamId);

  /// Lädt die eigene FuPa-Saisonstatistik bei Bedarf nach (nur Gerät mit
  /// FuPa-Link) und spiegelt sie in die Cloud – ohne auf den 6h-Voll-Import zu
  /// warten. No-op, wenn schon Statistik vorhanden ist oder kein Link existiert.
  Future<void> ensureOwnStats(String teamId) async {
    final existing = await _repo.getStats(teamId);
    if (existing.isNotEmpty) return;
    final url = _ownTeam?.fupaUrl ?? (await _repo.getTeam(teamId))?.fupaUrl;
    if (url == null || url.isEmpty) return;
    try {
      final n = await _importStatsInto(teamId, url);
      if (n > 0) await _pushStatsToCloud(teamId);
      notifyListeners();
    } catch (_) {
      // Statistik ist optional.
    }
  }

  /// Spiegelt die lokale Statistik eines Teams in die Cloud (nur aktives Team).
  Future<void> _pushStatsToCloud(String teamId) async {
    if (_activeCloudTeamId != teamId ||
        !CloudService.ready ||
        !CloudService.signedIn) {
      return;
    }
    final stats = await _repo.getStats(teamId);
    try {
      await CloudService.uploadStats(teamId, [
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
          },
      ]);
    } catch (_) {}
  }

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

  Future<void> renameTeam(
    String teamId,
    String name, {
    String? shortName,
  }) async {
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
        await CloudService.updateTeam(teamId, {
          'name': name,
          'short_name': shortName,
        });
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
    await _repo.upsertTeam(
      t.copyWith(
        name: (name != null && name.isNotEmpty) ? name : null,
        shortName: (shortName != null && shortName.isNotEmpty)
            ? shortName
            : null,
        logoPath: (logoPath != null && logoPath.isNotEmpty) ? logoPath : null,
      ),
    );
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

  /// Kader-Status-Übersicht: je Feldspieler Status + (bei befristeter
  /// Abwesenheit) das „bis"-Datum und ein optionaler Grund. Für die
  /// Status-Ansicht in der Statistik.
  Future<List<PlayerStatusInfo>> squadStatus(String teamId) async {
    final players = (await _repo.getPlayers(
      teamId,
    )).where((p) => !p.isStaffOnly).toList();
    final out = <PlayerStatusInfo>[];
    for (final p in players) {
      DateTime? until;
      String? note;
      if (p.status.isAbsence) {
        final abs = await _repo.getAbsences(p.id);
        for (final a in abs) {
          if (a.status == p.status) {
            until = a.until;
            note = a.note;
            break;
          }
        }
      }
      out.add(PlayerStatusInfo(player: p, until: until, note: note));
    }
    return out;
  }

  /// Legt eine Abwesenheit an (Zeitraum + Grund) und setzt den Spielerstatus.
  Future<void> addAbsence({
    required Player player,
    required PlayerStatus status,
    required DateTime from,
    required DateTime until,
    String? note,
  }) async {
    await _repo.upsertAbsence(
      PlayerAbsence(
        id: _uuid.v4(),
        playerId: player.id,
        status: status,
        from: from,
        until: until,
        note: note,
        createdAt: DateTime.now(),
      ),
    );
    // Status aus den Abwesenheiten ableiten (laufende ODER bevorstehende
    // Abwesenheit → Status wird gesetzt; abgelaufene zählen nicht).
    await _syncStatusFromAbsences(player.id);
    await logActivity(
      ActivityType.status,
      '${player.fullName}: ${status.label}',
    );
  }

  /// Abwesenheit geändert (z.B. Zeitraum verlängert): Status des Spielers
  /// automatisch an das aktuelle Datum anpassen.
  Future<void> updateAbsence(PlayerAbsence a) async {
    await _repo.upsertAbsence(a);
    await _syncStatusFromAbsences(a.playerId);
    notifyListeners();
  }

  Future<void> deleteAbsence(PlayerAbsence a) async {
    await _repo.deleteAbsence(a.id);
    await _syncStatusFromAbsences(a.playerId);
    notifyListeners();
  }

  /// Einzelnen Spieler neu laden (z.B. um den Status nach einer Abwesenheits-
  /// Änderung aktuell anzuzeigen).
  Future<Player?> playerById(String id) => _repo.getPlayer(id);

  /// Setzt den Spielerstatus passend zu seinen Abwesenheiten und dem heutigen
  /// Datum. Eine Abwesenheit gilt als aktiv, solange ihr Enddatum NICHT vor
  /// heute liegt (laufend ODER noch bevorstehend) → deren Status wird angezeigt.
  /// Eine heute laufende Abwesenheit hat Vorrang, sonst die mit spätestem Ende.
  /// Ist keine Abwesenheit mehr aktiv und der Spieler hatte einen Abwesenheits-
  /// Status → zurück auf „Fit". „Fit"/„inaktiv" ohne aktive Abwesenheit bleiben
  /// unverändert (inaktiv ist keine Abwesenheit).
  Future<void> _syncStatusFromAbsences(String playerId) async {
    final p = await _repo.getPlayer(playerId);
    if (p == null) return;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final abs = await _repo.getAbsences(playerId);
    PlayerAbsence? best;
    bool bestCovers = false;
    for (final a in abs) {
      final from = DateTime(a.from.year, a.from.month, a.from.day);
      final until = DateTime(a.until.year, a.until.month, a.until.day);
      if (until.isBefore(today)) continue; // vorbei → zählt nicht
      final covers = !today.isBefore(from) && !today.isAfter(until);
      if (best == null) {
        best = a;
        bestCovers = covers;
      } else if (covers && !bestCovers) {
        best = a;
        bestCovers = true;
      } else if (covers == bestCovers && a.until.isAfter(best.until)) {
        best = a;
      }
    }
    // Effektiver Status = aktive Abwesenheit (Grund), sonst der Grundstatus
    // (Fit/Inaktiv). So überlagert eine Abwesenheit nur zeitweise.
    final target = best?.status ?? p.baseStatus;
    if (target != p.status) {
      await updatePlayer(p.copyWith(status: target));
    }
  }

  /// Setzt den Grundstatus (nur Fit/Inaktiv) und berechnet den effektiven Status
  /// neu (eine laufende Abwesenheit bleibt davon unberührt sichtbar).
  Future<void> setBaseStatus(Player player, PlayerStatus base) async {
    await updatePlayer(player.copyWith(baseStatus: base));
    await _syncStatusFromAbsences(player.id);
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

  // ---------------------------------------------------- Karten & Sperren
  /// Karten-Übersicht je Feldspieler: FuPa-Saisonkarten + eigene erfasste
  /// Karten. Für die „Karten & Sperren"-Ansicht. Gesperrte zuerst, dann nach
  /// FuPa-Gelben absteigend.
  Future<List<PlayerCardSummary>> cardSummaries(String teamId) async {
    await ensureOwnStats(teamId);
    // Nur aktive Feldspieler – inaktive/abgemeldete erscheinen hier nicht.
    final players = (await _repo.getPlayers(
      teamId,
    )).where((p) => !p.isStaffOnly && p.active).toList();
    final stats = await _repo.getStats(teamId);
    final byKey = <String, PlayerStat>{
      for (final s in stats)
        '${s.firstName.trim().toLowerCase()}|${s.lastName.trim().toLowerCase()}':
            s,
    };
    final out = <PlayerCardSummary>[];
    for (final p in players) {
      final stat = byKey[p.dedupKey];
      final cards = await _repo.getCards(p.id);
      int own(CardType t) => cards.where((c) => c.type == t).length;
      out.add(
        PlayerCardSummary(
          player: p,
          fupaYellow: stat?.yellowCards ?? 0,
          fupaYellowRed: stat?.yellowRedCards ?? 0,
          fupaRed: stat?.redCards ?? 0,
          ownYellow: own(CardType.yellow),
          ownYellowRed: own(CardType.yellowRed),
          ownRed: own(CardType.red),
        ),
      );
    }
    // Gefährdung zuerst: gesperrt → Sperre fällig → gefährdet (ab 3 Gelben) →
    // Rest; innerhalb desselben Rangs nach Gelben, dann Name.
    int rank(PlayerCardSummary s) {
      if (s.player.suspendedGames > 0) return 3;
      if (s.yellowBanDue) return 2;
      if (s.yellowWarn) return 1;
      return 0;
    }

    out.sort((a, b) {
      final ra = rank(a), rb = rank(b);
      if (ra != rb) return rb - ra;
      if (a.fupaYellow != b.fupaYellow) {
        return b.fupaYellow.compareTo(a.fupaYellow);
      }
      return a.player.fullName.toLowerCase().compareTo(
        b.player.fullName.toLowerCase(),
      );
    });
    return out;
  }

  /// Setzt/ändert die Sperre eines Spielers: Anzahl Spiele, Wettbewerb und
  /// Startdatum. games == 0 hebt die Sperre auf (löscht Wettbewerb/Datum).
  /// Spiegelt auch in die Cloud (über updatePlayer).
  Future<void> setSuspension(
    Player p, {
    required int games,
    String? competition,
    DateTime? from,
  }) async {
    final g = games < 0 ? 0 : games;
    final updated = g == 0
        ? p.copyWith(
            suspendedGames: 0,
            clearSuspensionCompetition: true,
            clearSuspensionFrom: true,
          )
        : p.copyWith(
            suspendedGames: g,
            suspensionCompetition: competition,
            clearSuspensionCompetition: competition == null,
            suspensionFrom: from,
            clearSuspensionFrom: from == null,
          );
    await updatePlayer(updated);
  }

  /// Anzahl noch abzusitzender Spiele ändern, Wettbewerb/Startdatum behalten.
  Future<void> setSuspendedGames(Player p, int games) => setSuspension(
    p,
    games: games,
    competition: p.suspensionCompetition,
    from: p.suspensionFrom,
  );

  /// Vorkommende Wettbewerbe im Spielplan (für die Sperren-Auswahl).
  List<String> competitionsInSchedule() {
    final set = <String>{};
    for (final m in _matches) {
      final c = m.competition?.trim();
      if (c != null && c.isNotEmpty) set.add(c);
    }
    final list = set.toList()..sort();
    return list;
  }

  /// Die nächsten N angesetzten Spiele, für die der Spieler gesperrt ist:
  /// Wettbewerb der Sperre (oder alle) ab dem Startdatum, nach Datum sortiert.
  List<GameMatch> suspensionMatches(Player p) {
    if (p.suspendedGames <= 0) return const [];
    final from = p.suspensionFrom;
    final comp = p.suspensionCompetition;
    final list =
        _matches
            .where(
              (m) =>
                  m.status == MatchStatus.scheduled &&
                  m.kickoff != null &&
                  (comp == null || m.competition == comp) &&
                  (from == null || !m.kickoff!.isBefore(from)),
            )
            .toList()
          ..sort((a, b) => a.kickoff!.compareTo(b.kickoff!));
    return list.take(p.suspendedGames).toList();
  }

  /// Ist der Spieler für dieses konkrete Spiel gesperrt? (wettbewerbsgenau)
  bool isSuspendedForMatch(Player p, GameMatch m) =>
      suspensionMatches(p).any((x) => x.id == m.id);

  /// Setzt Spieler, deren Abwesenheit abgelaufen ist, automatisch auf „Fit".
  Future<void> _autoRevertAbsences() async {
    final team = _ownTeam;
    if (team == null) return;
    // Für jeden Spieler den Status an die Abwesenheiten + das heutige Datum
    // angleichen: neu begonnene Abwesenheit → Status setzen; abgelaufene →
    // zurück auf „Fit". Über updatePlayer, damit es in die Cloud gespiegelt wird
    // und nicht beim nächsten Pull wieder überschrieben wird.
    final players = await _repo.getPlayers(team.id);
    for (final p in players) {
      await _syncStatusFromAbsences(p.id);
    }
  }

  /// Öffentlicher Einstieg für den Auto-Revert (App-Start + Vordergrund).
  Future<void> revertExpiredAbsences() => _autoRevertAbsences();

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
    String teamId,
    List<PlayerData> players,
  ) async {
    if (players.isEmpty) return 0;
    final persist = FupaPersistence(_repo);
    final added = await persist.syncPlayers(teamId, players, DataSource.manual);
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
    String matchId,
    Map<String, String> info,
  ) async {
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
    String matchId,
    String playerId,
    int? number,
  ) async {
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
    String matchId,
    Map<String, String> info,
  ) async {
    await _repo.setSetting('announce_$matchId', jsonEncode(info));
  }

  // ------------------------------------------------------------- Nominations
  /// Status je Spieler für ein Spiel (Spieler ohne Datensatz = offen).
  Future<Map<String, NominationStatus>> nominationsOf(String matchId) async {
    final rows = await _repo.getNominations(matchId);
    return {for (final n in rows) n.playerId: n.status};
  }

  Future<void> setNomination(
    String matchId,
    String playerId,
    NominationStatus status,
  ) async {
    if (status == NominationStatus.open) {
      await _repo.deleteNomination(matchId, playerId);
    } else {
      await _repo.upsertNomination(
        Nomination(
          id: _uuid.v4(),
          matchId: matchId,
          playerId: playerId,
          status: status,
          updatedAt: DateTime.now(),
        ),
      );
      final label = switch (status) {
        NominationStatus.zugesagt => 'Zusage',
        NominationStatus.abgesagt => 'Absage',
        NominationStatus.unsicher => 'Unsicher',
        NominationStatus.unterVorbehalt => 'Vorbehalt',
        NominationStatus.open => 'Offen',
      };
      await logActivity(
        ActivityType.nomination,
        '$label: ${await _playerName(playerId)}',
      );
    }
    notifyListeners();
  }

  /// Setzt für mehrere Spieler denselben Status (Bulk, z.B. „alle zusagen").
  Future<void> setNominationBulk(
    String matchId,
    List<String> playerIds,
    NominationStatus status,
  ) async {
    for (final id in playerIds) {
      if (status == NominationStatus.open) {
        await _repo.deleteNomination(matchId, id);
      } else {
        await _repo.upsertNomination(
          Nomination(
            id: _uuid.v4(),
            matchId: matchId,
            playerId: id,
            status: status,
            updatedAt: DateTime.now(),
          ),
        );
      }
    }
    notifyListeners();
  }

  /// Wird beim Öffnen eines Spiels aufgerufen (Gegner sicherstellen).
  Future<ImportResult> openMatch(GameMatch match, {bool force = false}) async {
    final result = await opponentSync.ensureOpponentForMatch(
      match,
      force: force,
    );
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
  /// Die EIGENE Aufstellung des Trainers für ein Spiel – vorhanden, sonst eine
  /// unbesitzte (Alt-)Aufstellung übernehmen, sonst neu anlegen. Jeder Trainer
  /// hat seine eigene; genau eine kann freigegeben werden.
  Future<Lineup> ensureLineup(
    String matchId,
    String teamId, {
    String formation = '4-4-2',
  }) async {
    final me = _me;
    final mine = await _repo.getMyLineup(matchId, teamId, me);
    if (mine != null) return mine;
    // Alt-/unbesitzte Aufstellung als eigene übernehmen (Migration/Altbestand).
    final unowned = await _repo.getUnownedLineup(matchId, teamId);
    if (unowned != null) {
      final claimed = unowned.copyWith(
        createdBy: me,
        creatorName: CloudService.myName,
      );
      await _repo.upsertLineup(claimed);
      return claimed;
    }
    final lineup = Lineup(
      // Deterministische ID pro (Spiel, Team, Trainer) → genau eine Cloud-Zeile.
      id: 'lu_${matchId}_${teamId}_$me',
      matchId: matchId,
      teamId: teamId,
      formation: formation,
      createdBy: me,
      creatorName: CloudService.myName,
      createdAt: DateTime.now(),
    );
    await _repo.upsertLineup(lineup);
    return lineup;
  }

  /// Alle Aufstellungen eines Spiels (je Trainer eine), freigegebene zuerst.
  Future<List<Lineup>> lineupsForMatch(String matchId, String teamId) =>
      _repo.getLineupsForMatch(matchId, teamId);

  Future<Lineup?> getLineupById(String id) => _repo.getLineupById(id);

  /// Gibt diese Aufstellung für „Live" frei (alle anderen werden entsperrt).
  Future<void> releaseLineup(Lineup lineup) async {
    await _repo.releaseLineup(lineup.id, lineup.matchId, lineup.teamId);
    notifyListeners();
  }

  /// Ist dieser Trainer der Ersteller der Aufstellung? (darf sie bearbeiten)
  bool isMyLineup(Lineup l) =>
      (l.createdBy ?? '') == _me || l.createdBy == null;

  /// Vorschläge zu einer Aufstellung.
  Future<List<Lineup>> suggestionsFor(String lineupId) =>
      _repo.getSuggestionsFor(lineupId);

  /// Öffnet meinen Vorschlag zu einer fremden Aufstellung – vorhanden, sonst
  /// als Kopie (inkl. Einträge) neu anlegen. Der Vorschlag ist meine eigene,
  /// bearbeitbare Aufstellung und steht dem Ersteller zur Übernahme bereit.
  Future<Lineup> createOrOpenSuggestion(Lineup original) async {
    final me = _me;
    final existing = await _repo.getMySuggestionOf(original.id, me);
    if (existing != null) return existing;
    final sugg = Lineup(
      id: 'lu_sg_${original.id}_$me',
      matchId: original.matchId,
      teamId: original.teamId,
      formation: original.formation,
      createdBy: me,
      creatorName: CloudService.myName,
      suggestionOf: original.id,
      createdAt: DateTime.now(),
    );
    await _repo.upsertLineup(sugg);
    final entries = await _repo.getLineupEntries(original.id);
    final copies = [
      for (final e in entries)
        LineupEntry(
          id: 'le_${sugg.id}_${e.playerId}',
          lineupId: sugg.id,
          playerId: e.playerId,
          role: e.role,
          positionLabel: e.positionLabel,
          orderIndex: e.orderIndex,
          posX: e.posX,
          posY: e.posY,
        ),
    ];
    await _repo.replaceLineupEntries(sugg.id, copies);
    notifyListeners();
    return sugg;
  }

  /// Übernimmt einen Vorschlag in die Original-Aufstellung (Einträge + Formation)
  /// und entfernt den Vorschlag danach. Nur sinnvoll für den Ersteller.
  Future<void> adoptSuggestion(Lineup suggestion) async {
    final origId = suggestion.suggestionOf;
    if (origId == null) return;
    final orig = await _repo.getLineupById(origId);
    if (orig == null) return;
    final entries = await _repo.getLineupEntries(suggestion.id);
    final copies = [
      for (final e in entries)
        LineupEntry(
          id: 'le_${orig.id}_${e.playerId}',
          lineupId: orig.id,
          playerId: e.playerId,
          role: e.role,
          positionLabel: e.positionLabel,
          orderIndex: e.orderIndex,
          posX: e.posX,
          posY: e.posY,
        ),
    ];
    await _repo.upsertLineup(orig.copyWith(formation: suggestion.formation));
    await _repo.replaceLineupEntries(orig.id, copies);
    await _repo.deleteLineupById(suggestion.id);
    final proposer = suggestion.creatorName?.trim();
    await logActivity(
      ActivityType.lineup,
      'Aufstellungs-Vorschlag übernommen',
      subtitle: (proposer != null && proposer.isNotEmpty)
          ? 'Vorschlag von $proposer wurde übernommen'
          : 'Ein Vorschlag wurde übernommen',
    );
    await _notify(
      suggestion.createdBy,
      InboxType.lineupAdopted,
      'Dein Aufstellungs-Vorschlag wurde übernommen',
      subtitle:
          '${CloudService.displayName ?? 'Ein Trainer'} hat ihn übernommen',
      linkType: 'match',
      linkId: suggestion.matchId,
    );
    notifyListeners();
  }

  /// Lehnt einen Vorschlag ab (löscht ihn) und informiert das Team (Feed), damit
  /// der vorschlagende Trainer erfährt, dass sein Vorschlag abgelehnt wurde.
  Future<void> rejectSuggestion(Lineup suggestion) async {
    await _repo.deleteLineupById(suggestion.id);
    final proposer = suggestion.creatorName?.trim();
    await logActivity(
      ActivityType.lineup,
      'Aufstellungs-Vorschlag abgelehnt',
      subtitle: (proposer != null && proposer.isNotEmpty)
          ? 'Vorschlag von $proposer wurde abgelehnt'
          : 'Ein Vorschlag wurde abgelehnt',
    );
    await _notify(
      suggestion.createdBy,
      InboxType.lineupRejected,
      'Dein Aufstellungs-Vorschlag wurde abgelehnt',
      subtitle:
          '${CloudService.displayName ?? 'Ein Trainer'} hat ihn abgelehnt',
      linkType: 'match',
      linkId: suggestion.matchId,
    );
    notifyListeners();
  }

  /// Verwirft einen Vorschlag (löscht ihn, ohne Feed-Eintrag).
  Future<void> discardSuggestion(Lineup suggestion) async {
    await _repo.deleteLineupById(suggestion.id);
    notifyListeners();
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

  /// Alle Ereignisse aller Spiele (für die Saison-Gesamtstatistik).
  Future<List<MatchEvent>> allEvents() => _repo.getAllEvents();

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
      await _repo.upsertCard(
        CardEntry(
          id: _uuid.v4(),
          playerId: playerId,
          type: cardType,
          date: match?.kickoff ?? DateTime.now(),
          matchId: matchId,
          matchEventId: eventId,
          minute: minute,
          minuteExtra: minuteExtra,
          note: note,
        ),
      );
    }

    // Feed: Tore & Karten des eigenen Teams (keine Phasen-Marken).
    if (playerId != null && teamId == _ownTeam?.id && !type.isPhaseMarker) {
      final name = await _playerName(playerId);
      final (String? label, ActivityType kind) = switch (type) {
        MatchEventType.goal => ('Tor: $name', ActivityType.goal),
        MatchEventType.penalty => ('Tor (Elfmeter): $name', ActivityType.goal),
        MatchEventType.yellowCard => ('Gelb: $name', ActivityType.card),
        MatchEventType.secondYellow => ('Gelb-Rot: $name', ActivityType.card),
        MatchEventType.redCard => ('Rot: $name', ActivityType.card),
        _ => (null, ActivityType.other),
      };
      if (label != null) await logActivity(kind, label);
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
    await _repo.upsertCard(
      CardEntry(
        id: _uuid.v4(),
        playerId: playerId,
        type: type,
        date: date,
        matchId: matchId,
        minute: minute,
        note: note,
      ),
    );
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

  Future<void> addNote(
    String playerId,
    String text, {
    String? categoryId,
    String? matchId,
  }) async {
    await _repo.upsertNote(
      PlayerNote(
        id: _uuid.v4(),
        playerId: playerId,
        text: text.trim(),
        createdAt: DateTime.now(),
        categoryId: categoryId,
        matchId: matchId,
      ),
    );
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
    await _repo.upsertNoteCategory(
      NoteCategory(
        id: _uuid.v4(),
        name: name.trim(),
        sortOrder: existing.length,
      ),
    );
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
    String eventId,
    String playerId,
    NominationStatus status,
  ) async {
    if (status == NominationStatus.open) {
      await _repo.deleteEventAttendance(eventId, playerId);
    } else {
      await _repo.upsertEventAttendance(
        EventAttendance(
          id: _uuid.v4(),
          eventId: eventId,
          playerId: playerId,
          status: status,
          updatedAt: DateTime.now(),
        ),
      );
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
        await _repo.upsertMatch(
          match.copyWith(
            status: MatchStatus.scheduled,
            ownScore: 0,
            opponentScore: 0,
            // Ab jetzt selbst verwaltet – FuPa setzt das Spiel nicht wieder
            // auf „beendet" (sonst käme es sofort zurück ins Nachholen).
            locallyManaged: true,
            // Live-Steuerung freigeben.
            clearController: true,
          ),
        );
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
            'live_controller': null,
            'live_controller_name': null,
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
    // Beim Live-Gehen wird der Starter zum Controller (falls noch keiner ist);
    // beim Abpfiff wird die Steuerung wieder freigegeben.
    final noController =
        match.liveController == null || match.liveController!.isEmpty;
    final becomeController = status == MatchStatus.live && noController;
    final releaseController = status == MatchStatus.finished;
    await _repo.upsertMatch(
      match.copyWith(
        status: status,
        liveController: becomeController ? CloudService.userId : null,
        liveControllerName: becomeController ? CloudService.myName : null,
        clearController: releaseController,
      ),
    );
    await _reload();
    notifyListeners();
    // Status (z.B. „live"/„beendet") + Controller teilen, damit das Live-Spiel
    // bei allen sichtbar ist und klar ist, wer steuert.
    if (_activeCloudTeamId != null &&
        CloudService.ready &&
        CloudService.signedIn) {
      try {
        await CloudService.updateMatch(matchId, {
          'status': status.storageKey,
          if (becomeController) 'live_controller': CloudService.userId,
          if (becomeController) 'live_controller_name': CloudService.myName,
          if (releaseController) 'live_controller': null,
          if (releaseController) 'live_controller_name': null,
        });
      } catch (_) {}
      // Geht das Spiel live, Push an alle Team-Mitglieder (auch bei
      // geschlossener App) über die Edge-Function.
      if (status == MatchStatus.live && match.status != MatchStatus.live) {
        CloudService.notifyLive(
          _activeCloudTeamId!,
          matchId,
          match.opponentName,
        );
      }
      // Abpfiff: Spielergebnis team-weit in den Posteingang.
      if (status == MatchStatus.finished &&
          match.status != MatchStatus.finished) {
        final m = await _repo.getMatch(matchId);
        if (m != null) {
          await _notifyTeam(
            InboxType.result,
            'Spielergebnis steht',
            subtitle: 'vs ${m.opponentName} ${m.ownScore}:${m.opponentScore}',
            linkType: 'match',
            linkId: matchId,
          );
        }
      }
    }
  }

  /// Übernimmt die Steuerung des Live-Spiels (anderer Trainer, mit Bestätigung
  /// in der UI). Setzt den Controller auf den aktuellen Nutzer.
  Future<void> takeOverLiveControl(String matchId) async {
    final match = await _repo.getMatch(matchId);
    if (match == null) return;
    await _repo.upsertMatch(
      match.copyWith(
        liveController: CloudService.userId,
        liveControllerName: CloudService.myName,
      ),
    );
    await _reload();
    notifyListeners();
    if (_activeCloudTeamId != null &&
        CloudService.ready &&
        CloudService.signedIn) {
      try {
        await CloudService.updateMatch(matchId, {
          'live_controller': CloudService.userId,
          'live_controller_name': CloudService.myName,
        });
      } catch (_) {}
    }
  }

  // ---------------------------------------------------------------- Ratings
  Future<List<PlayerRating>> ratingsOf(String matchId) =>
      _repo.getRatings(matchId);

  /// Die EIGENEN Bewertungen eines Spiels als Map spielerId -> Bewertung
  /// (fürs Bearbeiten – jeder Trainer sieht/ändert seine eigene Note).
  Future<Map<String, PlayerRating>> ratingsMapOf(String matchId) async {
    final me = _me;
    final list = await _repo.getRatings(matchId);
    return {
      for (final r in list)
        if ((r.userId ?? '') == me) r.playerId: r,
    };
  }

  /// Aktueller Benutzer (für pro-Benutzer-Bewertungen). Ohne Cloud „local".
  String get _me => CloudService.userId ?? 'local';

  Future<void> setRating({
    required String matchId,
    required String playerId,
    required double rating,
    String? note,
    bool keepNote = true,
  }) async {
    final me = _me;
    final existing = await _repo.getRatings(matchId);
    // Nur die EIGENE Zeile (match, player, user) aktualisieren – jeder Trainer
    // bewertet eigenständig, der angezeigte Schnitt ist über alle Trainer.
    final prior = existing
        .where((r) => r.playerId == playerId && (r.userId ?? '') == me)
        .firstOrNull;
    await _repo.upsertRating(
      PlayerRating(
        id: prior?.id ?? _uuid.v4(),
        matchId: matchId,
        playerId: playerId,
        userId: me,
        rating: rating,
        note: note ?? (keepNote ? prior?.note : null),
        createdAt: prior?.createdAt ?? DateTime.now(),
      ),
    );
    // Nur die erste Bewertung je Spieler/Spiel protokollieren (kein Spam beim
    // Nachjustieren der Note).
    if (prior == null) {
      await logActivity(
        ActivityType.rating,
        'Bewertung: ${await _playerName(playerId)}',
        subtitle: 'Note ${rating.toStringAsFixed(1).replaceAll('.', ',')}',
      );
    }
    notifyListeners();
  }

  /// Entfernt die EIGENE Bewertung eines Spielers für ein Spiel.
  Future<void> removeRating(String matchId, String playerId) async {
    final me = _me;
    final existing = await _repo.getRatings(matchId);
    for (final r in existing.where(
      (r) => r.playerId == playerId && (r.userId ?? '') == me,
    )) {
      await _repo.deleteRating(r.id);
    }
    notifyListeners();
  }

  /// Schnitt + Anzahl je Spieler für ein Spiel (über alle Benutzer).
  Future<Map<String, (double, int)>> ratingAverages(String matchId) =>
      _repo.ratingAveragesForMatch(matchId);

  // -------------------------------------------------- Spieler des Monats
  Future<List<String>> ratedMonths(String teamId) =>
      _repo.monthsWithRatings(teamId);

  /// Monats-Rangliste: bewertete Spieler nach Schnitt (dann Anzahl), danach die
  /// übrigen Kaderspieler ohne Bewertung. avg == null = keine Bewertung.
  Future<List<(Player, double?, int)>> monthRanking(
    String teamId,
    String yearMonth,
  ) async {
    final players = (await playersOf(
      teamId,
    )).where((p) => !p.isStaffOnly).toList();
    final avgs = await _repo.ratingAveragesForTeamInMonth(teamId, yearMonth);
    final rated = <(Player, double?, int)>[];
    final unrated = <(Player, double?, int)>[];
    for (final p in players) {
      final a = avgs[p.id];
      if (a != null) {
        rated.add((p, a.$1, a.$2));
      } else {
        unrated.add((p, null, 0));
      }
    }
    rated.sort((x, y) {
      final c = (y.$2 ?? 0).compareTo(x.$2 ?? 0);
      return c != 0 ? c : y.$3.compareTo(x.$3);
    });
    unrated.sort(
      (x, y) => (x.$1.number ?? 9999).compareTo(y.$1.number ?? 9999),
    );
    return [...rated, ...unrated];
  }

  /// Monats-Statistik eines Spielers aus den live getrackten Spielen (mit
  /// Anpfiff-Marke), deren Anpfiff im [yearMonth] (YYYY-MM) der eigenen
  /// Mannschaft liegt. Für die Spieler-des-Monats-Urkunde/-Grafik.
  Future<PlayerMonthStats> playerMonthStats(
    String teamId,
    String yearMonth,
    String playerId,
  ) => _aggregatePlayerStats(teamId, playerId, yearMonth: yearMonth);

  /// Gesamt-Statistik eines Spielers über ALLE live getrackten eigenen Spiele
  /// (ohne Monatsfilter) – für Ehrungen/Anlässe (z.B. „100. Spiel").
  Future<PlayerMonthStats> playerTotalStats(String teamId, String playerId) =>
      _aggregatePlayerStats(teamId, playerId);

  // ----------------------------------------------------------- Aktivitäts-Feed
  /// Die neuesten Aktivitäten für den Start-Feed (neueste zuerst).
  Future<List<Activity>> recentActivities({int limit = 20}) =>
      _repo.recentActivities(limit: limit);

  /// Protokolliert eine Trainer-Aktion im team-weiten Aktivitäten-Feed
  /// (lokal + Cloud). Fehler werden geschluckt – der Feed darf nie die
  /// eigentliche Aktion stören.
  Future<void> logActivity(
    ActivityType type,
    String title, {
    String? subtitle,
  }) async {
    if (_ownTeam == null) return;
    try {
      await _repo.addActivity(
        Activity(
          id: _uuid.v4(),
          actorId: CloudService.user?.id,
          actorName: CloudService.displayName ?? 'Trainer',
          type: type,
          title: title,
          subtitle: subtitle,
          createdAt: DateTime.now(),
        ),
      );
      notifyListeners();
    } catch (_) {
      // Feed-Eintrag ist optional.
    }
  }

  // ----------------------------------------------------------------- Posteingang
  /// Meine Posteingang-Einträge (neueste zuerst).
  Future<List<InboxMessage>> inboxMessages() => _repo.getInbox();

  /// Anzahl ungelesener Posteingang-Einträge (für Glocke/Badge).
  Future<int> inboxUnreadCount() => _repo.unreadInboxCount();

  Future<void> markInboxRead(String id) async {
    await _repo.markInboxRead(id);
    notifyListeners();
  }

  Future<void> markAllInboxRead() async {
    await _repo.markAllInboxRead();
    notifyListeners();
  }

  /// Legt einen Posteingang-Eintrag für EINEN Empfänger an – direkt in der Cloud
  /// (nicht lokal; meine eigenen Einträge kommen per Pull/Realtime). Für mich
  /// selbst wird nichts erzeugt. Stößt zusätzlich eine Push an (best effort).
  Future<void> _notify(
    String? recipientUserId,
    InboxType type,
    String title, {
    String? subtitle,
    String? linkType,
    String? linkId,
  }) async {
    final team = _activeCloudTeamId;
    final me = _me;
    if (team == null ||
        recipientUserId == null ||
        recipientUserId.isEmpty ||
        recipientUserId == me ||
        !CloudService.ready ||
        !CloudService.signedIn) {
      return;
    }
    final msg = InboxMessage(
      id: _uuid.v4(),
      recipientId: recipientUserId,
      actorId: CloudService.user?.id,
      actorName: CloudService.displayName ?? CloudService.email ?? 'Trainer',
      type: type,
      title: title,
      subtitle: subtitle,
      linkType: linkType,
      linkId: linkId,
      createdAt: DateTime.now(),
    );
    try {
      await CloudService.upsertRow('inbox', {...msg.toMap(), 'team_id': team});
    } catch (_) {
      return; // ohne Cloud kein Eintrag für andere
    }
    await CloudService.notifyInbox([recipientUserId], title, subtitle ?? '');
  }

  /// Wie [_notify], aber an alle Team-Mitglieder außer mir (team-weite Info).
  /// [exclude] lässt zusätzlich bestimmte Konten aus (z.B. bereits per
  /// Erwähnung Benachrichtigte, damit sie keinen Doppel-Eintrag bekommen).
  Future<void> _notifyTeam(
    InboxType type,
    String title, {
    String? subtitle,
    String? linkType,
    String? linkId,
    Set<String> exclude = const <String>{},
  }) async {
    final team = _activeCloudTeamId;
    if (team == null || !CloudService.ready || !CloudService.signedIn) return;
    final me = _me;
    List<Map<String, dynamic>> members;
    try {
      members = await CloudService.teamMembers(team);
    } catch (_) {
      return;
    }
    for (final m in members) {
      final uid = m['user_id'] as String?;
      if (uid == null || uid == me || exclude.contains(uid)) continue;
      await _notify(
        uid,
        type,
        title,
        subtitle: subtitle,
        linkType: linkType,
        linkId: linkId,
      );
    }
  }

  /// Mit-Trainer des aktiven Teams (ohne mich) für die „Erwähnen"-Auswahl:
  /// (user_id, Anzeigename). Leer ohne Cloud.
  Future<List<({String userId, String name})>> teamTrainers() async {
    final team = _activeCloudTeamId;
    if (team == null || !CloudService.ready || !CloudService.signedIn) {
      return const [];
    }
    try {
      final rows = await CloudService.teamMembers(team);
      final me = _me;
      final out = <({String userId, String name})>[];
      for (final r in rows) {
        final uid = r['user_id'] as String?;
        if (uid == null || uid == me) continue;
        out.add((
          userId: uid,
          name: _trainerLabel(
            r['display_name'] as String?,
            r['email'] as String?,
          ),
        ));
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// Konten (user_id), die mit einem Spielerprofil verknüpft sind (für „zu
  /// Aufgabe hinzugefügt"). Leer ohne Cloud.
  Future<List<String>> _accountsForPlayer(String playerId) async {
    final team = _activeCloudTeamId;
    if (team == null || !CloudService.ready || !CloudService.signedIn) {
      return const [];
    }
    try {
      final map = await CloudService.memberPlayers(team);
      return [
        for (final e in map.entries)
          if (e.value.contains(playerId)) e.key,
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Anzeigename eines Spielers (für Feed-Texte); Rückfall „Spieler".
  Future<String> _playerName(String playerId) async =>
      (await _repo.getPlayer(playerId))?.fullName ?? 'Spieler';

  /// FuPa-Laufbahn eines Spielers samt aufgelöstem Verein (für die Vereins-
  /// Gesamtstatistik in der Grafik, live umschaltbar alle/nur Pflichtspiele).
  /// Lädt die FuPa-Spielerseite (Netzwerk); bei Fehlern/ohne FuPa-Bezug `null`.
  /// Löst die echte FuPa-Spieler-Profil-ID auf: zuerst aus der Saison-Statistik
  /// (per Name), sonst live aus der FuPa-Saison-API, zuletzt player.external_id
  /// (die ist die Kader-/Roster-ID und taugt meist nicht). `null` wenn keine.
  Future<String?> _resolveFupaPlayerId(
    Team? team,
    String teamId,
    Player player,
  ) async {
    final key = player.dedupKey;
    for (final s in await _repo.getStats(teamId)) {
      final k =
          '${s.firstName.trim().toLowerCase()}|${s.lastName.trim().toLowerCase()}';
      if (k == key) {
        final e = s.externalId?.trim();
        if (e != null && e.isNotEmpty) return e;
      }
    }
    if (team?.fupaUrl?.isNotEmpty ?? false) {
      for (final s in await _importer.importStats(team!.fupaUrl!)) {
        final k =
            '${s.firstName.trim().toLowerCase()}|${s.lastName.trim().toLowerCase()}';
        if (k == key) {
          final e = s.externalId?.trim();
          if (e != null && e.isNotEmpty) return e;
        }
      }
    }
    // Trainer: Profil-ID aus dem Coach-Slug der Teamseite.
    if (team?.fupaUrl?.isNotEmpty ?? false) {
      try {
        for (final c in await _importer.importCoachProfiles(team!.fupaUrl!)) {
          final k =
              '${c.firstName.trim().toLowerCase()}|${c.lastName.trim().toLowerCase()}';
          if (k == key && c.slug.isNotEmpty) return c.slug;
        }
      } catch (_) {
        // Ohne Trainer-Slug bleibt nur der Rückfall.
      }
    }
    final pe = player.externalId?.trim();
    return (pe != null && pe.isNotEmpty) ? pe : null;
  }

  Future<FupaClubCareer?> playerFupaClub(String teamId, Player player) async {
    try {
      final team = await _repo.getTeam(teamId);
      final ext = await _resolveFupaPlayerId(team, teamId, player);
      if (ext == null) return null;
      final holder = FupaClubCareer(
        career: await _importer.importPlayerCareer(ext),
        clubSlug: FupaReduxImporter.clubSlugFromTeamUrl(team?.fupaUrl),
        clubName: team?.name ?? team?.shortName,
      );
      // Nur zurückgeben, wenn es überhaupt Vereins-Daten gibt.
      return holder.total().hasAny ? holder : null;
    } catch (_) {
      return null;
    }
  }

  /// Komplette FuPa-Laufbahn eines Spielers (alle Saisons/Vereine + Gesamt-
  /// Bilanz) für das Spieler-Detail. Netzwerk; null bei Fehler/ohne FuPa.
  Future<FupaCareer?> playerFupaCareer(String teamId, Player player) async {
    try {
      final team = await _repo.getTeam(teamId);
      final ext = await _resolveFupaPlayerId(team, teamId, player);
      if (ext == null) return null;
      return await _importer.importPlayerCareer(ext);
    } catch (_) {
      return null;
    }
  }

  /// Vereins-Bilanz aller aktiven Feldspieler aus FuPa: je Spieler die
  /// Laufbahn-Summen beim aktuellen Verein (gesamt + nur Pflichtspiele) plus
  /// die Minuten der laufenden Saison. Lädt je Spieler die FuPa-Spielerseite
  /// (parallel, Netzwerk); Spieler ohne FuPa/ohne Daten erscheinen mit 0.
  Future<(List<PlayerClubStats>, String)> squadFupaClubStats(
    String teamId,
  ) async {
    final team = await _repo.getTeam(teamId);
    final clubSlug = FupaReduxImporter.clubSlugFromTeamUrl(team?.fupaUrl);
    final clubName = team?.name ?? team?.shortName;
    // Alle aktiven Personen inkl. Trainerteam (Spieler, spielende Co-Trainer
    // und reine Trainer). Reine Trainer ohne FuPa-Daten fliegen unten raus.
    final players = (await _repo.getPlayers(
      teamId,
    )).where((p) => p.active).toList();
    final stats = await _repo.getStats(teamId);
    final minutesByKey = <String, int>{};
    final extByKey = <String, String>{};
    for (final s in stats) {
      final key =
          '${s.firstName.trim().toLowerCase()}|${s.lastName.trim().toLowerCase()}';
      minutesByKey[key] = s.minutes;
      final e = s.externalId?.trim();
      if (e != null && e.isNotEmpty) extByKey[key] = e;
    }
    // Zusätzlich die FuPa-IDs live aus der Saison-API (Name → ID), unabhängig
    // davon, ob sie lokal/aus der Cloud gespeichert sind.
    final apiExtByKey = <String, String>{};
    final teamUrl = team?.fupaUrl;
    if (teamUrl != null && teamUrl.isNotEmpty) {
      try {
        for (final s in await _importer.importStats(teamUrl)) {
          final key =
              '${s.firstName.trim().toLowerCase()}|${s.lastName.trim().toLowerCase()}';
          final e = s.externalId?.trim();
          if (e != null && e.isNotEmpty) apiExtByKey[key] = e;
        }
      } catch (_) {
        // Ohne API-IDs greifen die gespeicherten Fallbacks.
      }
    }
    // Trainer stehen nicht in der Saison-Statistik – ihre FuPa-Profil-ID (im
    // Slug) kommt von der Teamseite (Trainerteam). Nur laden, wenn Staff dabei.
    final coachSlugByKey = <String, String>{};
    if (teamUrl != null &&
        teamUrl.isNotEmpty &&
        players.any((p) => p.isStaff)) {
      try {
        for (final c in await _importer.importCoachProfiles(teamUrl)) {
          final key =
              '${c.firstName.trim().toLowerCase()}|${c.lastName.trim().toLowerCase()}';
          if (c.slug.isNotEmpty) coachSlugByKey[key] = c.slug;
        }
      } catch (_) {
        // Ohne Trainer-Slugs zeigen reine Trainer keine Werte.
      }
    }
    // Karrieren parallel laden. FuPa-SPIELER-ID: zuerst aus der Saison-Statistik
    // bzw. live-API (das ist die echte Profil-ID) – die player.external_id ist
    // die Kader-/Roster-ID und taugt NICHT für /player/…; daher nur Rückfall.
    // Für Trainer greift der Coach-Slug von der Teamseite.
    var resolved = 0;
    String? firstErr;
    final careers = await Future.wait(
      players.map((p) async {
        final ext =
            apiExtByKey[p.dedupKey] ??
            extByKey[p.dedupKey] ??
            coachSlugByKey[p.dedupKey] ??
            (p.externalId?.trim().isNotEmpty ?? false
                ? p.externalId!.trim()
                : null);
        if (ext == null || ext.isEmpty) return null;
        resolved++;
        try {
          return await _importer.importPlayerCareer(ext);
        } catch (e) {
          firstErr ??= e.toString();
          return null;
        }
      }),
    );
    final out = <PlayerClubStats>[];
    for (var i = 0; i < players.length; i++) {
      final p = players[i];
      final career = careers[i];
      out.add(
        PlayerClubStats(
          player: p,
          all:
              career?.clubTotal(clubSlug: clubSlug, clubName: clubName) ??
              const FupaClubTotal(),
          pflicht:
              career?.clubTotal(
                clubSlug: clubSlug,
                clubName: clubName,
                pflichtOnly: true,
              ) ??
              const FupaClubTotal(),
          seasonMinutes: minutesByKey[p.dedupKey] ?? 0,
          hasFupa: career != null,
          isStaff: p.isStaff,
          isFieldPlayer: !p.isStaffOnly,
          spell: career?.currentClubSpell(),
          coachMatches: career?.coachMatches ?? 0,
          coachWins: career?.coachWins ?? 0,
          coachDraws: career?.coachDraws ?? 0,
          coachLosses: career?.coachLosses ?? 0,
          coachPoints: career?.coachPoints ?? 0,
        ),
      );
    }
    // Reine Trainer (nicht spielend) ohne FuPa-Daten (weder Spieler noch
    // Trainer) weglassen.
    out.removeWhere(
      (r) => r.player.isStaffOnly && !r.hasFupa && !r.hasCoachData,
    );
    final careerOk = careers.where((c) => c != null).length;
    final diag =
        'FuPa-Link: ${(teamUrl != null && teamUrl.isNotEmpty) ? 'ja' : 'nein'} · '
        'Verein: ${clubSlug ?? clubName ?? '—'} · '
        'IDs API/lokal: ${apiExtByKey.length}/${extByKey.length} · '
        'aufgelöst: $resolved/${players.length} · Laufbahn ok: $careerOk'
        '${firstErr != null ? ' · Fehler: $firstErr' : ''}';
    return (out, diag);
  }

  /// Aggregiert Tracking-Werte eines Spielers über die getrackten eigenen Spiele;
  /// mit [yearMonth] (YYYY-MM) nur diesen Monat, sonst alle.
  Future<PlayerMonthStats> _aggregatePlayerStats(
    String teamId,
    String playerId, {
    String? yearMonth,
  }) async {
    final events = await allEvents();
    // Getrackte Spiele = Matches mit einer Phasen-Marke (wie Gesamtstatistik).
    final trackedIds = events
        .where((e) => e.type.isPhaseMarker)
        .map((e) => e.matchId)
        .toSet();
    // Eigene getrackte Spiele – optional auf den Monat eingegrenzt.
    final matchIds = <String>{};
    for (final m in matches) {
      if (!trackedIds.contains(m.id)) continue;
      if (m.ownTeamId != teamId) continue;
      if (yearMonth != null) {
        final d = (m.kickoff ?? m.createdAt).toLocal();
        final ym =
            '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}';
        if (ym != yearMonth) continue;
      }
      matchIds.add(m.id);
    }
    var goals = 0, assists = 0, yellow = 0, secondYellow = 0, red = 0;
    final playedIn = <String>{};
    for (final e in events) {
      if (!matchIds.contains(e.matchId)) continue;
      final isOwn = e.teamId == teamId;
      final mine = isOwn && e.playerId == playerId;
      final myAssist = isOwn && e.assistPlayerId == playerId;
      if (mine || myAssist) playedIn.add(e.matchId);
      if (mine &&
          (e.type == MatchEventType.goal || e.type == MatchEventType.penalty)) {
        goals++;
      }
      if (myAssist &&
          (e.type == MatchEventType.goal || e.type == MatchEventType.penalty)) {
        assists++;
      }
      if (mine) {
        if (e.type == MatchEventType.yellowCard) yellow++;
        if (e.type == MatchEventType.secondYellow) secondYellow++;
        if (e.type == MatchEventType.redCard) red++;
      }
    }
    return PlayerMonthStats(
      games: playedIn.length,
      goals: goals,
      assists: assists,
      yellow: yellow,
      secondYellow: secondYellow,
      red: red,
    );
  }

  Future<List<PlayerOfMonth>> honorHistory() => _repo.getPlayersOfMonth();

  Future<PlayerOfMonth?> honoredOf(String yearMonth) async {
    for (final p in await _repo.getPlayersOfMonth()) {
      if (p.yearMonth == yearMonth) return p;
    }
    return null;
  }

  Future<void> honorPlayerOfMonth(String yearMonth, String playerId) async {
    final existing = await honoredOf(yearMonth);
    await _repo.upsertPlayerOfMonth(
      PlayerOfMonth(
        id: existing?.id ?? _uuid.v4(),
        yearMonth: yearMonth,
        playerId: playerId,
        createdAt: existing?.createdAt ?? DateTime.now(),
      ),
    );
    await logActivity(
      ActivityType.playerOfMonth,
      'Spieler des Monats: ${await _playerName(playerId)}',
    );
    notifyListeners();
  }

  // ------------------------------------------- Spiel-Gesamtnote/Abwesenheit
  Future<List<MatchRating>> matchRatingsOf(String matchId) =>
      _repo.getMatchRatings(matchId);

  Future<MatchRating?> myMatchRating(String matchId) async {
    final me = _me;
    final list = await _repo.getMatchRatings(matchId);
    return list.where((r) => (r.userId ?? '') == me).firstOrNull;
  }

  MatchRating _baseMatchRating(String matchId, MatchRating? mine) =>
      mine ??
      MatchRating(
        id: _uuid.v4(),
        matchId: matchId,
        userId: _me,
        createdAt: DateTime.now(),
      );

  Future<void> setMatchRating(String matchId, double? rating) async {
    final mine = await myMatchRating(matchId);
    await _repo.upsertMatchRating(
      _baseMatchRating(matchId, mine).copyWith(
        userId: _me,
        rating: rating,
        clearRating: rating == null,
        updatedAt: DateTime.now(),
      ),
    );
    notifyListeners();
  }

  /// Eigener Spielbericht/Kommentar zum Spiel (Freitext, je Trainer einer).
  /// Leer = Bericht entfernen. Liegt auf der eigenen match_ratings-Zeile.
  Future<void> setMatchNote(
    String matchId,
    String? note, {
    List<String> mentionUserIds = const [],
  }) async {
    final mine = await myMatchRating(matchId);
    final wasEmpty = (mine?.note ?? '').trim().isEmpty;
    final trimmed = note?.trim();
    final empty = trimmed == null || trimmed.isEmpty;
    await _repo.upsertMatchRating(
      _baseMatchRating(matchId, mine).copyWith(
        userId: _me,
        note: trimmed,
        clearNote: empty,
        updatedAt: DateTime.now(),
      ),
    );
    notifyListeners();
    // Erwähnte Trainer benachrichtigen.
    await _notifyMentions(
      mentionUserIds,
      'Im Spielbericht erwähnt',
      trimmed,
      linkType: 'match',
      linkId: matchId,
    );
    // Neuer Bericht (vorher leer, jetzt vorhanden): Team-weite Info – ohne die
    // bereits per Erwähnung benachrichtigten Trainer.
    if (!empty && wasEmpty) {
      final m = await _repo.getMatch(matchId);
      await _notifyTeam(
        InboxType.report,
        'Neuer Spielbericht',
        subtitle: m != null ? 'vs ${m.opponentName}' : null,
        linkType: 'match',
        linkId: matchId,
        exclude: mentionUserIds.toSet(),
      );
    }
  }

  /// „War nicht da / bewerte nicht": setzt nur das Kennzeichen auf der eigenen
  /// Spiel-Gesamtnote. Die (geteilten) Spielerbewertungen bleiben unberührt.
  Future<void> setAbstain(String matchId, bool abstained) async {
    final mine = await myMatchRating(matchId);
    await _repo.upsertMatchRating(
      _baseMatchRating(
        matchId,
        mine,
      ).copyWith(userId: _me, abstained: abstained, updatedAt: DateTime.now()),
    );
    notifyListeners();
  }

  /// Anzeigenamen je Benutzer-ID im Cloud-Team (für Auswertungen). Ohne Cloud
  /// leer (Best effort); der eigene Nutzer wird vom Aufrufer ggf. ergänzt.
  /// Anzeigename aus display_name, sonst E-Mail OHNE Domain (z.B. „a.chenfeld"
  /// statt „a.chenfeld@gmail.com"). Rückfall „Trainer". Den echten Namen kann
  /// nur der jeweilige Trainer selbst setzen (Konto & Team → Name).
  String _trainerLabel(String? displayName, String? email) {
    final n = displayName?.trim();
    if (n != null && n.isNotEmpty) return n;
    final mail = email?.trim();
    if (mail != null && mail.isNotEmpty) {
      final at = mail.indexOf('@');
      return at > 0 ? mail.substring(0, at) : mail;
    }
    return 'Trainer';
  }

  Future<Map<String, String>> teamMemberNames(String teamId) async {
    if (!CloudService.ready || !CloudService.signedIn) return const {};
    try {
      final rows = await CloudService.teamMembers(teamId);
      final map = <String, String>{};
      for (final r in rows) {
        final uid = r['user_id'] as String?;
        if (uid == null) continue;
        map[uid] = _trainerLabel(
          r['display_name'] as String?,
          r['email'] as String?,
        );
      }
      return map;
    } catch (_) {
      return const {};
    }
  }

  /// (Schnitt der Spiel-Gesamtnote, Anzahl Noten, Anzahl Abwesende).
  Future<(double?, int, int)> matchRatingSummary(String matchId) async {
    final list = await _repo.getMatchRatings(matchId);
    final notes = list.where((r) => r.rating != null).map((r) => r.rating!);
    final abs = list.where((r) => r.abstained).length;
    final avg = notes.isEmpty
        ? null
        : notes.reduce((a, b) => a + b) / notes.length;
    return (avg, notes.length, abs);
  }

  /// Ende der Bewertungs-Frist (Spielende + 3 Tage). Spielende = Abpfiff-
  /// Ereignis (live getrackt) sonst Anpfiff + 2h. Null = keine Frist (kein
  /// Anpfiff hinterlegt).
  Future<DateTime?> ratingDeadline(String matchId) async {
    final m = await _repo.getMatch(matchId);
    final kickoff = m?.kickoff;
    if (kickoff == null) return null;
    final events = await _repo.getEvents(matchId);
    DateTime? fulltime;
    for (final e in events) {
      if (e.type == MatchEventType.fulltime) {
        if (fulltime == null || e.createdAt.isAfter(fulltime)) {
          fulltime = e.createdAt;
        }
      }
    }
    final end = fulltime ?? kickoff.add(const Duration(hours: 2));
    return end.add(const Duration(days: 3));
  }

  /// Bewertungen eines Spielers je Spiel (matchId -> Sterne) – fürs Nachholen
  /// und Korrigieren im Profil.
  Future<Map<String, double>> playerRatingsByMatch(String playerId) =>
      _repo.ratingsByPlayer(playerId);

  /// Vollständige EIGENE Bewertungen je Spiel (inkl. Kommentar) – fürs Profil
  /// (bearbeitbar ist nur die eigene Bewertung).
  Future<Map<String, PlayerRating>> playerRatingsFull(String playerId) =>
      _repo.ratingsFullByPlayer(playerId, userId: _me);

  /// Gesamtschnitt eines Spielers über alle Spiele: (Durchschnitt, Anzahl).
  Future<(double?, int)> ratingAverage(String playerId) =>
      _repo.ratingAverage(playerId);

  /// Spiegelt die EIGENEN Bewertungen (Spieler + Spiel-Gesamtnote) erneut in
  /// die Cloud und entfernt lokale verwaiste Null-Benutzer-Zeilen. Nötig, damit
  /// nach dem Umstieg auf pro-Trainer-Bewertungen (Cloud-Stufe 24) beide
  /// Trainer-Noten zusammenlaufen – ohne manuelles Neu-Bewerten. Best effort.
  Future<void> _resyncMyRatingsToCloud() async {
    final removed = await _repo.deleteNullUserRatings();
    if (removed > 0) notifyListeners();
    final team = _activeCloudTeamId;
    final own = _ownTeam;
    if (team == null ||
        own == null ||
        !CloudService.ready ||
        !CloudService.signedIn) {
      return;
    }
    final me = _me;
    try {
      for (final m in await _repo.getMatches(own.id)) {
        for (final r in await _repo.getRatings(m.id)) {
          if ((r.userId ?? '') != me) continue;
          await CloudService.upsertRow('player_ratings', {
            ...r.toMap(),
            'team_id': team,
          }, onConflict: 'match_id,player_id,user_id').catchError((_) {});
        }
        for (final r in await _repo.getMatchRatings(m.id)) {
          if ((r.userId ?? '') != me) continue;
          await CloudService.upsertRow('match_ratings', {
            ...r.toMap(),
            'team_id': team,
          }, onConflict: 'match_id,user_id').catchError((_) {});
        }
      }
    } catch (_) {}
  }

  /// Schnitt + Anzahl eines Spielers in einem Monat (YYYY-MM). Ohne Monat wird
  /// der laufende Kalendermonat genommen.
  Future<(double?, int)> ratingAverageInMonth(
    String playerId, [
    String? yearMonth,
  ]) {
    final ym =
        yearMonth ??
        '${DateTime.now().year.toString().padLeft(4, '0')}-'
            '${DateTime.now().month.toString().padLeft(2, '0')}';
    return _repo.ratingAverageInMonth(playerId, ym);
  }

  Future<Map<String, (double, int)>> ratingAveragesForTeam(String teamId) =>
      _repo.ratingAveragesForTeam(teamId);

  // --------------------------------------------------------------- Scouting
  Future<Set<ScoutMarker>> scoutMarkersOf(String playerId) async {
    final keys = await _repo.getMarkers(playerId);
    return keys.map(ScoutMarker.fromKey).whereType<ScoutMarker>().toSet();
  }

  Future<Map<String, Set<ScoutMarker>>> scoutMarkersForTeam(
    String teamId,
  ) async {
    final raw = await _repo.markersForTeam(teamId);
    return raw.map(
      (pid, keys) => MapEntry(
        pid,
        keys.map(ScoutMarker.fromKey).whereType<ScoutMarker>().toSet(),
      ),
    );
  }

  /// Kommentare je Spieler eines Teams (playerId -> neuester Text).
  Future<Map<String, String>> scoutCommentsForTeam(String teamId) =>
      _repo.commentsForTeam(teamId);

  /// Liga-Tabelle (komplett) + Platz + Form (letzte 5) des Gegners.
  Future<(StandingRow?, List<FormMatch>, List<StandingRow>, List<FixtureMatch>)>
  opponentAnalysis(String ownTeamId, String opponentTeamId) async {
    final opp = await _repo.getTeam(opponentTeamId);
    final oppSlug = FupaReduxImporter.teamSlugFromUrl(opp?.fupaUrl);
    const empty = (null, <FormMatch>[], <StandingRow>[], <FixtureMatch>[]);
    if (oppSlug == null || opp?.fupaUrl == null) return empty;
    // Liga-Slug aus dem GEGNER ableiten (nicht aus unserer Liga – Pokalgegner
    // spielen in einer anderen Liga). Je Gegner gecacht.
    final cacheKey = 'league_slug_$opponentTeamId';
    var leagueSlug = await _repo.getSetting(cacheKey);
    if (leagueSlug == null || leagueSlug.isEmpty) {
      leagueSlug = await _importer.leagueSlugForTeam(opp!.fupaUrl!);
      if (leagueSlug != null) {
        await _repo.setSetting(cacheKey, leagueSlug);
      }
    }
    if (leagueSlug == null) return empty;
    var table = const <StandingRow>[];
    var form = const <FormMatch>[];
    var fixtures = const <FixtureMatch>[];
    try {
      table = await _importer.fetchStanding(leagueSlug);
    } catch (_) {}
    try {
      // Mehr Spiele laden, damit die Niederlagen der ganzen Saison vorliegen;
      // die „letzte 5"-Karte nimmt sich davon die ersten fünf. Kommende Spiele
      // (nächste 5) fallen aus demselben Abruf mit ab.
      final (f, fx) = await _importer.fetchTeamFormAndFixtures(
        leagueSlug,
        oppSlug,
        formLimit: 50,
        fixtureLimit: 5,
      );
      form = f;
      fixtures = fx;
    } catch (_) {}
    StandingRow? standing;
    for (final r in table) {
      if (r.teamSlug == oppSlug) {
        standing = r;
        break;
      }
    }
    return (standing, form, table, fixtures);
  }

  /// Komplette Liga-Tabelle + die Zeile unseres Teams (für die Statistik).
  Future<(StandingRow?, List<StandingRow>)> leagueTable(
    String ownTeamId,
  ) async {
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
    String teamId,
    MaterialDutyConfig config,
  ) async {
    await _repo.setSetting('material_duty_$teamId', config.encode());
    notifyListeners();
    // Materialdienst teilen, wenn dies das aktive Cloud-Team ist.
    if (_activeCloudTeamId == teamId &&
        CloudService.ready &&
        CloudService.signedIn) {
      try {
        await CloudService.updateTeam(teamId, {
          'material_duty': config.encode(),
        });
      } catch (_) {}
    }
  }

  /// Urlaube der Team-Spieler (aus den „Urlaub"-Abwesenheiten) als Zeiträume.
  Future<List<DutyVacation>> materialDutyVacations(String teamId) async {
    final abs = await _repo.absencesForTeam(
      teamId,
      status: PlayerStatus.urlaub,
    );
    return abs.map((a) => DutyVacation(a.playerId, a.from, a.until)).toList();
  }

  Future<void> toggleScoutMarker(
    String playerId,
    ScoutMarker m,
    bool on,
  ) async {
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
      await _repo.upsertNote(
        PlayerNote(
          id: id,
          playerId: playerId,
          text: t,
          createdAt: existing.isNotEmpty
              ? existing.first.createdAt
              : DateTime.now(),
        ),
      );
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
    List<String> mentionUserIds = const [],
  }) async {
    final t = text.trim();
    if (t.isEmpty) return;
    final todo = Todo(
      id: _uuid.v4(),
      text: t,
      createdAt: DateTime.now(),
      dueDate: dueDate,
      topicId: topicId,
      responsible: responsible,
    );
    await _repo.upsertTodo(todo);
    notifyListeners();
    await _notifyTodoAdded(todo, const <String>{});
    await _notifyMentions(
      mentionUserIds,
      'In einer Aufgabe erwähnt',
      todo.text,
      linkType: 'todo',
      linkId: todo.id,
    );
  }

  /// Komplette Aufgabe speichern (z.B. nach dem Bearbeiten im Dialog).
  Future<void> saveTodo(
    Todo todo, {
    List<String> mentionUserIds = const [],
  }) async {
    // Vorherige Verantwortliche ermitteln, um nur NEU hinzugekommene zu melden.
    Set<String> prevPlayerIds = const <String>{};
    try {
      final old = (await _repo.getTodos()).where((x) => x.id == todo.id);
      if (old.isNotEmpty) {
        prevPlayerIds = {
          for (final r in old.first.responsible)
            if (r.playerId != null) r.playerId!,
        };
      }
    } catch (_) {}
    await _repo.upsertTodo(todo);
    notifyListeners();
    await _notifyTodoAdded(todo, prevPlayerIds);
    await _notifyMentions(
      mentionUserIds,
      'In einer Aufgabe erwähnt',
      todo.text,
      linkType: 'todo',
      linkId: todo.id,
    );
  }

  /// Benachrichtigt die mit NEU hinzugekommenen Verantwortlichen verknüpften
  /// Konten (Spielerprofil → Konto via member_players).
  Future<void> _notifyTodoAdded(
    Todo todo,
    Set<String> previousPlayerIds,
  ) async {
    for (final r in todo.responsible) {
      final pid = r.playerId;
      if (pid == null || previousPlayerIds.contains(pid)) continue;
      for (final uid in await _accountsForPlayer(pid)) {
        await _notify(
          uid,
          InboxType.taskAssigned,
          'Du wurdest zu einer Aufgabe hinzugefügt',
          subtitle: todo.text,
          linkType: 'todo',
          linkId: todo.id,
        );
      }
    }
  }

  /// Benachrichtigt erwähnte Trainer (user_ids) – für Aufgaben und Berichte.
  Future<void> _notifyMentions(
    List<String> userIds,
    String title,
    String? subtitle, {
    String? linkType,
    String? linkId,
  }) async {
    for (final uid in userIds) {
      await _notify(
        uid,
        InboxType.mention,
        title,
        subtitle: subtitle,
        linkType: linkType,
        linkId: linkId,
      );
    }
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

  // -------------------------------------------------------------- Sponsoren
  Future<List<Sponsor>> sponsors() => _repo.getSponsors();

  /// Legt einen Sponsor an. Haupt-Sponsor ist exklusiv: ist [isMain] gesetzt,
  /// werden bestehende Haupt-Sponsoren zurückgestuft.
  Future<Sponsor> addSponsor(
    String name, {
    String? logo,
    bool isMain = false,
  }) async {
    final list = await _repo.getSponsors();
    if (isMain) {
      for (final s in list.where((s) => s.isMain)) {
        await _repo.upsertSponsor(s.copyWith(isMain: false));
      }
    }
    final sponsor = Sponsor(
      id: _uuid.v4(),
      name: name.trim(),
      logo: logo,
      isMain: isMain,
      sortOrder: list.length,
    );
    await _repo.upsertSponsor(sponsor);
    notifyListeners();
    return sponsor;
  }

  /// Speichert einen bearbeiteten Sponsor (hält den Haupt-Sponsor exklusiv).
  Future<void> saveSponsor(Sponsor s) async {
    if (s.isMain) {
      final list = await _repo.getSponsors();
      for (final other in list.where((o) => o.isMain && o.id != s.id)) {
        await _repo.upsertSponsor(other.copyWith(isMain: false));
      }
    }
    await _repo.upsertSponsor(s);
    notifyListeners();
  }

  Future<void> deleteSponsor(String id) async {
    await _repo.deleteSponsor(id);
    notifyListeners();
  }

  /// Übernimmt eine neue Reihenfolge der Sponsoren (sort_order = Listenindex).
  /// Nur geänderte Zeilen werden geschrieben; eine Benachrichtigung am Ende.
  Future<void> reorderSponsors(List<Sponsor> ordered) async {
    for (var i = 0; i < ordered.length; i++) {
      final s = ordered[i];
      if (s.sortOrder != i) {
        await _repo.upsertSponsor(s.copyWith(sortOrder: i));
      }
    }
    notifyListeners();
  }

  /// Schiebt alle lokalen Sponsoren (erneut) in die Cloud. Nötig für Sponsoren,
  /// die angelegt wurden, bevor die Cloud-Tabelle existierte – deren einmaliger
  /// Mirror-Push schlug damals still fehl und wird sonst nie wiederholt.
  /// Idempotent (Upsert per id). No-op ohne aktives Cloud-Team.
  Future<void> pushSponsorsToCloud() async {
    final team = _activeCloudTeamId;
    if (team == null || !CloudService.ready || !CloudService.signedIn) return;
    final list = await _repo.getSponsors();
    for (final s in list) {
      try {
        await CloudService.upsertRow('sponsors', {
          ...s.toMap(),
          'team_id': team,
        });
      } catch (_) {
        // Offline/Teilfehler – beim nächsten Öffnen erneut.
      }
    }
  }

  // -------------------------------------------------- Startelf-Grafik-Stil
  /// Grafik-Einstellungen des aktiven Teams (oder Defaults, falls noch keine).
  Future<GraphicSettings> graphicSettings() async {
    final s = await _repo.getGraphicSettings();
    return s ?? GraphicSettings(id: _activeCloudTeamId ?? 'local');
  }

  /// Speichert die Grafik-Einstellungen (id = Cloud-Team-id für eindeutige
  /// Cloud-PK) und spiegelt sie in die Cloud.
  Future<void> saveGraphicSettings(GraphicSettings s) async {
    await _repo.saveGraphicSettings(
      s.copyWith(id: _activeCloudTeamId ?? 'local'),
    );
    notifyListeners();
  }

  /// Schiebt die lokale Grafik-Einstellung (erneut) in die Cloud und
  /// normalisiert dabei die id auf die Team-id (für vor der Cloud-Tabelle
  /// angelegte Einstellungen). No-op ohne aktives Cloud-Team.
  Future<void> pushGraphicSettingsToCloud() async {
    final team = _activeCloudTeamId;
    if (team == null || !CloudService.ready || !CloudService.signedIn) return;
    final s = await _repo.getGraphicSettings();
    if (s == null) return;
    if (s.id != team) {
      // id angleichen (räumt lokal die alte Zeile weg) + Hook spiegelt in Cloud.
      await _repo.saveGraphicSettings(s.copyWith(id: team));
    } else {
      try {
        await CloudService.upsertRow('graphic_settings', {
          ...s.toMap(),
          'team_id': team,
        });
      } catch (_) {}
    }
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
    await _repo.upsertTalk(
      PlayerTalk(
        id: _uuid.v4(),
        playerId: playerId,
        title: title.trim(),
        scheduledAt: scheduledAt,
        notes: notes,
        done: done,
        createdAt: DateTime.now(),
      ),
    );
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
    await _repo.upsertTodo(
      done
          ? todo.copyWith(done: true, completedAt: DateTime.now())
          : todo.copyWith(done: false, clearCompletedAt: true),
    );
    if (done) {
      await logActivity(ActivityType.todo, 'Aufgabe erledigt: ${todo.text}');
    }
    notifyListeners();
  }

  /// Fälligkeitsdatum setzen (null entfernt es).
  Future<void> setTodoDueDate(Todo todo, DateTime? dueDate) async {
    await _repo.upsertTodo(
      dueDate == null
          ? todo.copyWith(clearDueDate: true)
          : todo.copyWith(dueDate: dueDate),
    );
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
        // Offene EIGENE Bewertungen: Bewertungen sind pro Trainer – jeder muss
        // selbst bewerten. ALLE gelaufenen Spiele bleiben hier, bis sie erledigt
        // sind (alle Spieler bewertet ODER „war nicht da / bewerte nicht").
        final mine = await myMatchRating(m.id);
        final abstained = mine?.abstained == true;
        if (!abstained) {
          final roster = await _ratingRoster(m);
          if (roster.isNotEmpty) {
            final me = _me;
            final myRated = (await _repo.getRatings(m.id))
                .where((r) => (r.userId ?? '') == me)
                .map((r) => r.playerId)
                .toSet();
            final open = roster.where((id) => !myRated.contains(id)).length;
            if (open > 0) {
              items.add(
                NachholenItem(
                  kind: NachholenKind.rating,
                  matchId: m.id,
                  title: 'vs ${m.opponentName}',
                  detail:
                      '$open von ${roster.length} Spielern noch zu bewerten',
                  kickoff: m.kickoff,
                ),
              );
            }
          } else if (mine?.rating == null) {
            // Kein Kader (keine Aufstellung/Nominierung): es gibt keine Spieler
            // zu bewerten – offen bleibt es, bis der Trainer eine Gesamtnote
            // abgibt oder „war nicht da" setzt.
            items.add(
              NachholenItem(
                kind: NachholenKind.rating,
                matchId: m.id,
                title: 'vs ${m.opponentName}',
                detail: 'Noch nicht bewertet',
                kickoff: m.kickoff,
              ),
            );
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
          items.add(
            NachholenItem(
              kind: NachholenKind.nomination,
              matchId: m.id,
              title: 'vs ${m.opponentName}',
              detail: 'Noch keine Nominierung',
              kickoff: m.kickoff,
            ),
          );
        } else {
          final zugesagt = noms
              .where((n) => n.status == NominationStatus.zugesagt)
              .length;
          if (zugesagt > 0) {
            final lineup = await _repo.getLineup(m.id, team.id);
            var starters = 0;
            if (lineup != null) {
              starters = (await _repo.getLineupEntries(
                lineup.id,
              )).where((e) => e.role == LineupRole.starter).length;
            }
            if (starters == 0) {
              items.add(
                NachholenItem(
                  kind: NachholenKind.lineup,
                  matchId: m.id,
                  title: 'vs ${m.opponentName}',
                  detail: 'Aufstellung fehlt',
                  kickoff: m.kickoff,
                ),
              );
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
    String playerId,
    String teamId,
  ) async {
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

/// Status-Info eines Spielers für die Kader-Status-Übersicht: der Spieler, bei
/// befristeter Abwesenheit das „bis"-Datum und ein optionaler Grund.
class PlayerStatusInfo {
  final Player player;
  final DateTime? until;
  final String? note;
  const PlayerStatusInfo({required this.player, this.until, this.note});
}

/// Karten-Übersicht eines Spielers: FuPa-Saisonkarten + eigene erfasste Karten.
/// Vereins-Bilanz eines Spielers aus FuPa: Laufbahn-Summen beim Verein
/// (gesamt + nur Pflicht) plus Saison-Minuten. Für die Ehrungen-Übersicht.
class PlayerClubStats {
  final Player player;
  final FupaClubTotal all; // alle Spiele (inkl. Freundschaft/Test)
  final FupaClubTotal pflicht; // nur Pflichtspiele (Pokal zählt)
  final int seasonMinutes; // nur laufende Saison (FuPa)
  final bool hasFupa; // Laufbahn konnte geladen werden
  final bool isStaff; // hat eine Trainerrolle
  final bool isFieldPlayer; // ist (auch) Feldspieler
  final FupaClubSpell? spell; // ununterbrochener Vereins-Lauf (seit wann)

  // Trainer-Bilanz (Karriere) – für die Trainer-Ansicht.
  final int coachMatches;
  final int coachWins;
  final int coachDraws;
  final int coachLosses;
  final int coachPoints;

  const PlayerClubStats({
    required this.player,
    required this.all,
    required this.pflicht,
    required this.seasonMinutes,
    required this.hasFupa,
    this.isStaff = false,
    this.isFieldPlayer = true,
    this.spell,
    this.coachMatches = 0,
    this.coachWins = 0,
    this.coachDraws = 0,
    this.coachLosses = 0,
    this.coachPoints = 0,
  });

  bool get hasCoachData => coachMatches > 0;
}

class PlayerCardSummary {
  final Player player;
  final int fupaYellow;
  final int fupaYellowRed;
  final int fupaRed;
  final int ownYellow;
  final int ownYellowRed;
  final int ownRed;

  const PlayerCardSummary({
    required this.player,
    required this.fupaYellow,
    required this.fupaYellowRed,
    required this.fupaRed,
    required this.ownYellow,
    required this.ownYellowRed,
    required this.ownRed,
  });

  /// Warnung ab der 5. Gelben (feste Schwelle): noch X bis zur Sperre.
  static const yellowThreshold = 5;
  int get yellowToBan {
    final r = yellowThreshold - (fupaYellow % yellowThreshold);
    return r == yellowThreshold ? 0 : r;
  }

  /// true = FuPa-Gelbe hat ein Vielfaches der Schwelle erreicht (Sperre fällig).
  bool get yellowBanDue => fupaYellow > 0 && fupaYellow % yellowThreshold == 0;

  /// Gelbe im laufenden 5er-Zyklus (0..4).
  int get yellowCycle => fupaYellow % yellowThreshold;

  /// Besonders gefährdet: 3 oder 4 Gelbe im Zyklus (1–2 bis zur Sperre),
  /// aber noch nicht fällig/gesperrt.
  bool get yellowWarn => yellowCycle >= 3 && !yellowBanDue;
}

/// Monats-Kennzahlen eines Spielers aus live getrackten Spielen (ein Monat).
class PlayerMonthStats {
  final int games;
  final int goals;
  final int assists;
  final int yellow;
  final int secondYellow;
  final int red;
  const PlayerMonthStats({
    this.games = 0,
    this.goals = 0,
    this.assists = 0,
    this.yellow = 0,
    this.secondYellow = 0,
    this.red = 0,
  });

  /// Rote Karten gesamt (direkt Rot + Gelb-Rot).
  int get redTotal => red + secondYellow;

  /// true = es gibt überhaupt etwas Zählbares zum Anzeigen.
  bool get hasAny =>
      games > 0 || goals > 0 || assists > 0 || yellow > 0 || redTotal > 0;
}
