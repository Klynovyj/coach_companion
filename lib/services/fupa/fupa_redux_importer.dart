import 'dart:convert';

import 'package:http/http.dart' as http;

import '../paste/squad_paste_parser.dart';

/// Importiert Spielerstammdaten von einer öffentlichen FuPa-Spielerseite –
/// portiert aus Coach Studio (`modules/players/fupaImport.ts`).
///
/// Strategie (kein HTML-Scraping): FuPa-Seiten enthalten einen
/// `window.REDUX_DATA = {…}`-Block mit vollständig strukturierten Daten unter
/// `dataHistory[].PlayerPage.data`. Dieser wird per string-sicherem
/// Brace-Counter extrahiert und als JSON geparst.
///
/// Hinweis: Ändert FuPa das Seitenlayout, muss die Extraktion angepasst
/// werden (gleiche Abhängigkeit wie in Coach Studio).
class FupaReduxImporter {
  FupaReduxImporter({http.Client? client})
      : _client = client ?? http.Client();

  final http.Client _client;

  static final RegExp _playerUrl =
      RegExp(r'^https?://(www\.)?fupa\.(net|de)/player/', caseSensitive: false);
  static final RegExp _teamUrl =
      RegExp(r'^https?://(www\.)?fupa\.(net|de)/team/', caseSensitive: false);

  /// true, wenn [text] (getrimmt) eine FuPa-Spieler-URL ist.
  static bool isPlayerUrl(String text) => _playerUrl.hasMatch(text.trim());

  /// true, wenn [text] (getrimmt) eine FuPa-Team-URL ist.
  static bool isTeamUrl(String text) => _teamUrl.hasMatch(text.trim());

  /// true für jede verarbeitbare FuPa-URL (Spieler oder Team).
  static bool isFupaUrl(String text) =>
      isPlayerUrl(text) || isTeamUrl(text);

  /// Lädt die FuPa-Spielerseite und liefert einen Spieler-Vorschlag.
  Future<ParsedPlayer> importPlayer(String url) async {
    final trimmed = url.trim();
    if (!isPlayerUrl(trimmed)) {
      throw FupaImportException(
          'URL muss auf eine FuPa-Spielerseite zeigen (…/player/…).');
    }
    return parsePlayerHtml(await _fetchHtml(trimmed));
  }

  /// Lädt die FuPa-Teamseite und liefert den gesamten (aktiven) Kader.
  Future<List<ParsedPlayer>> importTeamPlayers(String url) async {
    final trimmed = url.trim();
    if (!isTeamUrl(trimmed)) {
      throw FupaImportException(
          'URL muss auf eine FuPa-Teamseite zeigen (…/team/…).');
    }
    return parseTeamPlayersHtml(await _fetchHtml(trimmed));
  }

  Future<String> _fetchHtml(String url) async {
    final http.Response resp;
    try {
      resp = await _client.get(
        Uri.parse(url),
        headers: const {
          'User-Agent': 'Mozilla/5.0 CoachCompanion/1.0',
          'Accept': 'text/html,application/xhtml+xml',
        },
      );
    } catch (e) {
      throw FupaImportException('Netzwerkfehler beim FuPa-Abruf: $e');
    }
    if (resp.statusCode != 200) {
      throw FupaImportException('HTTP ${resp.statusCode} beim Laden der Seite.');
    }
    return resp.body;
  }

  /// Extrahiert und übersetzt die Spielerdaten aus dem Seiten-HTML.
  /// Als statische, netzwerkfreie Methode testbar.
  static ParsedPlayer parsePlayerHtml(String html) {
    final redux = _extractRedux(html);
    final data = _extractPlayerData(redux);
    return _toParsed(data);
  }

  /// Extrahiert den Kader aus dem HTML einer FuPa-Teamseite
  /// (`dataHistory[].TeamPlayersPage.data.players`). Deaktivierte Spieler
  /// (Vereinswechsel o.ä.) werden übersprungen. Netzwerkfrei testbar.
  static List<ParsedPlayer> parseTeamPlayersHtml(String html) {
    final redux = _extractRedux(html);
    final players = _extractTeamPlayers(redux);
    final out = <ParsedPlayer>[];
    for (final raw in players) {
      if (raw is! Map) continue;
      if (raw['isDeactivated'] == true) continue;
      final first = (raw['firstName'] as String?)?.trim() ?? '';
      final last = (raw['lastName'] as String?)?.trim() ?? '';
      if (first.isEmpty && last.isEmpty) continue;
      int? number;
      final jersey = raw['jerseyNumber'];
      if (jersey is int) number = jersey;
      if (jersey is num) number = jersey.toInt();
      out.add(ParsedPlayer(
        number: number,
        firstName: first,
        lastName: last,
        position: _mapPosition(raw['position']),
      ));
    }
    return out;
  }

  static List<dynamic> _extractTeamPlayers(Map<String, dynamic> redux) {
    final dh = redux['dataHistory'];
    if (dh is! List) {
      throw FupaImportException('REDUX_DATA enthält kein dataHistory-Array.');
    }
    for (final entry in dh) {
      if (entry is! Map) continue;
      // Primär: TeamPlayersPage (Kader-Tab). Fallback: andere *Page mit
      // data.players, falls FuPa die Struktur umbenennt.
      final tpp = entry['TeamPlayersPage'];
      if (tpp is Map && tpp['data'] is Map) {
        final players = (tpp['data'] as Map)['players'];
        if (players is List) return players;
      }
      for (final value in entry.values) {
        if (value is Map && value['data'] is Map) {
          final players = (value['data'] as Map)['players'];
          if (players is List) return players;
        }
      }
    }
    throw FupaImportException(
        'Kein Kader (players) auf der Teamseite gefunden – zeigt der Link auf die Mannschaft?');
  }

  // ─── REDUX_DATA-Extraktion (string-sicherer Brace-Counter) ──────────────
  static Map<String, dynamic> _extractRedux(String html) {
    const marker = 'window.REDUX_DATA = ';
    final start = html.indexOf(marker);
    if (start < 0) {
      throw FupaImportException(
          'REDUX_DATA-Block nicht gefunden – FuPa-Layout könnte sich geändert haben.');
    }
    final text = html.substring(start + marker.length);
    var depth = 0, end = -1;
    var inStr = false, esc = false;
    for (var i = 0; i < text.length; i++) {
      final c = text[i];
      if (esc) {
        esc = false;
        continue;
      }
      if (inStr) {
        if (c == r'\') {
          esc = true;
        } else if (c == '"') {
          inStr = false;
        }
        continue;
      }
      if (c == '"') {
        inStr = true;
      } else if (c == '{') {
        depth++;
      } else if (c == '}') {
        depth--;
        if (depth == 0) {
          end = i + 1;
          break;
        }
      }
    }
    if (end < 0) {
      throw FupaImportException('REDUX_DATA-Block ist nicht sauber geschlossen.');
    }
    try {
      final decoded = jsonDecode(text.substring(0, end));
      if (decoded is! Map<String, dynamic>) {
        throw FupaImportException('REDUX_DATA ist kein Objekt.');
      }
      return decoded;
    } on FormatException catch (e) {
      throw FupaImportException('REDUX_DATA-JSON ließ sich nicht parsen: ${e.message}');
    }
  }

  static Map<String, dynamic> _extractPlayerData(Map<String, dynamic> redux) {
    final dh = redux['dataHistory'];
    if (dh is! List) {
      throw FupaImportException('REDUX_DATA enthält kein dataHistory-Array.');
    }
    for (final entry in dh) {
      if (entry is Map) {
        final page = entry['PlayerPage'];
        if (page is Map && page['data'] is Map) {
          return Map<String, dynamic>.from(page['data'] as Map);
        }
      }
    }
    throw FupaImportException(
        'Kein PlayerPage-Eintrag gefunden – ist das wirklich eine FuPa-Spielerseite?');
  }

  static ParsedPlayer _toParsed(Map<String, dynamic> data) {
    final first = (data['firstName'] as String?)?.trim() ?? '';
    final last = (data['lastName'] as String?)?.trim() ?? '';
    final position = _mapPosition(data['position']);

    int? number;
    final role = data['playerRole'];
    if (role is Map && role['seasons'] is List) {
      final seasons = role['seasons'] as List;
      if (seasons.isNotEmpty && seasons.first is Map) {
        final jersey = (seasons.first as Map)['jerseyNumber'];
        if (jersey is int) number = jersey;
        if (jersey is num) number = jersey.toInt();
      }
    }

    return ParsedPlayer(
      number: number,
      firstName: first,
      lastName: last,
      position: position,
    );
  }

  /// FuPa nutzt grobe deutsche Bezeichnungen – auf unsere Kategorien mappen.
  static String? _mapPosition(Object? raw) {
    if (raw is! String) return null;
    final s = raw.toLowerCase();
    if (s.contains('tor')) return 'Tor';
    if (s.contains('abwehr') || s.contains('verteidig')) return 'Abwehr';
    if (s.contains('mittelfeld')) return 'Mittelfeld';
    if (s.contains('angriff') || s.contains('sturm')) return 'Sturm';
    return null;
  }
}

class FupaImportException implements Exception {
  FupaImportException(this.message);
  final String message;
  @override
  String toString() => message;
}
