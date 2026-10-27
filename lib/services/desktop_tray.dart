// Windows-Infobereich (Tray): Fenster-Schließen beendet die App nicht mehr,
// sondern minimiert sie in den Tray – so läuft die Live-Uhr im versteckten
// Fenster weiter. Über das Tray-Icon/-Menü wird die App wieder geöffnet oder
// endgültig beendet.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'live_clock.dart';

class DesktopTray with WindowListener, TrayListener {
  DesktopTray._();
  static final DesktopTray instance = DesktopTray._();

  static const _baseTooltip = 'myCoach';
  bool _ready = false;

  /// Nur auf Windows einrichten. Erwartet, dass windowManager bereits
  /// initialisiert ist (siehe main.dart).
  Future<void> init() async {
    if (!Platform.isWindows) return;
    windowManager.addListener(this);
    trayManager.addListener(this);
    await windowManager.setPreventClose(true);
    try {
      await trayManager.setIcon('assets/icon/tray_icon.ico');
      await trayManager.setToolTip(_baseTooltip);
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'show', label: 'myCoach öffnen'),
            MenuItem.separator(),
            MenuItem(key: 'exit', label: 'Beenden'),
          ],
        ),
      );
      _ready = true;
    } catch (e) {
      debugPrint('Tray-Einrichtung fehlgeschlagen: $e');
    }
    // Live-Uhr darf den Tray-Tooltip setzen.
    LiveClock.desktopTooltip = _setTooltip;
  }

  void _setTooltip(String? text) {
    if (!_ready) return;
    trayManager.setToolTip(
      (text == null || text.isEmpty) ? _baseTooltip : text,
    );
  }

  Future<void> _restore() async {
    await windowManager.setSkipTaskbar(false);
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _quit() async {
    await windowManager.setPreventClose(false);
    try {
      await trayManager.destroy();
    } catch (_) {}
    await windowManager.destroy();
  }

  // --- WindowListener ---
  @override
  void onWindowClose() async {
    // Statt zu beenden: in den Tray minimieren.
    if (await windowManager.isPreventClose()) {
      await windowManager.hide();
      await windowManager.setSkipTaskbar(true);
    }
  }

  // --- TrayListener ---
  @override
  void onTrayIconMouseDown() => _restore();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        _restore();
        break;
      case 'exit':
        _quit();
        break;
    }
  }
}
