/// Ein Design aus dem zentralen Designer (Mehr → Designer): Tor, Spieler des
/// Spiels, Anlass oder freies Design. Wird im Design-JSON unter `designer`
/// mitgespeichert, damit das Design später wieder geöffnet werden kann.
class DesignerData {
  const DesignerData({
    required this.id,
    required this.template,
    required this.title,
    this.headline = '',
    this.infoLine = '',
    this.matchId,
    this.playerPhoto,
    this.opponentName = '',
    this.opponentLogo,
    this.isHome = true,
    this.matchDate,
  });

  /// Speicher-ID (`designer:<uuid>`).
  final String id;

  /// Vorlage: `goal` | `motm` | `occasion` | `free`.
  final String template;

  /// Anzeigename in „Meine Designs".
  final String title;

  /// Vorgabe-Überschrift (z. B. „TOR!"); im Editor frei änderbar.
  final String headline;

  /// Vorgabe-Infozeile (z. B. „B. KANIA · 35' · 1:0"); im Editor änderbar.
  final String infoLine;

  /// Verknüpftes Spiel (für Gegner-Logo/Datum), optional.
  final String? matchId;

  /// Startbild (z. B. Kader-Foto des Spielers), optional.
  final String? playerPhoto;

  final String opponentName;
  final String? opponentLogo;
  final bool isHome;
  final DateTime? matchDate;

  static const templates = ['goal', 'motm', 'occasion', 'free'];

  /// Lesbarer Name der Vorlage.
  static String labelOf(String template) => switch (template) {
    'goal' => 'Tor',
    'motm' => 'Spieler des Spiels',
    'occasion' => 'Anlass',
    _ => 'Freies Design',
  };

  String get templateLabel => labelOf(template);

  DesignerData copyWith({String? title}) => DesignerData(
    id: id,
    template: template,
    title: title ?? this.title,
    headline: headline,
    infoLine: infoLine,
    matchId: matchId,
    playerPhoto: playerPhoto,
    opponentName: opponentName,
    opponentLogo: opponentLogo,
    isHome: isHome,
    matchDate: matchDate,
  );

  /// Ohne Startbild (das liegt nach dem Anlegen ohnehin im Design selbst).
  Map<String, Object?> toJson() => {
    'id': id,
    'template': template,
    'title': title,
    'headline': headline,
    'infoLine': infoLine,
    'matchId': matchId,
    'opponentName': opponentName,
    'opponentLogo': opponentLogo,
    'isHome': isHome,
    'matchDate': matchDate?.toIso8601String(),
  };

  static DesignerData? fromJson(Object? v) {
    if (v is! Map) return null;
    final id = v['id'];
    if (id is! String || id.isEmpty) return null;
    return DesignerData(
      id: id,
      template: v['template'] is String ? v['template'] as String : 'free',
      title: v['title'] is String ? v['title'] as String : '',
      headline: v['headline'] is String ? v['headline'] as String : '',
      infoLine: v['infoLine'] is String ? v['infoLine'] as String : '',
      matchId: v['matchId'] as String?,
      opponentName: v['opponentName'] is String
          ? v['opponentName'] as String
          : '',
      opponentLogo: v['opponentLogo'] as String?,
      isHome: v['isHome'] != false,
      matchDate: DateTime.tryParse(v['matchDate']?.toString() ?? ''),
    );
  }
}

/// Spielstand (eigene : Gegner) direkt NACH dem Tor an Position [index] der
/// nach Minute sortierten Torliste [goals] (own = eigenes Tor).
({int own, int opp}) scoreAfterGoal(
  List<({int minute, bool own})> goals,
  int index,
) {
  var own = 0, opp = 0;
  for (var i = 0; i <= index && i < goals.length; i++) {
    if (goals[i].own) {
      own++;
    } else {
      opp++;
    }
  }
  return (own: own, opp: opp);
}
