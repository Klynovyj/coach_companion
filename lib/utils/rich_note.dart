import 'dart:convert';

import 'package:flutter_quill/flutter_quill.dart';

/// Hilfsfunktionen für formatierte Notizen (flutter_quill / Delta-JSON).
///
/// Gespeichert wird in `PlayerNote.text` entweder ein Delta-JSON-String
/// (neue, formatierte Notizen) oder – aus Altbestand – reiner Text. Beide
/// Fälle werden hier transparent behandelt.
class RichNote {
  const RichNote._();

  /// Baut aus dem gespeicherten Wert ein Quill-Dokument. Fällt bei reinem
  /// Text (Altbestand) auf ein einfaches Dokument zurück.
  static Document documentFrom(String? stored) {
    final raw = stored ?? '';
    if (raw.trim().isEmpty) return Document();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return Document.fromJson(decoded);
    } catch (_) {
      // Kein JSON -> als Klartext behandeln.
    }
    final doc = Document();
    doc.insert(0, raw);
    return doc;
  }

  /// Serialisiert ein Quill-Dokument als Delta-JSON-String für die DB.
  static String encode(Document doc) => jsonEncode(doc.toDelta().toJson());

  /// Reiner Text (für Vorschauen, Suche oder WhatsApp-Teilen).
  static String plainText(String? stored) =>
      documentFrom(stored).toPlainText().trim();

  /// true, wenn der gespeicherte Wert keinen sichtbaren Inhalt hat.
  static bool isEmpty(String? stored) => plainText(stored).isEmpty;
}
