/// Hilfen für den Grafik-Editor: Verlauf (Rückgängig/Wiederholen) und
/// Einrasten an Hilfslinien. Rein rechnerisch → testbar ohne Flutter.
library;

/// Verlauf als Stapel von Ständen (z. B. JSON des Designs).
class DesignHistory {
  DesignHistory({this.limit = 50});

  /// Höchstzahl gemerkter Schritte zurück.
  final int limit;
  final List<String> _undo = [];
  final List<String> _redo = [];
  String? _current;

  String? get current => _current;
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  /// Neuer Ausgangsstand, Verlauf leeren (z. B. nach dem Laden).
  void reset(String state) {
    _undo.clear();
    _redo.clear();
    _current = state;
  }

  /// Aktuellen Stand ersetzen, ohne einen Schritt anzulegen (z. B. direkt
  /// nach Rückgängig, falls das Einspielen den Stand leicht normalisiert).
  void replaceCurrent(String state) => _current = state;

  /// Aktuellen Stand merken. Liefert true, wenn ein neuer Schritt entstand.
  bool record(String state) {
    final cur = _current;
    if (cur == null) {
      _current = state;
      return false;
    }
    if (state == cur) return false;
    _undo.add(cur);
    if (_undo.length > limit) _undo.removeAt(0);
    _redo.clear();
    _current = state;
    return true;
  }

  /// Einen Schritt zurück → der einzuspielende Stand (null = nichts da).
  String? undo() {
    if (_undo.isEmpty || _current == null) return null;
    _redo.add(_current!);
    _current = _undo.removeLast();
    return _current;
  }

  /// Einen Schritt vor → der einzuspielende Stand (null = nichts da).
  String? redo() {
    if (_redo.isEmpty || _current == null) return null;
    _undo.add(_current!);
    _current = _redo.removeLast();
    return _current;
  }
}

/// Einrasten auf einer Achse: Element mit Mitte [center] und halber Ausdehnung
/// [half]. [centerLines] ziehen die Mitte an, [edgeLines] die beiden Kanten.
/// Ergebnis: Verschiebung, die zur nächsten Linie führt (0 = nichts in der
/// Nähe), und die getroffene Linie (für die Anzeige).
({double offset, double? line}) snapAxis({
  required double center,
  required double half,
  List<double> centerLines = const [],
  List<double> edgeLines = const [],
  double threshold = 6,
}) {
  double? bestOff;
  double? bestLine;
  void check(double at, double line) {
    final d = line - at;
    if (d.abs() > threshold) return;
    if (bestOff == null || d.abs() < bestOff!.abs()) {
      bestOff = d;
      bestLine = line;
    }
  }

  for (final l in centerLines) {
    check(center, l);
  }
  for (final l in edgeLines) {
    check(center - half, l);
    check(center + half, l);
  }
  return (offset: bestOff ?? 0, line: bestLine);
}
