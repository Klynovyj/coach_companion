import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:window_manager/window_manager.dart';

import 'screens/home_screen.dart';
import 'services/cloud_service.dart';
import 'services/desktop_tray.dart';
import 'services/live_clock.dart';
import 'services/push_service.dart';
import 'state/app_state.dart';
import 'supabase_config.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('de_DE');

  // Fenster auf Windows: Schließen minimiert in den Tray, damit die Live-Uhr
  // im Hintergrund weiterläuft.
  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(null, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  // Supabase (Mehrbenutzer/Cloud) – scheitert nie den App-Start.
  if (SupabaseConfig.isConfigured) {
    try {
      await Supabase.initialize(
        url: SupabaseConfig.url,
        // Anon-JWT („public" Key); publishableKey wäre das neue Format.
        // ignore: deprecated_member_use
        anonKey: SupabaseConfig.anonKey,
      );
      CloudService.ready = true;
    } catch (e) {
      debugPrint('Supabase-Init fehlgeschlagen: $e');
    }
  }

  // Hintergrund-Uhr (Android: Vordergrund-Dienst, Benachrichtigungen).
  await LiveClock.initPlatform();

  // Push-Benachrichtigungen (FCM) – nur Android.
  await PushService.initPlatform();

  final appState = AppState();
  await appState.init();

  // FCM-Token registrieren (wenn angemeldet; sonst No-op).
  PushService.registerToken();

  // Tray erst nach dem ersten Frame einrichten (braucht die Engine).
  if (Platform.isWindows) {
    await DesktopTray.instance.init();
  }

  runApp(
    ChangeNotifierProvider.value(
      value: appState,
      child: const CoachCompanionApp(),
    ),
  );
}

class CoachCompanionApp extends StatelessWidget {
  const CoachCompanionApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'myCoach',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      // Lokalisierung (u.a. für den Rich-Text-Editor flutter_quill).
      locale: const Locale('de'),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        FlutterQuillLocalizations.delegate,
      ],
      supportedLocales: const [Locale('de'), Locale('en')],
      home: const HomeScreen(),
    );
  }
}
