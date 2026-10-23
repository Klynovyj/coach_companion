// Parser für eingefügte Kaderlisten.
//
// Übersetzt vom Trainer kopierten Text (z.B. aus der öffentlich sichtbaren
// FuPa-Mannschaftsseite) in Spieler-Vorschläge. Die App ruft dabei nichts von
// FuPa ab – sie interpretiert ausschließlich den Text, den der Nutzer einfügt.

/// Ein aus einer Textzeile oder FuPa-Seite erkannter Spieler-Vorschlag.
class ParsedPlayer {
  final int? number;
  final String firstName;
  final String lastName;
  final String? position;

  /// Externe FuPa-ID/Slug (für stabile Duplikaterkennung), falls vorhanden.
  final String? externalId;

  /// Basis-URL des Spielerfotos (ohne Größen-Suffix), falls vorhanden.
  final String? photoUrl;

  const ParsedPlayer({
    this.number,
    this.firstName = '',
    this.lastName = '',
    this.position,
    this.externalId,
    this.photoUrl,
  });

  bool get needsName => firstName.isEmpty && lastName.isEmpty;

  String get fullName =>
      [firstName, lastName].where((s) => s.isNotEmpty).join(' ');
}

class SquadPasteParser {
  // Erkennt gängige Positionsbezeichnungen und bildet sie auf eine
  // normalisierte deutsche Kategorie ab.
  static final List<MapEntry<RegExp, String>> _positions = [
    MapEntry(RegExp(r'\b(torwart|torhüter|keeper|tw|goalie|tor)\b', caseSensitive: false), 'Tor'),
    MapEntry(RegExp(r'\b(abwehr|verteidig\w*|innenverteidiger|iv|lv|rv|lib)\b', caseSensitive: false), 'Abwehr'),
    MapEntry(RegExp(r'\b(mittelfeld\w*|zm|dm|om|zdm|zom|ms6|sechser|achter|zehner)\b', caseSensitive: false), 'Mittelfeld'),
    MapEntry(RegExp(r'\b(sturm|stürmer|angriff|angreifer|st|ms|mittelstürmer|neuner)\b', caseSensitive: false), 'Sturm'),
  ];

  static final _urlRegExp =
      RegExp(r'https?:\/\/\S+', caseSensitive: false);
  static final _parenRegExp = RegExp(r'\(.*?\)');
  static final _leadingNumber = RegExp(r'^\s*(\d{1,2})\s*[.)\-:]?\s+');
  static final _nrNumber = RegExp(r'\bnr\.?\s*(\d{1,2})\b', caseSensitive: false);

  /// Zerlegt den eingefügten Text in Spieler-Vorschläge (eine Zeile = ein
  /// Spieler). Leere Zeilen und reine Nummern-/Link-Zeilen werden übersprungen.
  static List<ParsedPlayer> parse(String input) {
    final result = <ParsedPlayer>[];
    for (final rawLine in input.split(RegExp(r'[\r\n]+'))) {
      final parsed = _parseLine(rawLine);
      if (parsed != null) result.add(parsed);
    }
    return result;
  }

  static ParsedPlayer? _parseLine(String raw) {
    var line = raw.trim();
    if (line.isEmpty) return null;

    // Links und Klammer-Zusätze (z.B. "(12 Spiele)") entfernen.
    line = line.replaceAll(_urlRegExp, ' ');
    line = line.replaceAll(_parenRegExp, ' ');
    // Führende Aufzählungszeichen entfernen.
    line = line.replaceAll(RegExp(r'^[\s•\-\*•]+'), ' ').trim();
    if (line.isEmpty) return null;

    int? number;
    final lead = _leadingNumber.firstMatch(line);
    if (lead != null) {
      number = int.tryParse(lead.group(1)!);
      line = line.substring(lead.end).trim();
    } else {
      final nr = _nrNumber.firstMatch(line);
      if (nr != null) {
        number = int.tryParse(nr.group(1)!);
        line = line.replaceRange(nr.start, nr.end, ' ').trim();
      }
    }

    String? position;
    for (final entry in _positions) {
      if (entry.key.hasMatch(line)) {
        position = entry.value;
        line = line.replaceAll(entry.key, ' ').trim();
        break;
      }
    }

    // Verbleibende Tokens: alles mit Buchstaben ist Teil des Namens.
    final tokens = line
        .split(RegExp(r'[\s,;|/\\]+'))
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .where((t) => RegExp(r'[A-Za-zÀ-ÿ]').hasMatch(t))
        .toList();

    if (tokens.isEmpty) {
      // Keine Namensbestandteile (reine Nummer/Link) -> überspringen.
      return null;
    }

    String firstName;
    String lastName;
    if (tokens.length == 1) {
      firstName = '';
      lastName = tokens.first;
    } else {
      lastName = tokens.last;
      firstName = tokens.sublist(0, tokens.length - 1).join(' ');
    }

    return ParsedPlayer(
      number: number,
      firstName: firstName,
      lastName: lastName,
      position: position,
    );
  }
}
