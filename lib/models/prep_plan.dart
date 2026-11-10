import 'dart:convert';

/// Anlass eines Plan-Termins (wie im Coach Studio). „mannschaftsfoto" und
/// „grillen" stammen aus Altbeständen und werden wie „sonstiges" behandelt.
enum PrepAnlass { training, spiel, sonstiges }

/// Spielort eines Spiel-Termins: Heim / Auswärts / Offen (noch unklar).
enum PrepVenue { home, away, open }

extension PrepVenueLabel on PrepVenue {
  String get label => switch (this) {
    PrepVenue.home => 'Heim',
    PrepVenue.away => 'Auswärts',
    PrepVenue.open => 'Offen',
  };
}

/// „00:00" blendet eine Uhrzeit überall aus (Druck, WhatsApp, Anzeige) – wie
/// im Coach Studio, um einen Treffpunkt zu „löschen".
String? visiblePrepTime(String? t) =>
    (t == null || t.isEmpty || t == '00:00') ? null : t;

/// Ein Termin im Vorbereitungsplan. Der Wochentag wird aus dem Datum
/// abgeleitet.
class PrepPlanEntry {
  const PrepPlanEntry({
    required this.id,
    required this.date,
    this.time,
    this.anlass = PrepAnlass.training,
    this.customAnlassLabel,
    this.opponent,
    this.venue,
    this.address,
    this.meetTime,
    this.meetLocation,
    this.notes,
    this.tentative = false,
  });

  final String id;

  /// YYYY-MM-DD
  final String date;

  /// Beginn „HH:MM".
  final String? time;
  final PrepAnlass anlass;

  /// Bei „Sonstiges" der Anlass selbst, sonst ein optionaler Zusatz.
  final String? customAnlassLabel;
  final String? opponent;
  final PrepVenue? venue;

  /// Nur bei Auswärtsspielen: Adresse / Sportanlage.
  final String? address;
  final String? meetTime;
  final String? meetLocation;
  final String? notes;

  /// „Fraglich" – Termin steht noch nicht fest.
  final bool tentative;

  DateTime? get day => DateTime.tryParse(date);
  bool get isSpiel => anlass == PrepAnlass.spiel;
  bool get isAway => isSpiel && venue == PrepVenue.away;

  /// Überschrift des Anlasses (bei „Sonstiges" der freie Text).
  String get anlassLabel => switch (anlass) {
    PrepAnlass.training => 'Training',
    PrepAnlass.spiel => 'Spiel',
    PrepAnlass.sonstiges =>
      (customAnlassLabel?.trim().isNotEmpty ?? false)
          ? customAnlassLabel!.trim()
          : 'Sonstiges',
  };

  /// Zusatz unter dem Anlass (nur bei Training/Spiel).
  String? get zusatz =>
      anlass != PrepAnlass.sonstiges &&
          (customAnlassLabel?.trim().isNotEmpty ?? false)
      ? customAnlassLabel!.trim()
      : null;

  static const _unset = Object();

  PrepPlanEntry copyWith({
    String? date,
    Object? time = _unset,
    PrepAnlass? anlass,
    Object? customAnlassLabel = _unset,
    Object? opponent = _unset,
    Object? venue = _unset,
    Object? address = _unset,
    Object? meetTime = _unset,
    Object? meetLocation = _unset,
    Object? notes = _unset,
    bool? tentative,
  }) => PrepPlanEntry(
    id: id,
    date: date ?? this.date,
    time: identical(time, _unset) ? this.time : time as String?,
    anlass: anlass ?? this.anlass,
    customAnlassLabel: identical(customAnlassLabel, _unset)
        ? this.customAnlassLabel
        : customAnlassLabel as String?,
    opponent: identical(opponent, _unset) ? this.opponent : opponent as String?,
    venue: identical(venue, _unset) ? this.venue : venue as PrepVenue?,
    address: identical(address, _unset) ? this.address : address as String?,
    meetTime: identical(meetTime, _unset) ? this.meetTime : meetTime as String?,
    meetLocation: identical(meetLocation, _unset)
        ? this.meetLocation
        : meetLocation as String?,
    notes: identical(notes, _unset) ? this.notes : notes as String?,
    tentative: tentative ?? this.tentative,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'date': date,
    if (time != null) 'time': time,
    'anlass': anlass.name,
    if (customAnlassLabel != null) 'customAnlassLabel': customAnlassLabel,
    if (opponent != null) 'opponent': opponent,
    if (venue != null) 'venue': venue!.name,
    if (address != null) 'address': address,
    if (meetTime != null) 'meetTime': meetTime,
    if (meetLocation != null) 'meetLocation': meetLocation,
    if (notes != null) 'notes': notes,
    if (tentative) 'tentative': true,
  };

  factory PrepPlanEntry.fromJson(Map<String, dynamic> j) {
    String? s(String k) {
      final v = j[k];
      return (v is String && v.isNotEmpty) ? v : null;
    }

    final rawAnlass = s('anlass') ?? 'training';
    var anlass = PrepAnlass.values.firstWhere(
      (a) => a.name == rawAnlass,
      orElse: () => PrepAnlass.sonstiges,
    );
    var custom = s('customAnlassLabel');
    // Altbestand (Coach Studio): Mannschaftsfoto/Grillen → Sonstiges + Text.
    if (rawAnlass == 'mannschaftsfoto' || rawAnlass == 'grillen') {
      anlass = PrepAnlass.sonstiges;
      custom ??= rawAnlass == 'grillen' ? 'Grillen' : 'Mannschaftsfoto';
    }
    final v = s('venue');
    return PrepPlanEntry(
      id: s('id') ?? DateTime.now().microsecondsSinceEpoch.toString(),
      date: s('date') ?? '',
      time: s('time'),
      anlass: anlass,
      customAnlassLabel: custom,
      opponent: s('opponent'),
      venue: v == null
          ? null
          : PrepVenue.values.where((e) => e.name == v).firstOrNull,
      address: s('address'),
      meetTime: s('meetTime'),
      meetLocation: s('meetLocation'),
      notes: s('notes'),
      tentative: j['tentative'] == true,
    );
  }
}

/// Vorbereitungsplan (Saison-Termine als druckbarer A4-Plan), team-weit
/// geteilt. Extra-Texte oben/unten als Rich-Text (Quill-Delta-JSON oder
/// Klartext aus Altbestand).
class PrepPlan {
  const PrepPlan({
    required this.id,
    required this.title,
    this.subtitle,
    this.hint,
    this.footerText,
    this.entries = const [],
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String title;
  final String? subtitle;

  /// Extra-Text oben (zwischen Kopf und Tabelle).
  final String? hint;

  /// Extra-Text unten (nach der Tabelle).
  final String? footerText;
  final List<PrepPlanEntry> entries;
  final String? createdAt;
  final String? updatedAt;

  static const _unset = Object();

  PrepPlan copyWith({
    String? title,
    Object? subtitle = _unset,
    Object? hint = _unset,
    Object? footerText = _unset,
    List<PrepPlanEntry>? entries,
    String? updatedAt,
  }) => PrepPlan(
    id: id,
    title: title ?? this.title,
    subtitle: identical(subtitle, _unset) ? this.subtitle : subtitle as String?,
    hint: identical(hint, _unset) ? this.hint : hint as String?,
    footerText: identical(footerText, _unset)
        ? this.footerText
        : footerText as String?,
    entries: entries ?? this.entries,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    if (subtitle != null) 'subtitle': subtitle,
    if (hint != null) 'hint': hint,
    if (footerText != null) 'footerText': footerText,
    'entries': [for (final e in entries) e.toJson()],
    if (createdAt != null) 'createdAt': createdAt,
  };

  factory PrepPlan.fromJson(Map<String, dynamic> j, {String? updatedAt}) {
    final list = j['entries'];
    return PrepPlan(
      id: j['id'] as String,
      title: (j['title'] as String?) ?? 'Vorbereitungsplan',
      subtitle: j['subtitle'] as String?,
      hint: j['hint'] as String?,
      footerText: j['footerText'] as String?,
      entries: list is List
          ? [
              for (final e in list)
                if (e is Map) PrepPlanEntry.fromJson(Map<String, dynamic>.from(e)),
            ]
          : const [],
      createdAt: j['createdAt'] as String?,
      updatedAt: updatedAt,
    );
  }

  /// DB-Zeile (lokal; die Cloud-Zeile bekommt team_id beim Push).
  Map<String, Object?> toRow() => {
    'id': id,
    'data': jsonEncode(toJson()),
    'updated_at': updatedAt ?? DateTime.now().toUtc().toIso8601String(),
  };

  static PrepPlan? fromRow(Map<String, Object?> r) {
    try {
      final m = jsonDecode(r['data'] as String);
      if (m is! Map) return null;
      return PrepPlan.fromJson(
        Map<String, dynamic>.from(m),
        updatedAt: r['updated_at'] as String?,
      );
    } catch (_) {
      return null;
    }
  }
}
