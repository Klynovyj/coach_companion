import 'dart:convert';
import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/prep_plan.dart';

/// Übernahme der Vorbereitungspläne aus der Coach-Studio-Desktop-App
/// (lokale SQLite-Datenbank unter %APPDATA%\studio.coach.app). Nur Windows.
class StudioPlanImport {
  const StudioPlanImport._();

  static String? get _dbPath {
    if (!Platform.isWindows) return null;
    final appData = Platform.environment['APPDATA'];
    if (appData == null) return null;
    return '$appData\\studio.coach.app\\coach_studio.db';
  }

  /// true, wenn auf diesem PC eine Coach-Studio-Datenbank liegt.
  static bool get available {
    final p = _dbPath;
    return p != null && File(p).existsSync();
  }

  /// Liest alle Pläne (nur lesend). Extra-Texte kommen im Studio als HTML –
  /// sie werden als Klartext übernommen (Zeilenumbrüche/Listen bleiben).
  static Future<List<PrepPlan>> readPlans() async {
    final path = _dbPath;
    if (path == null || !File(path).existsSync()) return const [];
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    try {
      final rows = await db.query('plans');
      final out = <PrepPlan>[];
      for (final r in rows) {
        List<dynamic> entries = const [];
        try {
          final e = jsonDecode((r['entries'] as String?) ?? '[]');
          if (e is List) entries = e;
        } catch (_) {}
        final hint = htmlToPlain(r['hint'] as String?);
        final footer = htmlToPlain(r['footer_text'] as String?);
        final sub = (r['subtitle'] as String?)?.trim();
        out.add(
          PrepPlan(
            id: r['id'] as String,
            title: ((r['title'] as String?)?.trim().isNotEmpty ?? false)
                ? (r['title'] as String).trim()
                : 'Vorbereitungsplan',
            subtitle: (sub == null || sub.isEmpty) ? null : sub,
            hint: hint.isEmpty ? null : hint,
            footerText: footer.isEmpty ? null : footer,
            entries: [
              for (final e in entries)
                if (e is Map) PrepPlanEntry.fromJson(Map<String, dynamic>.from(e)),
            ],
            createdAt: r['created_at'] as String?,
          ),
        );
      }
      return out;
    } finally {
      await db.close();
    }
  }

  /// Einfaches HTML → Klartext (wie der WhatsApp-Export im Studio).
  static String htmlToPlain(String? html) {
    if (html == null) return '';
    var s = html;
    s = s.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
    s = s.replaceAll(RegExp(r'</p>\s*<p[^>]*>', caseSensitive: false), '\n');
    s = s.replaceAll(RegExp(r'</?(p|div)[^>]*>', caseSensitive: false), '\n');
    s = s.replaceAll(RegExp(r'<li[^>]*>', caseSensitive: false), '• ');
    s = s.replaceAll(RegExp(r'</li>', caseSensitive: false), '\n');
    s = s.replaceAll(RegExp(r'<[^>]+>'), '');
    s = s
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");
    return s.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }
}
