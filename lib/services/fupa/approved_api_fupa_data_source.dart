import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../models/enums.dart';
import 'fupa_data_source.dart';
import 'fupa_dtos.dart';

/// Datenquelle für einen offiziell genehmigten FuPa-Datenzugang.
///
/// Erwartet eine konfigurierte Basis-URL und ein Zugriffstoken (z.B. eine
/// genehmigte Partner-/Export-Schnittstelle). Ist nichts konfiguriert, meldet
/// die Quelle sich als nicht verfügbar – dann greift automatisch die manuelle
/// Übernahme. Es wird KEIN FuPa-Widget-Endpunkt als versteckte API verwendet.
///
/// Erwartetes JSON-Schema (quellneutral):
///   GET {base}/team?ref=...      -> { name, shortName, players: [...] }
///   GET {base}/schedule?ref=...  -> { matches: [...] }
///   GET {base}/opponent?ref=...  -> { name, shortName, players: [...] }
class ApprovedApiFupaDataSource implements FupaDataSource {
  final String? baseUrl;
  final String? token;
  final http.Client _client;

  ApprovedApiFupaDataSource({
    required this.baseUrl,
    required this.token,
    http.Client? client,
  }) : _client = client ?? http.Client();

  @override
  String get id => 'fupa_approved_api';

  @override
  String get label => 'Genehmigte FuPa-Schnittstelle';

  bool get _configured =>
      (baseUrl != null && baseUrl!.trim().isNotEmpty) &&
      (token != null && token!.trim().isNotEmpty);

  @override
  Future<SourceAvailability> checkAvailability() async {
    if (!_configured) {
      return const SourceAvailability.unavailable(
        'Keine genehmigte Schnittstelle hinterlegt (Basis-URL/Token fehlen).',
      );
    }
    return SourceAvailability.ready(
      'Genehmigte Schnittstelle aktiv: ${Uri.tryParse(baseUrl!)?.host ?? baseUrl}',
    );
  }

  Map<String, String> get _headers => {
        'Authorization': 'Bearer ${token!}',
        'Accept': 'application/json',
      };

  Uri _endpoint(String path, Map<String, String> query) {
    final base = Uri.parse(baseUrl!.trim());
    return base.replace(
      path: '${base.path.replaceAll(RegExp(r'/+$'), '')}/$path',
      queryParameters: {...base.queryParameters, ...query},
    );
  }

  Future<Map<String, dynamic>> _getJson(Uri uri) async {
    final resp = await _client.get(uri, headers: _headers);
    if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw SourceNotAuthorized(
          'Zugriff abgelehnt (${resp.statusCode}) – Genehmigung/Token prüfen.');
    }
    if (resp.statusCode >= 400) {
      throw Exception('Server-Fehler ${resp.statusCode} bei $uri');
    }
    final decoded = jsonDecode(resp.body);
    if (decoded is! Map<String, dynamic>) {
      throw Exception('Unerwartetes Antwortformat von $uri');
    }
    return decoded;
  }

  @override
  Future<TeamData> fetchTeam(FupaTeamRef ref) async {
    if (!_configured) throw SourceNotAuthorized('Schnittstelle nicht konfiguriert.');
    final json = await _getJson(_endpoint('team', {'ref': ref.ref}));
    return _teamFromJson(json, ref.ref);
  }

  @override
  Future<TeamData> fetchOpponent(ScheduledMatchData match) async {
    if (!_configured) throw SourceNotAuthorized('Schnittstelle nicht konfiguriert.');
    final ref = match.opponentRef ?? '';
    final json = await _getJson(_endpoint('opponent', {'ref': ref}));
    return _teamFromJson(json, ref);
  }

  @override
  Future<List<ScheduledMatchData>> fetchSchedule(FupaTeamRef ref) async {
    if (!_configured) throw SourceNotAuthorized('Schnittstelle nicht konfiguriert.');
    final json = await _getJson(_endpoint('schedule', {'ref': ref.ref}));
    final matches = (json['matches'] as List?) ?? const [];
    return matches
        .whereType<Map<String, dynamic>>()
        .map(_matchFromJson)
        .toList();
  }

  TeamData _teamFromJson(Map<String, dynamic> json, String fallbackRef) {
    final players = ((json['players'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((p) => PlayerData(
              firstName: (p['firstName'] ?? p['first_name'] ?? '').toString(),
              lastName: (p['lastName'] ?? p['last_name'] ?? '').toString(),
              number: _asInt(p['number']),
              position: p['position']?.toString(),
              externalId: (p['id'] ?? p['externalId'])?.toString(),
            ))
        .toList();
    return TeamData(
      name: (json['name'] ?? fallbackRef).toString(),
      shortName: json['shortName']?.toString(),
      fupaRef: (json['ref'] ?? fallbackRef).toString(),
      players: players,
    );
  }

  ScheduledMatchData _matchFromJson(Map<String, dynamic> m) {
    final venueStr = (m['venue'] ?? '').toString().toLowerCase();
    return ScheduledMatchData(
      opponentName: (m['opponentName'] ?? m['opponent'] ?? 'Gegner').toString(),
      opponentRef: (m['opponentRef'] ?? m['opponent_ref'])?.toString(),
      kickoff: DateTime.tryParse((m['kickoff'] ?? '').toString()),
      venue: venueStr.contains('away') || venueStr.contains('ausw')
          ? Venue.away
          : Venue.home,
      competition: m['competition']?.toString(),
      externalId: (m['id'] ?? m['externalId'])?.toString(),
    );
  }

  int? _asInt(Object? v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }
}
