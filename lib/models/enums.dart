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
  substitution('substitution', 'Wechsel', '🔁');

  const MatchEventType(this.storageKey, this.label, this.symbol);
  final String storageKey;
  final String label;
  final String symbol;

  /// Zählt dieses Ereignis als Tor für das ausführende Team?
  bool get countsAsGoal => this == MatchEventType.goal;

  static MatchEventType fromKey(String? key) =>
      MatchEventType.values.firstWhere((e) => e.storageKey == key,
          orElse: () => MatchEventType.goal);
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
