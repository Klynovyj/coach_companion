import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../models/enums.dart';
import '../paste/squad_paste_parser.dart';
import 'fupa_dtos.dart';

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

  /// Lädt die FuPa-Teamseite einmal und liefert Kader **und** Vereinsdaten
  /// (Name, Kurzname, Logo als Data-URL).
  Future<FupaTeamImport> importTeam(String url) async {
    final trimmed = url.trim();
    if (!isTeamUrl(trimmed)) {
      throw FupaImportException(
          'URL muss auf eine FuPa-Teamseite zeigen (…/team/…).');
    }
    final html = await _fetchHtml(trimmed);
    final players = parseTeamPlayersHtml(html);
    final meta = parseTeamMetaHtml(html);
    final logo = meta.logoUrl == null ? null : await downloadLogo(meta.logoUrl!);
    return FupaTeamImport(
      name: meta.name,
      shortName: meta.shortName,
      logoDataUrl: logo,
      players: players,
    );
  }

  /// Lädt das Vereinslogo als Data-URL (PNG). FuPa erlaubt nur feste Größen –
  /// 128×128 ist für Avatare ausreichend.
  Future<String?> downloadLogo(String baseUrl) =>
      _downloadImage(baseUrl, '128x128.png');

  /// Lädt ein Spielerfoto als Data-URL (JPEG, 128×128).
  Future<String?> downloadPhoto(String baseUrl) =>
      _downloadImage(baseUrl, '128x128.jpeg');

  /// Lädt ein FuPa-Bild (Basis-URL + Größen-Suffix) als Data-URL. Fehler
  /// werden still verschluckt (Bild ist optional).
  Future<String?> _downloadImage(String baseUrl, String suffix) async {
    final url = baseUrl.endsWith('/') ? '$baseUrl$suffix' : baseUrl;
    try {
      final resp = await _client.get(Uri.parse(url),
          headers: const {'User-Agent': 'Mozilla/5.0 CoachCompanion/1.0'});
      if (resp.statusCode != 200) return null;
      final ct = resp.headers['content-type'] ?? 'image/jpeg';
      if (!ct.startsWith('image/')) return null;
      return 'data:$ct;base64,${base64Encode(resp.bodyBytes)}';
    } catch (_) {
      return null;
    }
  }

  /// Wandelt erkannte Spieler in [PlayerData] um und lädt dabei – sofern eine
  /// Foto-URL vorliegt – die Spielerfotos nebenläufig als Data-URL.
  Future<List<PlayerData>> toPlayerDataWithPhotos(
      List<ParsedPlayer> players) async {
    final photos = <String, String?>{};
    final urls = <String>{
      for (final p in players)
        if (p.photoUrl != null) p.photoUrl!,
    };
    await Future.wait(urls.map((u) async {
      photos[u] = await downloadPhoto(u);
    }));
    return [
      for (final p in players)
        PlayerData(
          firstName: p.firstName,
          lastName: p.lastName,
          number: p.number,
          position: p.position,
          externalId: p.externalId,
          photoDataUrl: p.photoUrl == null ? null : photos[p.photoUrl!],
        ),
    ];
  }

  /// Importiert den Spielplan einer Mannschaft. Akzeptiert den Team- oder den
  /// `/matches`-Link; lädt die `/matches`-Seite, parst die Spiele und lädt
  /// Gegner-Logos nebenläufig als Data-URL.
  Future<List<ScheduledMatchData>> importSchedule(String url) async {
    final trimmed = url.trim();
    if (!isTeamUrl(trimmed)) {
      throw FupaImportException(
          'URL muss auf eine FuPa-Teamseite zeigen (…/team/…).');
    }
    final ownSlug = _teamSlug(trimmed);
    final matchesUrl = _subPageUrlFor(trimmed, 'matches');
    final html = await _fetchHtml(matchesUrl);
    final matches = parseTeamMatchesHtml(html, ownSlug);

    // Gegner-Logos nebenläufig laden (eindeutige URLs nur einmal).
    final uniqueLogos = <String>{
      for (final m in matches)
        if (m.opponentLogoUrl != null) m.opponentLogoUrl!,
    };
    final logoCache = <String, String?>{};
    await Future.wait(uniqueLogos.map((u) async {
      logoCache[u] = await downloadLogo(u);
    }));

    return [
      for (final m in matches)
        m.opponentLogoUrl == null
            ? m
            : m.withLogo(logoCache[m.opponentLogoUrl!]),
    ];
  }

  /// Importiert die Spieler-Saison-Statistik (aus `/playerstats`).
  Future<List<PlayerStatData>> importStats(String url) async {
    final trimmed = url.trim();
    if (!isTeamUrl(trimmed)) {
      throw FupaImportException(
          'URL muss auf eine FuPa-Teamseite zeigen (…/team/…).');
    }
    final statsUrl = _subPageUrlFor(trimmed, 'playerstats');
    return parseTeamStatsHtml(await _fetchHtml(statsUrl));
  }

  /// Extrahiert die Statistik aus `dataHistory[].TeamPlayerStatsPage.season.players`.
  /// Netzwerkfrei testbar.
  static List<PlayerStatData> parseTeamStatsHtml(String html) {
    final redux = _extractRedux(html);
    final dh = redux['dataHistory'];
    if (dh is! List) {
      throw FupaImportException('REDUX_DATA enthält kein dataHistory-Array.');
    }
    List? players;
    for (final entry in dh) {
      if (entry is! Map) continue;
      final page = entry['TeamPlayerStatsPage'];
      if (page is Map && page['season'] is Map) {
        final p = (page['season'] as Map)['players'];
        if (p is List) {
          players = p;
          break;
        }
      }
    }
    if (players == null) {
      throw FupaImportException(
          'Keine Statistik (TeamPlayerStatsPage) gefunden – zeigt der Link auf die Mannschaft?');
    }
    int asInt(Object? v) => v is int ? v : (v is num ? v.toInt() : 0);
    final out = <PlayerStatData>[];
    for (final raw in players) {
      if (raw is! Map) continue;
      final first = (raw['firstName'] as String?)?.trim() ?? '';
      final last = (raw['lastName'] as String?)?.trim() ?? '';
      if (first.isEmpty && last.isEmpty) continue;
      out.add(PlayerStatData(
        externalId: (raw['id'] ?? raw['slug'])?.toString(),
        firstName: first,
        lastName: last,
        matches: asInt(raw['matches']),
        goals: asInt(raw['goals']),
        assists: asInt(raw['assists']),
        yellowCards: asInt(raw['yellowCards']),
        yellowRedCards: asInt(raw['yellowRedCards']),
        redCards: asInt(raw['redCards']),
        minutes: asInt(raw['minutesPlayed']),
        topEleven: asInt(raw['topEleven']),
      ));
    }
    return out;
  }

  /// Baut aus einem Team-/Unterseitenlink die URL einer bestimmten Unterseite
  /// (z.B. `matches`, `playerstats`) – egal welche Unterseite eingefügt wurde.
  static String _subPageUrlFor(String url, String sub) {
    final u = url.trim().replaceAll(RegExp(r'/+$'), '');
    final match = RegExp(r'^(https?://(?:www\.)?fupa\.(?:net|de)/team/[^/]+)',
            caseSensitive: false)
        .firstMatch(u);
    final base = match?.group(1) ?? u;
    return '$base/$sub';
  }

  static String _teamSlug(String url) {
    final m = RegExp(r'/team/([^/?#]+)', caseSensitive: false).firstMatch(url);
    return (m?.group(1) ?? '').toLowerCase();
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
        externalId: (raw['id'] ?? raw['slug'])?.toString(),
        photoUrl: _imagePath(raw['image']),
      ));
    }
    return out;
  }

  /// Liest Vereinsname, Kurzname und Logo-Basis-URL aus `data.info.club`.
  static FupaTeamMeta parseTeamMetaHtml(String html) {
    final redux = _extractRedux(html);
    final dh = redux['dataHistory'];
    if (dh is List) {
      for (final entry in dh) {
        if (entry is! Map) continue;
        for (final page in entry.values) {
          if (page is Map && page['data'] is Map) {
            final info = (page['data'] as Map)['info'];
            if (info is Map && info['club'] is Map) {
              final club = info['club'] as Map;
              final img = club['image'];
              final logoUrl = (img is Map) ? img['path'] as String? : null;
              return FupaTeamMeta(
                name: (club['name'] as String?)?.trim(),
                shortName: (club['shortName'] as String?)?.trim(),
                logoUrl: (logoUrl != null && logoUrl.startsWith('http'))
                    ? logoUrl
                    : null,
              );
            }
          }
        }
      }
    }
    return const FupaTeamMeta();
  }

  /// Extrahiert den Spielplan aus dem HTML der `/matches`-Seite
  /// (`dataHistory[].TeamMatchesPage.items`). [ownSlug] bestimmt Heim/Auswärts
  /// und die Ergebnis-Zuordnung. Netzwerkfrei testbar.
  static List<ScheduledMatchData> parseTeamMatchesHtml(
      String html, String ownSlug) {
    final redux = _extractRedux(html);
    final items = _extractMatchItems(redux);
    final out = <ScheduledMatchData>[];
    for (final raw in items) {
      if (raw is! Map) continue;
      final home = raw['homeTeam'];
      final away = raw['awayTeam'];
      if (home is! Map || away is! Map) continue;

      final homeSlug = (home['slug'] as String?)?.toLowerCase();
      final ownIsHome = homeSlug == ownSlug;
      final Map opp = ownIsHome ? away : home;

      final homeGoal = raw['homeGoal'];
      final awayGoal = raw['awayGoal'];
      final finished = homeGoal is int && awayGoal is int;

      out.add(ScheduledMatchData(
        opponentName: _teamName(opp),
        opponentRef: (opp['slug'] as String?)?.toLowerCase(),
        opponentFupaUrl: _teamLink(opp),
        opponentLogoUrl: _teamLogo(opp),
        kickoff: DateTime.tryParse((raw['kickoff'] ?? '').toString()),
        venue: ownIsHome ? Venue.home : Venue.away,
        competition: _competition(raw),
        externalId: raw['id']?.toString(),
        finished: finished,
        ownGoals: finished ? (ownIsHome ? homeGoal : awayGoal) : null,
        opponentGoals: finished ? (ownIsHome ? awayGoal : homeGoal) : null,
      ));
    }
    return out;
  }

  static List<dynamic> _extractMatchItems(Map<String, dynamic> redux) {
    final dh = redux['dataHistory'];
    if (dh is! List) {
      throw FupaImportException('REDUX_DATA enthält kein dataHistory-Array.');
    }
    for (final entry in dh) {
      if (entry is! Map) continue;
      final page = entry['TeamMatchesPage'];
      if (page is Map && page['items'] is List) {
        return page['items'] as List;
      }
    }
    throw FupaImportException(
        'Kein Spielplan (TeamMatchesPage.items) gefunden – zeigt der Link auf die Mannschaft?');
  }

  static String _teamName(Map team) {
    final club = team['club'];
    if (club is Map && club['name'] is String) return club['name'] as String;
    final name = team['name'];
    if (name is Map && name['full'] is String) return name['full'] as String;
    return 'Gegner';
  }

  static String? _teamLink(Map team) {
    final link = team['linkUrl'];
    if (link is String && link.startsWith('/')) {
      return 'https://www.fupa.net$link';
    }
    final slug = team['slug'];
    if (slug is String && slug.isNotEmpty) {
      return 'https://www.fupa.net/team/$slug';
    }
    return null;
  }

  static String? _teamLogo(Map team) {
    final club = team['club'];
    if (club is Map && club['image'] is Map) {
      final path = (club['image'] as Map)['path'];
      if (path is String && path.startsWith('http')) return path;
    }
    final img = team['image'];
    if (img is Map && img['path'] is String) {
      final path = img['path'] as String;
      if (path.startsWith('http')) return path;
    }
    return null;
  }

  static String? _competition(Map item) {
    final round = item['round'];
    if (round is Map && round['competitionSeason'] is Map) {
      final cs = round['competitionSeason'] as Map;
      final short = cs['shortName'];
      if (short is String && short.isNotEmpty) return short;
      final name = cs['name'];
      if (name is String && name.isNotEmpty) return name;
    }
    final comp = item['competition'];
    if (comp is String && comp.isNotEmpty) return comp;
    if (comp is Map) {
      final n = comp['shortName'] ?? comp['name'];
      if (n is String && n.isNotEmpty) return n;
    }
    return null;
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
      externalId: (data['id'] ?? data['slug'])?.toString(),
      photoUrl: _imagePath(data['image']),
    );
  }

  static String? _imagePath(Object? image) {
    if (image is Map && image['path'] is String) {
      final p = image['path'] as String;
      if (p.startsWith('http')) return p;
    }
    return null;
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

/// Vereins-Stammdaten aus der FuPa-Teamseite.
class FupaTeamMeta {
  final String? name;
  final String? shortName;

  /// Basis-URL des Logos (ohne Größen-Suffix), falls vorhanden.
  final String? logoUrl;

  const FupaTeamMeta({this.name, this.shortName, this.logoUrl});

  bool get hasAny => name != null || shortName != null || logoUrl != null;
}

/// Ergebnis von [FupaReduxImporter.importTeam]: Kader + Vereinsdaten.
class FupaTeamImport {
  final String? name;
  final String? shortName;

  /// Logo als Data-URL (bereits heruntergeladen), falls verfügbar.
  final String? logoDataUrl;

  final List<ParsedPlayer> players;

  const FupaTeamImport({
    this.name,
    this.shortName,
    this.logoDataUrl,
    this.players = const [],
  });

  bool get hasMeta =>
      name != null || shortName != null || logoDataUrl != null;
}
