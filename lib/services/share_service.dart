import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/enums.dart';
import '../models/match.dart';
import '../models/match_event.dart';
import '../models/player.dart';
import '../models/team.dart';
import '../models/team_event.dart';
import 'package:intl/intl.dart';

/// Öffnet WhatsApp mit vorausgefülltem Text. Der Nutzer wählt selbst den
/// Empfänger und sendet die Nachricht in WhatsApp – es wird nichts automatisch
/// versendet.
Future<bool> shareViaWhatsApp(String text) async {
  final uri = Uri.parse('https://wa.me/?text=${Uri.encodeComponent(text)}');
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// Teilt ein Bild (z.B. die Aufstellung). Auf dem Handy (Android/iOS) über das
/// System-Teilen-Menü, in dem WhatsApp & Co. erscheinen. Auf dem Desktop
/// (Windows) gibt es dafür kein zuverlässiges System-Teilen für Dateien –
/// dort wird das Bild in den Downloads-Ordner gespeichert und direkt mit dem
/// Standard-Bildbetrachter geöffnet, sodass es z.B. in WhatsApp angehängt
/// werden kann. Gibt den Speicherpfad zurück, wenn gespeichert wurde
/// (Desktop), sonst null (mobil geteilt).
Future<String?> shareOrSaveImage(
  Uint8List bytes,
  String baseName, {
  String? text,
}) async {
  final safe = baseName.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  if (Platform.isAndroid || Platform.isIOS) {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$safe.png');
    await file.writeAsBytes(bytes);
    await SharePlus.instance
        .share(ShareParams(files: [XFile(file.path)], text: text));
    return null;
  }
  // Desktop: in den Downloads-Ordner speichern und direkt öffnen.
  final dir =
      await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
  final stamp = DateFormat('yyyyMMdd_HHmm').format(DateTime.now());
  final file = File('${dir.path}/${safe}_$stamp.png');
  await file.writeAsBytes(bytes);
  // Öffnen ist optional – die Datei ist gespeichert, auch wenn kein Viewer startet.
  try {
    await launchUrl(
      Uri.file(file.path, windows: Platform.isWindows),
      mode: LaunchMode.externalApplication,
    );
  } catch (_) {
    // ignorieren – Pfad wird dem Nutzer ohnehin angezeigt.
  }
  return file.path;
}

/// Baut den Spielbericht-Text: Kopf (Ergebnis/Infos) + VOLLSTÄNDIGER Ticker –
/// alle Ereignisse chronologisch, so wie sie in der App stehen (Tore, Karten,
/// Wechsel, Ecken/Freistöße/Elfmeter/Fouls, Kommentare und die Spielphasen).
String buildMatchReport({
  required GameMatch match,
  required String ownName,
  required String oppName,
  required List<MatchEvent> events,
  required String Function(String?) resolveName,
}) {
  final df = DateFormat('dd.MM.yyyy', 'de_DE');
  final b = StringBuffer();
  b.writeln('Spielbericht');
  b.writeln('$ownName ${match.ownScore}:${match.opponentScore} $oppName');
  b.writeln('${match.venue.label}'
      '${match.kickoff != null ? ' · ${df.format(match.kickoff!.toLocal())}' : ''}'
      '${match.competition != null ? ' · ${match.competition}' : ''}');

  // Chronologisch: Minute, dann Nachspielzeit, dann Erfassungszeitpunkt.
  final sorted = [...events]..sort((a, c) {
      final m = a.minute.compareTo(c.minute);
      if (m != 0) return m;
      final me = a.minuteExtra.compareTo(c.minuteExtra);
      if (me != 0) return me;
      return a.createdAt.compareTo(c.createdAt);
    });

  String teamOf(MatchEvent e) =>
      e.teamId == match.ownTeamId ? ownName : oppName;

  if (sorted.isNotEmpty) {
    b.writeln('\nTicker:');
    for (final e in sorted) {
      b.writeln(_tickerLine(e, match, ownName, oppName, teamOf, resolveName));
    }
  }
  return b.toString().trim();
}

/// Formatiert EIN Ereignis als Ticker-Zeile.
String _tickerLine(
  MatchEvent e,
  GameMatch match,
  String ownName,
  String oppName,
  String Function(MatchEvent) teamOf,
  String Function(String?) resolveName,
) {
  final min = e.minuteLabel; // enthält bereits das '
  final sym = e.type.symbol;
  final note =
      (e.note != null && e.note!.trim().isNotEmpty) ? ' – ${e.note!.trim()}' : '';
  switch (e.type) {
    case MatchEventType.goal:
    case MatchEventType.penalty:
      final assist = e.assistPlayerId != null
          ? ' (Vorlage: ${resolveName(e.assistPlayerId)})'
          : '';
      final pen = e.type == MatchEventType.penalty ? ' [Elfmeter]' : '';
      return '$min $sym Tor ${teamOf(e)} – ${resolveName(e.playerId)}$assist$pen';
    case MatchEventType.ownGoal:
      return '$min $sym Eigentor (${teamOf(e)}) – ${resolveName(e.playerId)}';
    case MatchEventType.yellowCard:
    case MatchEventType.secondYellow:
    case MatchEventType.redCard:
      return '$min $sym ${e.type.label}: ${resolveName(e.playerId)} (${teamOf(e)})';
    case MatchEventType.substitution:
      return '$min $sym Wechsel ${teamOf(e)}: '
          '${resolveName(e.playerId)} für ${resolveName(e.assistPlayerId)}';
    case MatchEventType.comment:
      return '$min $sym Kommentar${note.isEmpty ? '' : ': ${e.note!.trim()}'}';
    case MatchEventType.penaltyMissed:
    case MatchEventType.penaltySaved:
    case MatchEventType.soGoal:
    case MatchEventType.soMiss:
      final pl = e.playerId != null ? ' – ${resolveName(e.playerId)}' : '';
      return '$min $sym ${e.type.label} (${teamOf(e)})$pl';
    default:
      // Spielphasen (Anpfiff/Halbzeit/Abpfiff …) sind team-neutral.
      if (e.type.isPhaseMarker) return '$min $sym ${e.type.label}';
      // Ecke/Freistoß/Foul/Großchance/Meckern.
      final pl = e.playerId != null ? ' – ${resolveName(e.playerId)}' : '';
      return '$min $sym ${e.type.label} (${teamOf(e)})$pl$note';
  }
}

/// Teilt reinen Text. Auf dem Handy über das System-Teilen-Menü (WhatsApp &
/// Co. erscheinen) – ohne Längenlimit, sodass auch ein langer Ticker komplett
/// ankommt. Auf dem Desktop über den wa.me-Link als Rückfall.
Future<bool> shareText(String text) async {
  if (Platform.isAndroid || Platform.isIOS) {
    await SharePlus.instance.share(ShareParams(text: text));
    return true;
  }
  return shareViaWhatsApp(text);
}

/// Baut den Nominierungs-Text (gruppiert nach Status).
String buildNominationText({
  required String title,
  DateTime? kickoff,
  required List<Player> players,
  required Map<String, NominationStatus> status,
}) {
  final df = DateFormat('dd.MM.yyyy', 'de_DE');
  final b = StringBuffer();
  b.writeln('Nominierung – $title'
      '${kickoff != null ? ' (${df.format(kickoff)})' : ''}');

  void group(NominationStatus s, String label) {
    final names = players
        .where((p) => (status[p.id] ?? NominationStatus.open) == s)
        .map((p) => p.fullName)
        .toList();
    if (names.isNotEmpty) {
      b.writeln('\n$label (${names.length}):');
      b.writeln(names.join(', '));
    }
  }

  group(NominationStatus.zugesagt, 'Zugesagt');
  group(NominationStatus.unsicher, 'Unsicher');
  group(NominationStatus.unterVorbehalt, 'Unter Vorbehalt');
  group(NominationStatus.abgesagt, 'Abgesagt');
  group(NominationStatus.open, 'Offen');
  return b.toString().trim();
}

/// Baut den Termin-Text (inkl. Zu-/Absagen).
String buildEventText({
  required TeamEvent event,
  required List<Player> players,
  required Map<String, NominationStatus> status,
}) {
  final df = DateFormat('EEEE, dd.MM.yyyy • HH:mm', 'de_DE');
  final b = StringBuffer();
  b.writeln('${event.type.label} – ${event.title}');
  b.writeln(df.format(event.date));
  if (event.location != null) b.writeln('Ort: ${event.location}');
  if (event.note != null && event.note!.isNotEmpty) b.writeln(event.note);

  void group(NominationStatus s, String label) {
    final names = players
        .where((p) => (status[p.id] ?? NominationStatus.open) == s)
        .map((p) => p.fullName)
        .toList();
    if (names.isNotEmpty) {
      b.writeln('\n$label (${names.length}):');
      b.writeln(names.join(', '));
    }
  }

  group(NominationStatus.zugesagt, 'Zugesagt');
  group(NominationStatus.unsicher, 'Unsicher');
  group(NominationStatus.unterVorbehalt, 'Unter Vorbehalt');
  group(NominationStatus.abgesagt, 'Abgesagt');
  return b.toString().trim();
}

/// Team für Berichts-Namen (Kurzname bevorzugt).
String teamDisplay(Team? team, String fallback) =>
    team?.shortName ?? team?.name ?? fallback;
