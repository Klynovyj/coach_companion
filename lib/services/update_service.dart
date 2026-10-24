// Auto-Update für die Android-APK (sideloaded, kein Play Store).
//
// Beim Start lädt die App eine kleine version.json (öffentlich auf GitHub).
// Ist dort ein höherer versionCode als der installierte → Dialog mit
// Neuerungen; auf Wunsch wird die neue APK geladen und der Android-Installer
// geöffnet. Nur Android; auf anderen Plattformen passiert nichts.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

class UpdateInfo {
  final int versionCode;
  final String versionName;
  final String apkUrl;
  final String notes;

  const UpdateInfo({
    required this.versionCode,
    required this.versionName,
    required this.apkUrl,
    required this.notes,
  });
}

class UpdateService {
  UpdateService._();

  /// Öffentliche Manifest-Datei (im Repo, raw).
  static const _manifestUrl =
      'https://raw.githubusercontent.com/Klynovyj/coach_companion/master/version.json';

  /// Prüft auf eine neuere Version. Liefert null, wenn aktuell / nicht Android.
  static Future<UpdateInfo?> check() async {
    if (!Platform.isAndroid) return null;
    try {
      final info = await PackageInfo.fromPlatform();
      final currentCode = int.tryParse(info.buildNumber) ?? 0;
      final res = await http
          .get(Uri.parse(_manifestUrl))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      final latest = (j['versionCode'] as num?)?.toInt() ?? 0;
      if (latest <= currentCode) return null;
      final apkUrl = j['apkUrl'] as String?;
      if (apkUrl == null || apkUrl.isEmpty) return null;
      return UpdateInfo(
        versionCode: latest,
        versionName: j['versionName'] as String? ?? '',
        apkUrl: apkUrl,
        notes: j['notes'] as String? ?? '',
      );
    } catch (e) {
      debugPrint('Update-Check fehlgeschlagen: $e');
      return null;
    }
  }

  /// Lädt die APK herunter und öffnet den Installer. Gibt null bei Erfolg,
  /// sonst eine Fehlermeldung zurück. [onProgress] 0..1 (−1 = unbekannt).
  static Future<String?> downloadAndInstall(
    String apkUrl, {
    void Function(double progress)? onProgress,
  }) async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/myCoach-update.apk');
      final client = http.Client();
      final resp = await client.send(http.Request('GET', Uri.parse(apkUrl)));
      if (resp.statusCode != 200) {
        client.close();
        return 'Download fehlgeschlagen (HTTP ${resp.statusCode}).';
      }
      final total = resp.contentLength ?? 0;
      final sink = file.openWrite();
      var received = 0;
      await for (final chunk in resp.stream) {
        received += chunk.length;
        sink.add(chunk);
        if (onProgress != null) {
          onProgress(total > 0 ? received / total : -1);
        }
      }
      await sink.close();
      client.close();

      final result = await OpenFilex.open(
        file.path,
        type: 'application/vnd.android.package-archive',
      );
      if (result.type != ResultType.done) {
        return 'Installer konnte nicht geöffnet werden: ${result.message}';
      }
      return null;
    } catch (e) {
      return 'Fehler beim Update: $e';
    }
  }

  /// Prüft beim Start und zeigt ggf. den Update-Dialog. [silent] = bei „aktuell"
  /// keine Rückmeldung (für den Auto-Check). Bei false kommt ein Hinweis.
  static Future<void> promptIfAvailable(BuildContext context,
      {bool silent = true}) async {
    final info = await check();
    if (!context.mounted) return;
    if (info == null) {
      if (!silent) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('myCoach ist aktuell.')));
      }
      return;
    }
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Update verfügbar${info.versionName.isEmpty ? '' : ' (${info.versionName})'}'),
        content: SingleChildScrollView(
          child: Text(info.notes.isEmpty
              ? 'Eine neuere Version von myCoach ist verfügbar.'
              : info.notes),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Später')),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.system_update),
            label: const Text('Aktualisieren'),
          ),
        ],
      ),
    );
    if (go != true || !context.mounted) return;
    await _runDownload(context, info);
  }

  static Future<void> _runDownload(
      BuildContext context, UpdateInfo info) async {
    final progress = ValueNotifier<double>(-1);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('Update wird geladen …'),
        content: ValueListenableBuilder<double>(
          valueListenable: progress,
          builder: (_, p, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: p < 0 ? null : p),
              const SizedBox(height: 8),
              Text(p < 0 ? 'Bitte warten …' : '${(p * 100).round()} %'),
            ],
          ),
        ),
      ),
    );
    final error = await downloadAndInstall(
      info.apkUrl,
      onProgress: (p) => progress.value = p,
    );
    if (context.mounted) Navigator.of(context).pop(); // Fortschritts-Dialog
    if (error != null && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
    }
    progress.dispose();
  }
}
