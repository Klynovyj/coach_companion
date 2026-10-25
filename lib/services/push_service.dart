import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'cloud_service.dart';
import 'live_clock.dart';

/// FCM-Hintergrund-Handler (Top-Level, eigener Isolate). Bei Notification-
/// Nachrichten zeigt Android die Benachrichtigung selbst – hier ist nichts zu
/// tun; die Funktion muss aber existieren und registriert sein.
@pragma('vm:entry-point')
Future<void> _fcmBackgroundHandler(RemoteMessage message) async {}

/// Push-Benachrichtigungen via Firebase Cloud Messaging – nur Android.
/// Auf anderen Plattformen sind alle Methoden No-ops.
class PushService {
  PushService._();
  static bool _ready = false;

  /// Firebase initialisieren + Handler registrieren. Nur Android.
  static Future<void> initPlatform() async {
    if (!Platform.isAndroid) return;
    try {
      await Firebase.initializeApp();
      FirebaseMessaging.onBackgroundMessage(_fcmBackgroundHandler);
      await FirebaseMessaging.instance.requestPermission();
      // Vordergrund: Benachrichtigung selbst anzeigen.
      FirebaseMessaging.onMessage.listen((m) {
        final n = m.notification;
        if (n != null) {
          LiveClock.showInfo(n.title ?? 'myCoach', n.body ?? '');
        }
      });
      _ready = true;
    } catch (e) {
      debugPrint('FCM-Init fehlgeschlagen: $e');
    }
  }

  /// FCM-Token holen und (pro Nutzer) in Supabase hinterlegen. Nach Anmeldung.
  static Future<void> registerToken() async {
    if (!_ready || !CloudService.ready || !CloudService.signedIn) return;
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) await CloudService.upsertDeviceToken(token);
      FirebaseMessaging.instance.onTokenRefresh.listen((t) {
        CloudService.upsertDeviceToken(t).catchError((_) {});
      });
    } catch (e) {
      debugPrint('FCM-Token fehlgeschlagen: $e');
    }
  }
}
