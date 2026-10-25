// Geplante lokale Geburtstags-Benachrichtigungen.
//
// Für jede Person mit hinterlegtem Geburtsdatum wird eine Benachrichtigung um
// 8:00 Uhr am Geburtstag geplant (jährlich wiederkehrend). Wird beim App-Start
// und nach jedem Kader-Sync neu gesetzt, damit Änderungen übernommen werden.
//
// Nur Android: geplante Benachrichtigungen (`zonedSchedule`) laufen auch bei
// geschlossener App und überstehen dank Boot-Empfänger einen Neustart. Auf
// Windows/Desktop unterstützt das Plugin keine Planung → dort ein No-op.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../models/player.dart';

class BirthdayNotifications {
  BirthdayNotifications._();

  static final FlutterLocalNotificationsPlugin _fln =
      FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  static const _channelId = 'birthdays';
  // Fester ID-Bereich, damit wir alte Geburtstags-Benachrichtigungen gezielt
  // ersetzen können, ohne andere (Live-)Benachrichtigungen zu treffen.
  static const _idBase = 920000;
  static const _maxPeople = 200;

  static Future<void> _ensure() async {
    if (_ready) return;
    try {
      tzdata.initializeTimeZones();
      // Deutscher Verein – feste lokale Zeitzone.
      tz.setLocalLocation(tz.getLocation('Europe/Berlin'));
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      await _fln.initialize(
        settings: const InitializationSettings(android: android),
      );
      _ready = true;
    } catch (e) {
      debugPrint('Geburtstags-Benachrichtigungen init: $e');
    }
  }

  /// Plant die Geburtstage aller übergebenen Personen neu (ersetzt die alten).
  static Future<void> reschedule(List<Player> people) async {
    if (!Platform.isAndroid) return;
    await _ensure();
    if (!_ready) return;

    // Alte Geburtstags-Benachrichtigungen im festen ID-Bereich entfernen.
    for (var i = 0; i < _maxPeople; i++) {
      try {
        await _fln.cancel(id: _idBase + i);
      } catch (_) {}
    }

    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        'Geburtstage',
        channelDescription: 'Erinnerung an Geburtstage im Team',
        importance: Importance.high,
        priority: Priority.high,
      ),
    );

    final now = tz.TZDateTime.now(tz.local);
    var idx = 0;
    for (final p in people) {
      final bd = p.birthdate;
      if (bd == null) continue;
      if (idx >= _maxPeople) break;
      final when = _next8am(now, bd);
      final age = when.year - bd.year;
      final name = p.shortOrFullName;
      final body = age > 0
          ? '$name wird heute $age 🎉'
          : '$name hat heute Geburtstag 🎉';
      try {
        await _fln.zonedSchedule(
          id: _idBase + idx,
          title: '🎂 Geburtstag',
          body: body,
          scheduledDate: when,
          notificationDetails: details,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          // Jährlich wiederkehrend (Monat+Tag+Uhrzeit).
          matchDateTimeComponents: DateTimeComponents.dateAndTime,
        );
        idx++;
      } catch (e) {
        debugPrint('Geburtstag planen fehlgeschlagen: $e');
      }
    }
  }

  /// Nächster 8:00-Termin am Geburtstag (dieses Jahr, sonst nächstes Jahr).
  static tz.TZDateTime _next8am(tz.TZDateTime now, DateTime birthdate) {
    var when =
        tz.TZDateTime(tz.local, now.year, birthdate.month, birthdate.day, 8);
    if (!when.isAfter(now)) {
      when = tz.TZDateTime(
          tz.local, now.year + 1, birthdate.month, birthdate.day, 8);
    }
    return when;
  }
}
