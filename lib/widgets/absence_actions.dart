import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../models/enums.dart';
import '../models/player.dart';
import '../models/player_absence.dart';
import '../state/app_state.dart';
import 'injury_icon.dart';

/// Symbol je Abwesenheits-/Status-Grund: „Verletzt" bekommt das rote Kreuz
/// (`InjuryCross`), alle anderen ihr Emoji. Einheitlich für alle Abwesenheits-
/// Ansichten.
Widget absenceReasonIcon(PlayerStatus s, {double size = 18}) =>
    s == PlayerStatus.verletzt
    ? InjuryCross(size: size)
    : Text(s.symbol, style: TextStyle(fontSize: size));

/// Gemeinsame Abwesenheits-Eingabe (Grund-Auswahl + Datums-Dialog), damit sie
/// sowohl im Spielerprofil als auch in der zentralen Abwesenheits-Übersicht
/// genutzt werden kann.

/// Datums-Eingabe TT.MM.JJJJ – fügt die Punkte automatisch ein.
class DateInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    var digits = newValue.text.replaceAll(RegExp(r'\D'), '');
    if (digits.length > 8) digits = digits.substring(0, 8);
    final b = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i == 2 || i == 4) b.write('.');
      b.write(digits[i]);
    }
    final text = b.toString();
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}

/// Parst „TT.MM.JJJJ" zu einem Datum; null bei ungültiger Eingabe.
DateTime? parseDmy(String s) {
  final m = RegExp(r'^(\d{1,2})\.(\d{1,2})\.(\d{4})$').firstMatch(s.trim());
  if (m == null) return null;
  final d = int.parse(m.group(1)!);
  final mo = int.parse(m.group(2)!);
  final y = int.parse(m.group(3)!);
  if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
  final dt = DateTime(y, mo, d);
  if (dt.day != d || dt.month != mo) return null; // z.B. 31.02 abfangen
  return dt;
}

/// Grund-Auswahl (Krank/Verletzt/Gesperrt/Urlaub/Abwesend) als Sheet.
Future<PlayerStatus?> pickAbsenceReason(BuildContext context) {
  return showModalBottomSheet<PlayerStatus>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Abwesenheit – Grund wählen',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ),
          ),
          for (final s in PlayerStatus.absenceOnlyReasons)
            ListTile(
              leading: absenceReasonIcon(s, size: 20),
              title: Text(s.label),
              onTap: () => Navigator.pop(ctx, s),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

/// Dialog für Zeitraum (von–bis) + optionalen Grund-Freitext einer Abwesenheit.
Future<(DateTime, DateTime, String?)?> showAbsenceDateDialog(
  BuildContext context, {
  required PlayerStatus reason,
  DateTime? initialFrom,
  DateTime? initialUntil,
  String? initialNote,
}) async {
  final df = DateFormat('dd.MM.yyyy', 'de_DE');
  final from = initialFrom ?? DateTime.now();
  final until = initialUntil ?? DateTime.now().add(const Duration(days: 7));
  final fromCtrl = TextEditingController(text: df.format(from));
  final untilCtrl = TextEditingController(text: df.format(until));
  final noteCtrl = TextEditingController(text: initialNote ?? '');

  return showDialog<(DateTime, DateTime, String?)>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setLocal) {
        Widget dateField(
          String label,
          IconData icon,
          TextEditingController ctrl,
        ) {
          return TextField(
            controller: ctrl,
            keyboardType: TextInputType.number,
            inputFormatters: [DateInputFormatter()],
            decoration: InputDecoration(
              labelText: label,
              hintText: 'TT.MM.JJJJ',
              border: const OutlineInputBorder(),
              isDense: true,
              prefixIcon: Icon(icon, size: 18),
              suffixIcon: IconButton(
                icon: const Icon(Icons.calendar_month),
                tooltip: 'Kalender',
                onPressed: () async {
                  final base = parseDmy(ctrl.text) ?? DateTime.now();
                  final d = await showDatePicker(
                    context: context,
                    initialDate: base,
                    firstDate: DateTime(base.year - 2),
                    lastDate: DateTime(base.year + 3),
                  );
                  if (d != null) setLocal(() => ctrl.text = df.format(d));
                },
              ),
            ),
          );
        }

        return AlertDialog(
          title: Text('${reason.symbol} ${reason.label}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              dateField('Von', Icons.event, fromCtrl),
              const SizedBox(height: 10),
              dateField('Bis', Icons.event_available, untilCtrl),
              const SizedBox(height: 10),
              TextField(
                controller: noteCtrl,
                decoration: const InputDecoration(
                  labelText: 'Grund (optional)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () {
                final f = parseDmy(fromCtrl.text);
                final u = parseDmy(untilCtrl.text);
                final messenger = ScaffoldMessenger.of(context);
                if (f == null || u == null) {
                  messenger.showSnackBar(
                    const SnackBar(
                      content: Text('Bitte Datum als TT.MM.JJJJ eingeben.'),
                    ),
                  );
                  return;
                }
                if (u.isBefore(f)) {
                  messenger.showSnackBar(
                    const SnackBar(
                      content: Text('„Bis" darf nicht vor „Von" liegen.'),
                    ),
                  );
                  return;
                }
                Navigator.pop(context, (
                  f,
                  u,
                  noteCtrl.text.trim().isEmpty ? null : noteCtrl.text.trim(),
                ));
              },
              child: const Text('Speichern'),
            ),
          ],
        );
      },
    ),
  );
}

/// Status aus dem Status-Menü setzen: Fit/Inaktiv → Grundstatus (ohne Datum);
/// Krank/Verletzt → befristete Abwesenheit (Zeitraum-Dialog). Gibt true zurück,
/// wenn etwas geändert wurde.
Future<bool> setStatusFlow(
  BuildContext context,
  AppState state,
  Player player,
  PlayerStatus chosen,
) async {
  if (chosen == PlayerStatus.fit || chosen == PlayerStatus.inaktiv) {
    await state.setBaseStatus(player, chosen);
    return true;
  }
  // Krank/Verletzt: wie eine Abwesenheit mit Zeitraum.
  final res = await showAbsenceDateDialog(context, reason: chosen);
  if (res == null) return false;
  await state.addAbsence(
    player: player,
    status: chosen,
    from: res.$1,
    until: res.$2,
    note: res.$3,
  );
  return true;
}

/// Vollständiger Ablauf „Abwesenheit eintragen": Grund wählen → Zeitraum →
/// speichern. Gibt true zurück, wenn eine Abwesenheit angelegt wurde.
Future<bool> addAbsenceFlow(
  BuildContext context,
  AppState state,
  Player player,
) async {
  final reason = await pickAbsenceReason(context);
  if (reason == null || !context.mounted) return false;
  final res = await showAbsenceDateDialog(context, reason: reason);
  if (res == null) return false;
  await state.addAbsence(
    player: player,
    status: reason,
    from: res.$1,
    until: res.$2,
    note: res.$3,
  );
  return true;
}

/// Vorhandene Abwesenheit bearbeiten (Zeitraum/Grund-Freitext anpassen).
Future<bool> editAbsenceFlow(
  BuildContext context,
  AppState state,
  PlayerAbsence a,
) async {
  final res = await showAbsenceDateDialog(
    context,
    reason: a.status,
    initialFrom: a.from,
    initialUntil: a.until,
    initialNote: a.note,
  );
  if (res == null) return false;
  await state.updateAbsence(
    PlayerAbsence(
      id: a.id,
      playerId: a.playerId,
      status: a.status,
      from: res.$1,
      until: res.$2,
      note: res.$3,
      createdAt: a.createdAt,
    ),
  );
  return true;
}
