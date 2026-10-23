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

/// Baut den Spielbericht-Text (Ergebnis, Tore, Karten, Wechsel).
String buildMatchReport({
  required GameMatch match,
  required String ownName,
  required String oppName,
  required List<MatchEvent> events,
  required String Function(String?) resolveName,
}) {
  final df = DateFormat('dd.MM.yyyy', 'de_DE');
  final b = StringBuffer();
  b.writeln('⚽ Spielbericht');
  b.writeln('$ownName ${match.ownScore}:${match.opponentScore} $oppName');
  b.writeln('${match.venue.label}'
      '${match.kickoff != null ? ' · ${df.format(match.kickoff!)}' : ''}'
      '${match.competition != null ? ' · ${match.competition}' : ''}');

  final sorted = [...events]..sort((a, b) => a.minute.compareTo(b.minute));
  final goals = sorted.where((e) => e.type == MatchEventType.goal).toList();
  final cards = sorted
      .where((e) =>
          e.type == MatchEventType.yellowCard ||
          e.type == MatchEventType.secondYellow ||
          e.type == MatchEventType.redCard)
      .toList();
  final subs =
      sorted.where((e) => e.type == MatchEventType.substitution).toList();

  if (goals.isNotEmpty) {
    b.writeln('\nTore:');
    for (final e in goals) {
      final assist = e.assistPlayerId != null
          ? ' (Vorlage: ${resolveName(e.assistPlayerId)})'
          : '';
      b.writeln("${e.minute}' ⚽ ${resolveName(e.playerId)}$assist");
    }
  }
  if (cards.isNotEmpty) {
    b.writeln('\nKarten:');
    for (final e in cards) {
      b.writeln("${e.minute}' ${e.type.symbol} ${resolveName(e.playerId)}");
    }
  }
  if (subs.isNotEmpty) {
    b.writeln('\nWechsel:');
    for (final e in subs) {
      b.writeln(
          "${e.minute}' 🔁 ${resolveName(e.playerId)} für ${resolveName(e.assistPlayerId)}");
    }
  }
  return b.toString().trim();
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
  b.writeln('📋 Nominierung – $title'
      '${kickoff != null ? ' (${df.format(kickoff)})' : ''}');

  void group(NominationStatus s, String emoji, String label) {
    final names = players
        .where((p) => (status[p.id] ?? NominationStatus.open) == s)
        .map((p) => p.fullName)
        .toList();
    if (names.isNotEmpty) {
      b.writeln('\n$emoji $label (${names.length}):');
      b.writeln(names.join(', '));
    }
  }

  group(NominationStatus.zugesagt, '✅', 'Zugesagt');
  group(NominationStatus.unsicher, '❓', 'Unsicher');
  group(NominationStatus.abgesagt, '❌', 'Abgesagt');
  group(NominationStatus.open, '⬜', 'Offen');
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
  b.writeln('${event.type.symbol} ${event.title}');
  b.writeln(df.format(event.date));
  if (event.location != null) b.writeln('📍 ${event.location}');
  if (event.note != null && event.note!.isNotEmpty) b.writeln(event.note);

  void group(NominationStatus s, String emoji, String label) {
    final names = players
        .where((p) => (status[p.id] ?? NominationStatus.open) == s)
        .map((p) => p.fullName)
        .toList();
    if (names.isNotEmpty) {
      b.writeln('\n$emoji $label (${names.length}):');
      b.writeln(names.join(', '));
    }
  }

  group(NominationStatus.zugesagt, '✅', 'Zugesagt');
  group(NominationStatus.unsicher, '❓', 'Unsicher');
  group(NominationStatus.abgesagt, '❌', 'Abgesagt');
  return b.toString().trim();
}

/// Team für Berichts-Namen (Kurzname bevorzugt).
String teamDisplay(Team? team, String fallback) =>
    team?.shortName ?? team?.name ?? fallback;
