// Zentrale Enums für alle Datenmodelle.
//
// Als Strings in SQLite gespeichert (robust gegenüber Reihenfolge-Änderungen),
// deshalb hat jeder Enum einen stabilen storageKey.

/// Woher die Stammdaten eines Teams/Spielers stammen.
enum DataSource {
  /// Manuell im App-UI angelegt.
  manual('manual', 'Manuell'),

  /// Aus FuPa importiert.
  fupaApproved('fupa_approved', 'FuPa'),

  /// Platzhalter aus dem Spielplan (Gegnername bekannt, Kader noch nicht).
  schedulePlaceholder('schedule_placeholder', 'Spielplan');

  const DataSource(this.storageKey, this.label);
  final String storageKey;
  final String label;

  static DataSource fromKey(String? key) =>
      DataSource.values.firstWhere((e) => e.storageKey == key,
          orElse: () => DataSource.manual);
}

/// Status eines Spiels.
enum MatchStatus {
  scheduled('scheduled', 'Geplant'),
  live('live', 'Live'),
  finished('finished', 'Beendet');

  const MatchStatus(this.storageKey, this.label);
  final String storageKey;
  final String label;

  static MatchStatus fromKey(String? key) =>
      MatchStatus.values.firstWhere((e) => e.storageKey == key,
          orElse: () => MatchStatus.scheduled);
}

/// Heim oder Auswärts (aus Sicht des eigenen Teams).
enum Venue {
  home('home', 'Heim'),
  away('away', 'Auswärts');

  const Venue(this.storageKey, this.label);
  final String storageKey;
  final String label;

  static Venue fromKey(String? key) => Venue.values
      .firstWhere((e) => e.storageKey == key, orElse: () => Venue.home);
}

/// Rolle eines Spielers in einer Aufstellung.
enum LineupRole {
  starter('starter', 'Startelf'),
  substitute('substitute', 'Ersatzbank'),
  unavailable('unavailable', 'Nicht dabei');

  const LineupRole(this.storageKey, this.label);
  final String storageKey;
  final String label;

  static LineupRole fromKey(String? key) =>
      LineupRole.values.firstWhere((e) => e.storageKey == key,
          orElse: () => LineupRole.substitute);
}

/// Art eines Live-Ereignisses.
enum MatchEventType {
  goal('goal', 'Tor', '⚽'),
  ownGoal('own_goal', 'Eigentor', '🥅'),
  yellowCard('yellow_card', 'Gelbe Karte', '🟨'),
  secondYellow('second_yellow', 'Gelb-Rot', '🟨🟥'),
  redCard('red_card', 'Rote Karte', '🟥'),
  substitution('substitution', 'Wechsel', '🔁'),
  // Team-neutrale Spielphasen-Marken (ohne Spieler).
  kickoff('kickoff', 'Anpfiff', '🟢'),
  halftime('halftime', 'Halbzeit', '⏸'),
  secondHalfStart('second_half', 'Anpfiff 2. Halbzeit', '🟢'),
  fulltime('fulltime', 'Abpfiff', '🔚');

  const MatchEventType(this.storageKey, this.label, this.symbol);
  final String storageKey;
  final String label;
  final String symbol;

  /// Zählt dieses Ereignis als Tor für das ausführende Team?
  bool get countsAsGoal => this == MatchEventType.goal;

  /// Team-neutrale Phasen-Marke (Anpfiff/Halbzeit/Abpfiff)?
  bool get isPhaseMarker =>
      this == MatchEventType.kickoff ||
      this == MatchEventType.halftime ||
      this == MatchEventType.secondHalfStart ||
      this == MatchEventType.fulltime;

  static MatchEventType fromKey(String? key) =>
      MatchEventType.values.firstWhere((e) => e.storageKey == key,
          orElse: () => MatchEventType.goal);
}

/// Verfügbarkeitsstatus eines Spielers (Stammdaten).
enum PlayerStatus {
  fit('fit', 'Fit', '🟢'),
  verletzt('verletzt', 'Verletzt', '🤕'),
  krank('krank', 'Krank', '🤒'),
  gesperrt('gesperrt', 'Gesperrt', '⛔'),
  inaktiv('inaktiv', 'Inaktiv', '⚪');

  const PlayerStatus(this.storageKey, this.label, this.symbol);
  final String storageKey;
  final String label;
  final String symbol;

  static PlayerStatus fromKey(String? key) => PlayerStatus.values
      .firstWhere((e) => e.storageKey == key, orElse: () => PlayerStatus.fit);
}

/// Kapitäns-Rolle eines Spielers (je eine pro Mannschaft).
enum CaptainRole {
  none('none', '—', ''),
  captain('captain', 'Kapitän', 'Ⓒ'),
  vice('vice', 'Vize-Kapitän', 'Ⓥ'),
  third('third', '3. Kapitän', '③');

  const CaptainRole(this.storageKey, this.label, this.badge);
  final String storageKey;
  final String label;
  final String badge;

  static CaptainRole fromKey(String? key) => CaptainRole.values
      .firstWhere((e) => e.storageKey == key, orElse: () => CaptainRole.none);
}

/// Art eines Mannschafts-Termins (kein Pflichtspiel – dafür gibt es Spiele).
enum TeamEventType {
  feier('feier', 'Feier', '🎉'),
  foto('foto', 'Mannschaftsfoto', '📷'),
  grillen('grillen', 'Grillen', '🍖'),
  training('training', 'Training', '🏃'),
  sonstiges('sonstiges', 'Sonstiges', '📌');

  const TeamEventType(this.storageKey, this.label, this.symbol);
  final String storageKey;
  final String label;
  final String symbol;

  static TeamEventType fromKey(String? key) =>
      TeamEventType.values.firstWhere((e) => e.storageKey == key,
          orElse: () => TeamEventType.sonstiges);
}

/// Kartentyp für den Disziplin-/Kartenverlauf eines Spielers.
enum CardType {
  yellow('yellow', 'Gelbe Karte', '🟨'),
  yellowRed('yellow_red', 'Gelb-Rote Karte', '🟨🟥'),
  red('red', 'Rote Karte', '🟥');

  const CardType(this.storageKey, this.label, this.symbol);
  final String storageKey;
  final String label;
  final String symbol;

  static CardType fromKey(String? key) => CardType.values
      .firstWhere((e) => e.storageKey == key, orElse: () => CardType.yellow);

  /// Ableitung aus einem Live-Ereignistyp; null wenn keine Karte.
  static CardType? fromEvent(MatchEventType type) {
    switch (type) {
      case MatchEventType.yellowCard:
        return CardType.yellow;
      case MatchEventType.secondYellow:
        return CardType.yellowRed;
      case MatchEventType.redCard:
        return CardType.red;
      default:
        return null;
    }
  }
}

/// Nominierungs-/Verfügbarkeitsstatus eines Spielers für ein Spiel.
enum NominationStatus {
  /// Keine Angabe (Standard – kein Datensatz).
  open('open', 'Offen'),
  zugesagt('zugesagt', 'Zugesagt'),
  unsicher('unsicher', 'Unsicher'),
  abgesagt('abgesagt', 'Abgesagt');

  const NominationStatus(this.storageKey, this.label);
  final String storageKey;
  final String label;

  /// Zählt dieser Status als für die Aufstellung verfügbar?
  bool get isAvailable => this == NominationStatus.zugesagt;

  static NominationStatus fromKey(String? key) =>
      NominationStatus.values.firstWhere((e) => e.storageKey == key,
          orElse: () => NominationStatus.open);
}

/// Ergebnis-Status eines Imports / einer Synchronisierung.
enum ImportStatus {
  /// Online-Import über eine genehmigte Quelle erfolgreich.
  success('success'),

  /// Keine genehmigte automatische Quelle verfügbar – manuelle Pflege nötig.
  manualRequired('manual_required'),

  /// Daten sind bereits vorhanden, nichts Neues importiert.
  alreadyPresent('already_present'),

  /// Quelle vorhanden, aber nicht autorisiert/konfiguriert.
  notAuthorized('not_authorized'),

  /// Technischer Fehler beim Import.
  error('error');

  const ImportStatus(this.storageKey);
  final String storageKey;
}
