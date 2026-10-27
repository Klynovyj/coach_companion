// Hintergrund-Live-Uhr: hält die Spielzeit am Laufen, auch wenn die App
// geschlossen/weggewischt ist, und meldet Halbzeit/Abpfiff.
//
// - Android: Vordergrund-Dienst (flutter_foreground_task) mit dauerhafter
//   Benachrichtigung, die jede Sekunde aktualisiert wird. Läuft in einem
//   eigenen Isolate weiter, wenn die App geschlossen ist. Alarm bei 45:00/90:00
//   über flutter_local_notifications.
// - Windows: Fenster-Schließen minimiert in den Infobereich (siehe
//   DesktopTray in main.dart), die UI-Uhr tickt im versteckten Fenster weiter;
//   Alarm ebenfalls über flutter_local_notifications.
//
// Datenaustausch UI-Isolate ⇄ Service-Isolate läuft über
// FlutterForegroundTask.saveData/getData (SharedPreferences-basiert).

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Geteilter Zustand der Live-Uhr.
class MatchClockData {
  const MatchClockData({
    required this.running,
    required this.baseElapsed,
    required this.startedAtMs,
    required this.half,
    required this.phaseLabel,
    required this.ownName,
    required this.oppName,
    required this.ownScore,
    required this.oppScore,
  });

  /// Läuft die Uhr gerade (true) oder ist sie pausiert (Halbzeit)?
  final bool running;

  /// Gespielte Sekunden zum Zeitpunkt [startedAtMs].
  final int baseElapsed;

  /// Zeitpunkt des letzten Uhr-Starts (ms seit Epoch).
  final int startedAtMs;

  /// 1 = erste Halbzeit (Alarm bei 45:00), 2 = zweite Halbzeit (Alarm 90:00).
  final int half;

  /// Anzeigelabel der Phase, z.B. „1. Halbzeit".
  final String phaseLabel;

  final String ownName;
  final String oppName;
  final int ownScore;
  final int oppScore;

  /// Aktuell gespielte Sekunden (bei laufender Uhr echtzeit-korrigiert).
  int currentElapsed() {
    if (!running) return baseElapsed;
    final delta = ((DateTime.now().millisecondsSinceEpoch - startedAtMs) / 1000)
        .floor();
    return baseElapsed + (delta < 0 ? 0 : delta);
  }

  Map<String, dynamic> toJson() => {
    'running': running,
    'base': baseElapsed,
    'ts': startedAtMs,
    'half': half,
    'label': phaseLabel,
    'own': ownName,
    'opp': oppName,
    'os': ownScore,
    'ps': oppScore,
  };

  static MatchClockData? fromJson(Map<String, dynamic> j) {
    try {
      return MatchClockData(
        running: j['running'] == true,
        baseElapsed: (j['base'] as num).toInt(),
        startedAtMs: (j['ts'] as num).toInt(),
        half: (j['half'] as num).toInt(),
        phaseLabel: j['label'] as String? ?? '',
        ownName: j['own'] as String? ?? '',
        oppName: j['opp'] as String? ?? '',
        ownScore: (j['os'] as num?)?.toInt() ?? 0,
        oppScore: (j['ps'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }

  static String formatClock(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

/// Fasst Notification-Titel/Text aus den Uhr-Daten zusammen.
({String title, String text}) _notificationContent(MatchClockData d) {
  final title = '${d.ownName} ${d.ownScore}:${d.oppScore} ${d.oppName}';
  final text =
      '${d.phaseLabel} · ${MatchClockData.formatClock(d.currentElapsed())}';
  return (title: title, text: text);
}

// --------------------------------------------------------------------------
// Fassade für das UI-Isolate
// --------------------------------------------------------------------------

class LiveClock {
  LiveClock._();

  static const _dataKey = 'match_clock';

  static const _channelId = 'live_match_clock';
  static const _alertChannelId = 'live_match_alert';

  static final FlutterLocalNotificationsPlugin _fln =
      FlutterLocalNotificationsPlugin();
  static bool _flnReady = false;

  // Alarm-Status (Windows: im selben Isolate; Android macht das der Dienst).
  static bool _winAlertHalf = false;
  static bool _winAlertFull = false;

  /// Tray-Hook für Windows (wird in main.dart gesetzt).
  static void Function(String? tooltip)? desktopTooltip;

  /// Einmalige Einrichtung beim App-Start.
  static Future<void> initPlatform() async {
    if (Platform.isAndroid) {
      FlutterForegroundTask.initCommunicationPort();
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: _channelId,
          channelName: 'Live-Spiel',
          channelDescription: 'Laufende Spielzeit im Hintergrund',
          channelImportance: NotificationChannelImportance.LOW,
          priority: NotificationPriority.LOW,
          onlyAlertOnce: true,
          showWhen: false,
        ),
        iosNotificationOptions: const IOSNotificationOptions(),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.repeat(1000),
          autoRunOnBoot: false,
          allowWakeLock: true,
          allowWifiLock: false,
        ),
      );
    }
    await _ensureFln();
  }

  static Future<void> _ensureFln() async {
    if (_flnReady) return;
    try {
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      const windows = WindowsInitializationSettings(
        appName: 'myCoach',
        appUserModelId: 'de.coach.coach_companion',
        guid: 'b3f6d1c2-8a4e-4f2b-9e3a-2c7d5e9f1a60',
      );
      await _fln.initialize(
        settings: const InitializationSettings(
          android: android,
          windows: windows,
        ),
      );
      _flnReady = true;
    } catch (e) {
      debugPrint('FLN init fehlgeschlagen: $e');
    }
  }

  /// Startet die Hintergrund-Uhr für ein Spiel.
  static Future<void> start(MatchClockData d) async {
    _winAlertHalf = false;
    _winAlertFull = false;
    if (Platform.isAndroid) {
      await _requestAndroidPermissions();
      await FlutterForegroundTask.saveData(
        key: _dataKey,
        value: jsonEncode(d.toJson()),
      );
      await FlutterForegroundTask.saveData(key: '${_dataKey}_ah', value: false);
      await FlutterForegroundTask.saveData(key: '${_dataKey}_af', value: false);
      final content = _notificationContent(d);
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.updateService(
          notificationTitle: content.title,
          notificationText: content.text,
        );
      } else {
        await FlutterForegroundTask.startService(
          serviceId: 4711,
          serviceTypes: [ForegroundServiceTypes.dataSync],
          notificationTitle: content.title,
          notificationText: content.text,
          callback: startMatchClockCallback,
        );
      }
    } else {
      await update(d);
    }
  }

  /// Aktualisiert die laufende Uhr (z.B. nach einem Tor oder Phasenwechsel).
  static Future<void> update(MatchClockData d) async {
    if (Platform.isAndroid) {
      await FlutterForegroundTask.saveData(
        key: _dataKey,
        value: jsonEncode(d.toJson()),
      );
      // Der Dienst aktualisiert die Benachrichtigung selbst (jede Sekunde).
      return;
    }
    // Desktop (Windows): Tray-Tooltip + Alarm im UI-Isolate.
    final content = _notificationContent(d);
    desktopTooltip?.call('${content.title}\n${content.text}');
    await _checkDesktopAlert(d);
  }

  /// Beendet die Hintergrund-Uhr (Abpfiff / Reset / Verlassen).
  static Future<void> stop() async {
    _winAlertHalf = false;
    _winAlertFull = false;
    if (Platform.isAndroid) {
      await FlutterForegroundTask.removeData(key: _dataKey);
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
    } else {
      desktopTooltip?.call(null);
    }
  }

  static Future<void> _checkDesktopAlert(MatchClockData d) async {
    if (!d.running) return;
    final sec = d.currentElapsed();
    if (d.half == 1 && !_winAlertHalf && sec >= 45 * 60) {
      _winAlertHalf = true;
      await _showAlert('Halbzeit', '45:00 erreicht');
    } else if (d.half == 2 && !_winAlertFull && sec >= 90 * 60) {
      _winAlertFull = true;
      await _showAlert('90. Minute', 'Reguläre Spielzeit vorbei');
    }
  }

  /// Einmalige Info-Benachrichtigung (z.B. „Live-Spiel läuft").
  static Future<void> showInfo(String title, String body) =>
      _showAlert(title, body);

  static Future<void> _showAlert(String title, String body) async {
    await _ensureFln();
    if (!_flnReady) return;
    try {
      await _fln.show(
        id: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            _alertChannelId,
            'Spielzeit-Hinweise',
            channelDescription: 'Halbzeit- und Abpfiff-Hinweis',
            importance: Importance.high,
            priority: Priority.high,
          ),
          windows: WindowsNotificationDetails(),
        ),
      );
    } catch (e) {
      debugPrint('Alarm fehlgeschlagen: $e');
    }
  }

  static Future<void> _requestAndroidPermissions() async {
    try {
      final perm = await FlutterForegroundTask.checkNotificationPermission();
      if (perm != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
    } catch (e) {
      debugPrint('Benachrichtigungs-Berechtigung: $e');
    }
  }
}

// --------------------------------------------------------------------------
// Hintergrund-Isolate (Android Vordergrund-Dienst)
// --------------------------------------------------------------------------

@pragma('vm:entry-point')
void startMatchClockCallback() {
  FlutterForegroundTask.setTaskHandler(_MatchClockHandler());
}

class _MatchClockHandler extends TaskHandler {
  final FlutterLocalNotificationsPlugin _fln =
      FlutterLocalNotificationsPlugin();
  bool _flnReady = false;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    try {
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      await _fln.initialize(
        settings: const InitializationSettings(android: android),
      );
      _flnReady = true;
    } catch (_) {
      _flnReady = false;
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    _tick();
  }

  Future<void> _tick() async {
    final raw = await FlutterForegroundTask.getData<String>(key: 'match_clock');
    if (raw == null) return;
    MatchClockData? d;
    try {
      d = MatchClockData.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      d = null;
    }
    if (d == null) return;

    final content = _notificationContent(d);
    await FlutterForegroundTask.updateService(
      notificationTitle: content.title,
      notificationText: content.text,
    );

    // Alarm bei 45:00 / 90:00 – jeweils nur einmal.
    if (!d.running) return;
    final sec = d.currentElapsed();
    if (d.half == 1 && sec >= 45 * 60) {
      final already =
          await FlutterForegroundTask.getData<bool>(key: 'match_clock_ah') ??
          false;
      if (!already) {
        await FlutterForegroundTask.saveData(
          key: 'match_clock_ah',
          value: true,
        );
        await _alert('Halbzeit', '45:00 erreicht');
      }
    } else if (d.half == 2 && sec >= 90 * 60) {
      final already =
          await FlutterForegroundTask.getData<bool>(key: 'match_clock_af') ??
          false;
      if (!already) {
        await FlutterForegroundTask.saveData(
          key: 'match_clock_af',
          value: true,
        );
        await _alert('90. Minute', 'Reguläre Spielzeit vorbei');
      }
    }
  }

  Future<void> _alert(String title, String body) async {
    if (!_flnReady) return;
    try {
      await _fln.show(
        id: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'live_match_alert',
            'Spielzeit-Hinweise',
            channelDescription: 'Halbzeit- und Abpfiff-Hinweis',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
      );
    } catch (_) {}
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}
