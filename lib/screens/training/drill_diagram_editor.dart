import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/drill_diagram.dart';
import '../../services/cloud_service.dart';
import '../../widgets/drill_diagram_view.dart';
import '../../widgets/zone_overlays.dart';

/// Bearbeitbare Übungs-Skizze: Werkzeug wählen, auf das Feld tippen zum
/// Hinzufügen, Elemente ziehen zum Verschieben. Pfeile/Zonen zieht man zum
/// Zeichnen auf; bei Auswahl lassen sich die Endpunkte einzeln ziehen. Mit dem
/// Größe-Regler wird das gewählte Objekt größer/kleiner. „Vollbild" öffnet den
/// Editor formatfüllend.
class DrillDiagramEditor extends StatefulWidget {
  const DrillDiagramEditor({
    super.key,
    required this.initial,
    required this.onChanged,
    this.fullscreen = false,
  });

  final DrillDiagram initial;
  final ValueChanged<DrillDiagram> onChanged;
  final bool fullscreen;

  @override
  State<DrillDiagramEditor> createState() => _DrillDiagramEditorState();
}

class _DrillDiagramEditorState extends State<DrillDiagramEditor> {
  late List<DrillElement> _els = List.of(widget.initial.elements);
  late String _field = widget.initial.field;
  late String? _overlay = widget.initial.overlay;
  late List<DrillAnimStep>? _animation = widget.initial.animation;
  String _tool = 'select';
  final Set<int> _selection = {};
  int? get _sel => _selection.length == 1 ? _selection.first : null;

  // Aktiver Zug: Art ('move'|'start'|'end'|'draw'|'marquee') + Element.
  String? _dragKind;
  int? _dragIndex;
  Rect? _marquee; // Rahmen-Auswahl (normierte Koordinaten)
  Offset? _marqueeStart;

  // Undo/Redo: Verlauf von Zuständen (debounced, max 50).
  final List<DrillDiagram> _history = [];
  int _histIndex = 0;
  Timer? _histTimer;
  bool _restoring = false;

  final FocusNode _editorFocus = FocusNode();
  final FocusNode _labelFocus = FocusNode();

  // Favoriten-Farben (persistent über shared_preferences).
  static const _favKey = 'skizze_color_favorites';
  List<String> _favColors = [];

  @override
  void initState() {
    super.initState();
    _history.add(_snapshot());
    _loadFavs();
  }

  @override
  void dispose() {
    _histTimer?.cancel();
    _editorFocus.dispose();
    _labelFocus.dispose();
    super.dispose();
  }

  DrillDiagram _snapshot() => DrillDiagram(
    field: _field,
    elements: List.of(_els),
    overlay: _overlay,
    animation: _animation,
  );

  Future<void> _loadFavs() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _favColors = p.getStringList(_favKey) ?? const []);
  }

  Future<void> _addFav(String hex) async {
    final h = hex.toUpperCase();
    if (_favColors.any((e) => e.toUpperCase() == h)) return;
    setState(() {
      _favColors = [h, ..._favColors];
      if (_favColors.length > 10) _favColors = _favColors.sublist(0, 10);
    });
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_favKey, _favColors);
  }

  Future<void> _removeFav(String hex) async {
    setState(
      () => _favColors = _favColors
          .where((e) => e.toUpperCase() != hex.toUpperCase())
          .toList(),
    );
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_favKey, _favColors);
  }

  // Standardfarben für Spieler (blau) und Gegner (rot).
  static const _playerColor = '#1565C0';
  static const _oppColor = '#C62828';
  static const _gkColor = '#F59E0B';

  static const _tools = <(String, String, IconData)>[
    ('select', 'Hand', Icons.back_hand),
    ('player', 'Spieler', Icons.person),
    ('opp', 'Gegner', Icons.person_outline),
    ('gk', 'Torwart', Icons.sports_handball),
    ('cone', 'Hütchen', Icons.change_history),
    ('goal', 'Großtor', Icons.sports_soccer),
    ('minigoal', 'Minitor', Icons.sports_soccer_outlined),
    ('ball', 'Ball', Icons.circle),
    ('arrow', 'Pfeil', Icons.north_east),
    ('zone', 'Zone', Icons.crop_square),
    ('text', 'Text', Icons.title),
  ];

  // Farb-Palette fürs Eigenschaften-Panel (schwarz, rot, blau, grün, orange, weiß).
  static const _palette = <String>[
    '#000000',
    _oppColor,
    _playerColor,
    '#2E7D32',
    _gkColor,
    '#FFFFFF',
  ];

  bool _isTwoPoint(String type) => type == 'arrow' || type == 'zone';

  // Raster-Einrasten, damit Objekte sauber ausgerichtet sitzen.
  static const _grid = 0.0625;
  double _snapV(double v) => ((v / _grid).round() * _grid).clamp(0.0, 1.0);
  DrillElement _snapEl(DrillElement e) => e.copyWith(
    x: _snapV(e.x),
    y: _snapV(e.y),
    x2: e.x2 == null ? null : _snapV(e.x2!),
    y2: e.y2 == null ? null : _snapV(e.y2!),
  );

  void _emit() {
    widget.onChanged(_snapshot());
    if (!_restoring) {
      _histTimer?.cancel();
      _histTimer = Timer(const Duration(milliseconds: 350), _pushHistory);
    }
  }

  void _pushHistory() {
    final cur = _snapshot();
    if (jsonEncode(cur.toJson()) ==
        jsonEncode(_history[_histIndex].toJson())) {
      return;
    }
    if (_histIndex < _history.length - 1) {
      _history.removeRange(_histIndex + 1, _history.length);
    }
    _history.add(cur);
    if (_history.length > 50) _history.removeAt(0);
    _histIndex = _history.length - 1;
    if (mounted) setState(() {});
  }

  bool get _canUndo => _histIndex > 0;
  bool get _canRedo => _histIndex < _history.length - 1;

  void _undo() {
    _histTimer?.cancel();
    _pushHistory(); // offene Änderung sichern
    if (_histIndex <= 0) return;
    setState(() {
      _histIndex--;
      _applyState(_history[_histIndex]);
    });
  }

  void _redo() {
    if (_histIndex >= _history.length - 1) return;
    setState(() {
      _histIndex++;
      _applyState(_history[_histIndex]);
    });
  }

  void _applyState(DrillDiagram d) {
    _field = d.field;
    _overlay = d.overlay;
    _animation = d.animation;
    _els = List.of(d.elements);
    _selection.clear();
    _restoring = true;
    widget.onChanged(_snapshot());
    _restoring = false;
  }

  int? _hit(Offset norm) {
    int? best;
    double bestD = 0.07; // Trefferschwelle (relativ)
    for (var i = 0; i < _els.length; i++) {
      final e = _els[i];
      final d = (Offset(e.x, e.y) - norm).distance;
      if (d < bestD) {
        bestD = d;
        best = i;
      }
      if (e.x2 != null && e.y2 != null) {
        final d2 = (Offset(e.x2!, e.y2!) - norm).distance;
        if (d2 < bestD) {
          bestD = d2;
          best = i;
        }
      }
    }
    return best;
  }

  /// Prüft, ob [norm] nahe einem Endpunkt des Elements liegt. Rückgabe
  /// 'start' (x/y) oder 'end' (x2/y2) oder null.
  String? _endpointHit(Offset norm, int index) {
    final e = _els[index];
    if (!_isTwoPoint(e.type) || e.x2 == null || e.y2 == null) return null;
    final dStart = (Offset(e.x, e.y) - norm).distance;
    final dEnd = (Offset(e.x2!, e.y2!) - norm).distance;
    const th = 0.08;
    if (dStart > th && dEnd > th) return null;
    return dEnd < dStart ? 'end' : 'start';
  }

  /// Indizes, die zur selben Gruppe gehören wie [i] (oder nur {i}).
  Set<int> _groupMembers(int i) {
    final g = _els[i].groupId;
    if (g == null) return {i};
    return {
      for (var j = 0; j < _els.length; j++)
        if (_els[j].groupId == g) j,
    };
  }

  /// Wählt das getroffene Objekt (bzw. seine Gruppe); mit Shift additiv.
  void _selectHit(int hit, bool shift) {
    final members = _groupMembers(hit);
    setState(() {
      if (shift) {
        if (_selection.containsAll(members)) {
          _selection.removeAll(members);
        } else {
          _selection.addAll(members);
        }
      } else {
        _selection
          ..clear()
          ..addAll(members);
      }
    });
  }

  Offset _norm(Offset local, Size size) {
    final inset = size.shortestSide * 0.03;
    final w = size.width - 2 * inset;
    final h = size.height - 2 * inset;
    return Offset(
      ((local.dx - inset) / w).clamp(0.0, 1.0),
      ((local.dy - inset) / h).clamp(0.0, 1.0),
    );
  }

  Future<void> _addText(Offset norm) async {
    final ctrl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Text'),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    if (text == null || text.isEmpty) return;
    setState(() {
      _els.add(
        _snapEl(DrillElement(type: 'text', x: norm.dx, y: norm.dy, label: text)),
      );
      _selection
        ..clear()
        ..add(_els.length - 1);
    });
    _emit();
  }

  /// Kleinste freie Rückennummer unter den Spielern gleicher Farbe (Team).
  String _nextNumber(String colorHex) {
    final used = <int>{};
    for (final e in _els) {
      if (e.type == 'player' && (e.color ?? _playerColor) == colorHex) {
        final n = int.tryParse(e.label ?? '');
        if (n != null) used.add(n);
      }
    }
    var n = 1;
    while (used.contains(n)) {
      n++;
    }
    return n.toString();
  }

  DrillElement _newElement(String tool, Offset norm, {Offset? end}) {
    final e2 = end ?? norm;
    switch (tool) {
      case 'player':
        return DrillElement(
          type: 'player',
          x: norm.dx,
          y: norm.dy,
          color: _playerColor,
          label: _nextNumber(_playerColor),
        );
      case 'opp':
        return DrillElement(
          type: 'player',
          x: norm.dx,
          y: norm.dy,
          color: _oppColor,
          label: _nextNumber(_oppColor),
        );
      case 'gk':
        return DrillElement(
          type: 'player',
          x: norm.dx,
          y: norm.dy,
          color: _gkColor,
          label: 'TW',
        );
      case 'arrow':
        return DrillElement(
          type: 'arrow',
          x: norm.dx,
          y: norm.dy,
          x2: e2.dx,
          y2: e2.dy,
        );
      case 'zone':
        return DrillElement(
          type: 'zone',
          x: norm.dx,
          y: norm.dy,
          x2: e2.dx,
          y2: e2.dy,
        );
      default:
        return DrillElement(type: tool, x: norm.dx, y: norm.dy);
    }
  }

  void _addByTap(Offset norm) {
    if (_tool == 'text') {
      _addText(norm);
      return;
    }
    DrillElement e;
    if (_tool == 'arrow') {
      e = _newElement('arrow', norm,
          end: Offset(
            (norm.dx + 0.18).clamp(0.0, 1.0),
            (norm.dy - 0.12).clamp(0.0, 1.0),
          ));
    } else if (_tool == 'zone') {
      e = _newElement('zone', norm,
          end: Offset(
            (norm.dx + 0.22).clamp(0.0, 1.0),
            (norm.dy + 0.18).clamp(0.0, 1.0),
          ));
    } else {
      e = _newElement(_tool, norm);
    }
    setState(() {
      _els.add(_snapEl(e));
      _selection
        ..clear()
        ..add(_els.length - 1);
    });
    _emit();
  }

  void _moveBy(int i, Offset delta) {
    final e = _els[i];
    _els[i] = e.copyWith(
      x: (e.x + delta.dx).clamp(0.0, 1.0),
      y: (e.y + delta.dy).clamp(0.0, 1.0),
      x2: e.x2 == null ? null : (e.x2! + delta.dx).clamp(0.0, 1.0),
      y2: e.y2 == null ? null : (e.y2! + delta.dy).clamp(0.0, 1.0),
    );
  }

  bool get _shiftHeld =>
      HardwareKeyboard.instance.isShiftPressed ||
      HardwareKeyboard.instance.isControlPressed;

  void _onPanStart(Offset norm) {
    _editorFocus.requestFocus();
    // 1) Endpunkt des (einzeln) gewählten Pfeils/Zone ziehen?
    final sel = _sel;
    if (sel != null && sel < _els.length) {
      final which = _endpointHit(norm, sel);
      if (which != null) {
        _dragKind = which;
        _dragIndex = sel;
        return;
      }
    }
    // 2) Vorhandenes Element verschieben (ganze Auswahl/Gruppe mit)?
    final hit = _hit(norm);
    if (hit != null) {
      if (_shiftHeld || !_selection.contains(hit)) {
        _selectHit(hit, _shiftHeld);
      }
      if (_els[hit].locked == true) return; // gesperrt: nicht ziehen
      _dragKind = 'move';
      _dragIndex = hit;
      return;
    }
    // 3a) Pfeil/Zone aufziehen (Zeichen-Werkzeug).
    if (_tool == 'arrow' || _tool == 'zone') {
      final e = _snapEl(_newElement(_tool, norm, end: norm));
      setState(() {
        _els.add(e);
        _selection
          ..clear()
          ..add(_els.length - 1);
      });
      _dragKind = 'draw';
      _dragIndex = _els.length - 1;
      return;
    }
    // 3b) Hand-Werkzeug auf leerer Fläche: Rahmen-Auswahl.
    if (_tool == 'select') {
      _dragKind = 'marquee';
      _marqueeStart = norm;
      setState(() => _marquee = Rect.fromPoints(norm, norm));
    }
  }

  void _onPanUpdate(Offset norm, Offset delta, Size size) {
    if (_dragKind == 'marquee') {
      setState(() => _marquee = Rect.fromPoints(_marqueeStart ?? norm, norm));
      return;
    }
    final i = _dragIndex;
    if (i == null || i >= _els.length) return;
    // Endpunkte/Griffe fein (ohne Raster) ziehen; Objekte rasten erst am Ende.
    final p = Offset(norm.dx.clamp(0.0, 1.0), norm.dy.clamp(0.0, 1.0));
    setState(() {
      switch (_dragKind) {
        case 'move':
          final d = Offset(delta.dx / size.width, delta.dy / size.height);
          final targets = _selection.contains(i) ? _selection : {i};
          for (final j in targets) {
            if (j < _els.length) _moveBy(j, d);
          }
        case 'start':
          _els[i] = _els[i].copyWith(x: p.dx, y: p.dy);
        case 'end':
        case 'draw':
          _els[i] = _els[i].copyWith(x2: p.dx, y2: p.dy);
      }
    });
  }

  void _onPanEnd() {
    if (_dragKind == 'marquee') {
      final rect = _marquee;
      setState(() {
        if (rect != null) {
          if (!_shiftHeld) _selection.clear();
          for (var j = 0; j < _els.length; j++) {
            final e = _els[j];
            if (rect.contains(Offset(e.x, e.y))) _selection.add(j);
          }
        }
        _marquee = null;
        _marqueeStart = null;
      });
      _dragKind = null;
      _dragIndex = null;
      return;
    }
    final i = _dragIndex;
    if (_dragKind == 'move' && i != null) {
      setState(() {
        final targets = _selection.contains(i) ? _selection : {i};
        for (final j in targets) {
          if (j < _els.length) _els[j] = _snapEl(_els[j]);
        }
      });
    } else if (_dragKind == 'draw' && i != null && i < _els.length) {
      final e = _els[i];
      final len = (Offset(e.x, e.y) - Offset(e.x2 ?? e.x, e.y2 ?? e.y)).distance;
      if (len < 0.03) {
        setState(() {
          _els.removeAt(i);
          _selection.clear();
        });
      }
    }
    _dragKind = null;
    _dragIndex = null;
    _emit();
  }

  void _setSize(double v) {
    final i = _sel;
    if (i == null || i >= _els.length) return;
    setState(() => _els[i] = _els[i].copyWith(size: v));
    _emit();
  }

  void _setColor(String hex) {
    final i = _sel;
    if (i == null || i >= _els.length) return;
    setState(() => _els[i] = _els[i].copyWith(color: hex));
    _emit();
  }

  /// Öffnet einen Dialog zum Hinzufügen einer eigenen Farbe (Auswahl oder Hex),
  /// wendet sie auf das gewählte Element an und merkt sie als Favorit.
  Future<void> _addCustomColor() async {
    final i = _sel;
    if (i == null || i >= _els.length) return;
    const extra = <String>[
      '#D32F2F', '#C2185B', '#7B1FA2', '#512DA8', '#303F9F', '#1976D2',
      '#0288D1', '#0097A7', '#00796B', '#388E3C', '#689F38', '#AFB42B',
      '#FBC02D', '#FFA000', '#F57C00', '#E64A19', '#5D4037', '#616161',
      '#455A64', '#000000', '#FFFFFF',
    ];
    String? normalize(String s) {
      var h = s.trim().toUpperCase();
      if (h.isEmpty) return null;
      if (!h.startsWith('#')) h = '#$h';
      return RegExp(r'^#([0-9A-F]{6})$').hasMatch(h) ? h : null;
    }

    final ctrl = TextEditingController(text: _els[i].color ?? '#');
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) {
        String? sel = normalize(ctrl.text);
        return StatefulBuilder(
          builder: (ctx, setD) => AlertDialog(
            title: const Text('Farbe hinzufügen'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final c in extra)
                      GestureDetector(
                        onTap: () => setD(() {
                          sel = c;
                          ctrl.text = c;
                        }),
                        child: Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            color: _hexColor(c),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: sel == c ? Colors.amber : Colors.black26,
                              width: sel == c ? 3 : 1,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: ctrl,
                  autofocus: false,
                  decoration: const InputDecoration(
                    labelText: 'Hex, z.B. #FF8800',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (v) => setD(() => sel = normalize(v)),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Abbrechen'),
              ),
              FilledButton(
                onPressed: sel == null ? null : () => Navigator.pop(ctx, sel),
                child: const Text('Übernehmen'),
              ),
            ],
          ),
        );
      },
    );
    if (picked == null) return;
    _setColor(picked);
    await _addFav(picked);
  }

  /// Wendet eine Änderung auf das gewählte Element an.
  void _patch(DrillElement Function(DrillElement e) f) {
    final i = _sel;
    if (i == null || i >= _els.length) return;
    setState(() => _els[i] = f(_els[i]));
    _emit();
  }

  void _setLabel(String s) {
    final i = _sel;
    if (i == null || i >= _els.length) return;
    setState(() => _els[i] = _els[i].copyWith(label: s.trim()));
    _emit();
  }

  void _duplicate() {
    final i = _sel;
    if (i == null || i >= _els.length) return;
    final e = _els[i];
    final copy = e.copyWith(
      x: (e.x + 0.05).clamp(0.0, 1.0),
      y: (e.y + 0.05).clamp(0.0, 1.0),
      x2: e.x2 == null ? null : (e.x2! + 0.05).clamp(0.0, 1.0),
      y2: e.y2 == null ? null : (e.y2! + 0.05).clamp(0.0, 1.0),
    );
    setState(() {
      _els.add(copy);
      _selection
        ..clear()
        ..add(_els.length - 1);
    });
    _emit();
  }

  void _moveZ(bool toFront) {
    final i = _sel;
    if (i == null || i >= _els.length) return;
    setState(() {
      final e = _els.removeAt(i);
      if (toFront) {
        _els.add(e);
        _selection
          ..clear()
          ..add(_els.length - 1);
      } else {
        _els.insert(0, e);
        _selection
          ..clear()
          ..add(0);
      }
    });
    _emit();
  }

  void _deleteSelected() {
    if (_selection.isEmpty) return;
    final idx = _selection.toList()..sort((a, b) => b.compareTo(a));
    setState(() {
      for (final i in idx) {
        if (i < _els.length) _els.removeAt(i);
      }
      _selection.clear();
    });
    _emit();
  }

  void _toggleLock() {
    final i = _sel;
    if (i == null || i >= _els.length) return;
    setState(
      () => _els[i] = _els[i].copyWith(locked: !(_els[i].locked ?? false)),
    );
    _emit();
  }

  double _minOf(Iterable<double> xs) => xs.reduce((a, b) => a < b ? a : b);
  double _maxOf(Iterable<double> xs) => xs.reduce((a, b) => a > b ? a : b);

  /// Richtet die Auswahl an einer Achse aus (left/centerX/right/top/centerY/
  /// bottom). Pfeil-/Zonen-Endpunkte wandern mit.
  void _align(String axis) {
    if (_selection.length < 2) return;
    final horiz = axis == 'left' || axis == 'centerX' || axis == 'right';
    final vals = [for (final i in _selection) horiz ? _els[i].x : _els[i].y];
    final double target = axis == 'left' || axis == 'top'
        ? _minOf(vals)
        : axis == 'right' || axis == 'bottom'
        ? _maxOf(vals)
        : vals.reduce((a, b) => a + b) / vals.length;
    setState(() {
      for (final i in _selection) {
        final e = _els[i];
        if (horiz) {
          final dx = target - e.x;
          _els[i] = e.copyWith(
            x: target,
            x2: e.x2 == null ? null : (e.x2! + dx).clamp(0.0, 1.0),
          );
        } else {
          final dy = target - e.y;
          _els[i] = e.copyWith(
            y: target,
            y2: e.y2 == null ? null : (e.y2! + dy).clamp(0.0, 1.0),
          );
        }
      }
    });
    _emit();
  }

  void _group() {
    if (_selection.length < 2) return;
    final gid = 'g${DateTime.now().microsecondsSinceEpoch}';
    setState(() {
      for (final i in _selection) {
        _els[i] = _els[i].copyWith(groupId: gid);
      }
    });
    _emit();
  }

  void _ungroup() {
    setState(() {
      for (final i in _selection) {
        _els[i] = _els[i].copyWith(clearGroupId: true);
      }
    });
    _emit();
  }

  Color _hexColor(String hex) {
    var h = hex.replaceAll('#', '');
    if (h.length == 6) h = 'FF$h';
    return Color(int.tryParse(h, radix: 16) ?? 0xFF888888);
  }

  Future<void> _openFullscreen() async {
    final result = await Navigator.of(context).push<DrillDiagram>(
      MaterialPageRoute(
        builder: (_) => _FullscreenDiagramEditorPage(
          initial: DrillDiagram(
            field: _field,
            elements: List.of(_els),
            overlay: _overlay,
            animation: _animation,
          ),
        ),
      ),
    );
    if (result == null) return;
    setState(() {
      _field = result.field;
      _overlay = result.overlay;
      _animation = result.animation;
      _els = List.of(result.elements);
      _selection.clear();
    });
    _emit();
  }

  Future<String?> _promptText(String title, String hint) {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          minLines: 1,
          maxLines: 4,
          decoration: InputDecoration(hintText: hint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Los'),
          ),
        ],
      ),
    );
  }

  /// KI bearbeitet die Skizze: [create]=true erstellt eine neue, sonst wird die
  /// aktuelle aufgeräumt/verbessert.
  Future<void> _aiDiagram({required bool create}) async {
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    var focus = '';
    if (create) {
      final f = await _promptText(
        'Neue Skizze (KI)',
        'Was soll geübt werden? (optional)',
      );
      if (f == null) return; // abgebrochen
      focus = f;
    }
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Expanded(child: Text('KI arbeitet an der Skizze …')),
          ],
        ),
      ),
    );
    try {
      final res = await CloudService.aiCoach({
        'mode': 'diagram',
        'focus': focus,
        'diagram': create ? <String, dynamic>{} : _snapshot().toJson(),
      });
      nav.pop();
      final dia = res?['diagram'];
      if (dia is! Map) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Keine Antwort von der KI.')),
        );
        return;
      }
      final parsed = DrillDiagram.fromJson(
        Map<String, dynamic>.from(dia),
      ).tidy();
      if (!mounted) return;
      setState(() {
        _field = parsed.field;
        _els = List.of(parsed.elements);
        _selection.clear();
      });
      _emit();
      messenger.showSnackBar(
        SnackBar(
          content: Text(create ? 'Skizze erstellt.' : 'Skizze verbessert.'),
        ),
      );
    } catch (e) {
      nav.pop();
      messenger.showSnackBar(SnackBar(content: Text('KI-Fehler: $e')));
    }
  }

  /// KI erzeugt eine Animation (Bewegungs-Schritte) aus der aktuellen Skizze.
  Future<void> _aiAnimate() async {
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    if (_els.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Erst Objekte zeichnen.')),
      );
      return;
    }
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Expanded(child: Text('KI erstellt die Animation …')),
          ],
        ),
      ),
    );
    try {
      final res = await CloudService.aiCoach({
        'mode': 'animate',
        'diagram': _snapshot().toJson(),
      });
      nav.pop();
      final anim = res?['animation'];
      if (anim is! List) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Keine Animation von der KI.')),
        );
        return;
      }
      final steps = [
        for (final s in anim)
          DrillAnimStep.fromJson(Map<String, dynamic>.from(s as Map)),
      ];
      if (!mounted) return;
      setState(() => _animation = steps);
      _emit();
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Animation erstellt – im Lese-Modus abspielbar.'),
        ),
      );
    } catch (e) {
      nav.pop();
      messenger.showSnackBar(SnackBar(content: Text('KI-Fehler: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final toolbar = widget.fullscreen
        ? SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                for (final (id, label, icon) in _tools)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      avatar: Icon(icon, size: 18),
                      label: Text(label),
                      selected: _tool == id,
                      onSelected: (_) => setState(() => _tool = id),
                    ),
                  ),
              ],
            ),
          )
        : Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final (id, label, icon) in _tools)
                ChoiceChip(
                  avatar: Icon(icon, size: 16),
                  label: Text(label),
                  selected: _tool == id,
                  onSelected: (_) => setState(() => _tool = id),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          );

    final controls = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          IconButton(
            tooltip: 'Rückgängig',
            icon: const Icon(Icons.undo),
            onPressed: _canUndo ? _undo : null,
          ),
          IconButton(
            tooltip: 'Wiederholen',
            icon: const Icon(Icons.redo),
            onPressed: _canRedo ? _redo : null,
          ),
          PopupMenuButton<String>(
            tooltip: 'KI-Skizze',
            icon: Icon(
              Icons.auto_awesome,
              color: Theme.of(context).colorScheme.primary,
            ),
            onSelected: (v) {
              if (v == 'animate') {
                _aiAnimate();
              } else {
                _aiDiagram(create: v == 'create');
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'improve', child: Text('Skizze aufräumen')),
              PopupMenuItem(value: 'create', child: Text('Neue Skizze (KI)')),
              PopupMenuItem(value: 'animate', child: Text('Animation (KI)')),
            ],
          ),
          DropdownButton<String>(
            value: _field,
            items: const [
              DropdownMenuItem(value: 'full', child: Text('Ganzes Feld (quer)')),
              DropdownMenuItem(
                value: 'full_v',
                child: Text('Ganzes Feld (längs)'),
              ),
              DropdownMenuItem(value: 'half', child: Text('Halbfeld')),
              DropdownMenuItem(value: 'box', child: Text('Zone/Kasten')),
            ],
            onChanged: (v) {
              if (v == null) return;
              setState(() => _field = v);
              _emit();
            },
          ),
          PopupMenuButton<String?>(
            tooltip: 'Zonen-Raster',
            icon: Icon(
              Icons.grid_on,
              color: _overlay != null
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
            onSelected: (v) {
              setState(() => _overlay = v == '__none__' ? null : v);
              _emit();
            },
            itemBuilder: (_) => [
              for (final (k, l) in overlayOptions)
                PopupMenuItem<String?>(value: k ?? '__none__', child: Text(l)),
            ],
          ),
          if (!widget.fullscreen)
            IconButton(
              tooltip: 'Vollbild bearbeiten',
              icon: const Icon(Icons.fullscreen),
              onPressed: _openFullscreen,
            ),
          TextButton.icon(
            onPressed: _els.isEmpty
                ? null
                : () {
                    setState(() {
                      _els = [];
                      _selection.clear();
                    });
                    _emit();
                  },
            icon: const Icon(Icons.clear_all, size: 18),
            label: const Text('Leeren'),
          ),
        ],
      ),
    );

    // Eigenschaften-Panel: Einzel- oder Mehrfachauswahl.
    final Widget panel;
    if (_selection.length > 1) {
      panel = _multiPanel();
    } else {
      final selEl = (_sel != null && _sel! < _els.length) ? _els[_sel!] : null;
      panel = selEl == null
          ? const SizedBox.shrink()
          : _propertiesPanel(selEl);
    }

    if (widget.fullscreen) {
      final hasSel = _selection.isNotEmpty;
      return Focus(
        focusNode: _editorFocus,
        onKeyEvent: _onKey,
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(0, 8, 0, 4),
                  child: toolbar,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                  child: controls,
                ),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(8, 0, 8, hasSel ? 60 : 8),
                    child: LayoutBuilder(
                      builder: (context, c) =>
                          Center(child: _buildCanvas(c.maxWidth, c.maxHeight)),
                    ),
                  ),
                ),
              ],
            ),
            // Eigenschaften als ausziehbares Bodenblatt: bleibt eingeklappt (nur
            // Griff sichtbar), öffnet sich erst, wenn man es von unten hochzieht.
            if (hasSel)
              DraggableScrollableSheet(
                initialChildSize: 0.09,
                minChildSize: 0.09,
                maxChildSize: 0.8,
                snap: true,
                snapSizes: const [0.09, 0.5, 0.8],
                builder: (ctx, scroll) => Material(
                  elevation: 12,
                  color: Theme.of(context).canvasColor,
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(16),
                    ),
                  ),
                  child: ListView(
                    controller: scroll,
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 20),
                    children: [
                      Center(
                        child: Container(
                          width: 42,
                          height: 4,
                          margin: const EdgeInsets.only(bottom: 6),
                          decoration: BoxDecoration(
                            color: Colors.grey.withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            'Eigenschaften hochziehen',
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                      panel,
                    ],
                  ),
                ),
              ),
          ],
        ),
      );
    }

    return Focus(
      focusNode: _editorFocus,
      onKeyEvent: _onKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          toolbar,
          const SizedBox(height: 6),
          LayoutBuilder(
            builder: (context, c) => _buildCanvas(c.maxWidth, null),
          ),
          panel,
          const SizedBox(height: 2),
          controls,
        ],
      ),
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    if (_labelFocus.hasFocus) return KeyEventResult.ignored;
    final ctrl =
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final k = e.logicalKey;
    if (ctrl && k == LogicalKeyboardKey.keyZ) {
      shift ? _redo() : _undo();
      return KeyEventResult.handled;
    }
    if (ctrl && k == LogicalKeyboardKey.keyY) {
      _redo();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.delete || k == LogicalKeyboardKey.backspace) {
      if (_selection.isNotEmpty) {
        _deleteSelected();
        return KeyEventResult.handled;
      }
    }
    if (k == LogicalKeyboardKey.escape) {
      if (_selection.isNotEmpty) {
        setState(() => _selection.clear());
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  Widget _multiPanel() {
    final anyGrouped = _selection.any((i) => _els[i].groupId != null);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('${_selection.length} ausgewählt'),
              const Spacer(),
              IconButton(
                tooltip: anyGrouped ? 'Gruppierung lösen' : 'Gruppieren',
                icon: Icon(anyGrouped ? Icons.layers_clear : Icons.layers),
                onPressed: anyGrouped ? _ungroup : _group,
              ),
              IconButton(
                tooltip: 'Löschen',
                icon: const Icon(Icons.delete_outline),
                onPressed: _deleteSelected,
              ),
            ],
          ),
          Wrap(
            spacing: 2,
            children: [
              _alignBtn('left', Icons.align_horizontal_left),
              _alignBtn('centerX', Icons.align_horizontal_center),
              _alignBtn('right', Icons.align_horizontal_right),
              _alignBtn('top', Icons.align_vertical_top),
              _alignBtn('centerY', Icons.align_vertical_center),
              _alignBtn('bottom', Icons.align_vertical_bottom),
            ],
          ),
        ],
      ),
    );
  }

  Widget _alignBtn(String axis, IconData icon) => IconButton(
    tooltip: 'Ausrichten',
    icon: Icon(icon),
    visualDensity: VisualDensity.compact,
    onPressed: () => _align(axis),
  );

  Widget _propertiesPanel(DrillElement sel) {
    final usesColor =
        sel.type == 'player' ||
        sel.type == 'cone' ||
        sel.type == 'arrow' ||
        sel.type == 'zone' ||
        sel.type == 'text';
    final usesLabel = sel.type == 'player' || sel.type == 'text';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (usesColor)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Icon(Icons.palette_outlined, size: 18),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final c in _palette)
                        _swatch(
                          c,
                          (sel.color ?? '').toUpperCase() == c.toUpperCase(),
                        ),
                      for (final c in _favColors)
                        if (!_palette.any(
                          (e) => e.toUpperCase() == c.toUpperCase(),
                        ))
                          _swatch(
                            c,
                            (sel.color ?? '').toUpperCase() == c.toUpperCase(),
                            onLongPress: () => _removeFav(c),
                          ),
                      // Eigene Farbe hinzufügen (Auswahl + Hex) und anwenden.
                      GestureDetector(
                        onTap: _addCustomColor,
                        child: Container(
                          width: 26,
                          height: 26,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.black26),
                          ),
                          child: const Icon(Icons.add, size: 16),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        if (usesLabel)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              children: [
                Icon(sel.type == 'text' ? Icons.title : Icons.tag, size: 18),
                const SizedBox(width: 6),
                Expanded(
                  child: TextFormField(
                    key: ValueKey('lbl$_sel'),
                    focusNode: _labelFocus,
                    initialValue: sel.label ?? '',
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      hintText: 'Nummer / Text',
                    ),
                    onChanged: _setLabel,
                  ),
                ),
              ],
            ),
          ),
        _sliderRow(
          Icons.photo_size_select_large,
          'Größe',
          (sel.size ?? 1.0).clamp(0.4, 2.5),
          0.4,
          2.5,
          _setSize,
          percent: true,
          unit: '%',
        ),
        if (sel.type == 'cone' ||
            sel.type == 'goal' ||
            sel.type == 'minigoal' ||
            sel.type == 'text')
          _sliderRow(
            Icons.rotate_right,
            'Drehen',
            (sel.rotation ?? 0).clamp(-180.0, 180.0),
            -180,
            180,
            (v) => _patch((e) => e.copyWith(rotation: v)),
            unit: '°',
          ),
        _sliderRow(
          Icons.opacity,
          'Deckkraft',
          (sel.opacity ?? 1.0).clamp(0.1, 1.0),
          0.1,
          1.0,
          (v) => _patch((e) => e.copyWith(opacity: v)),
          percent: true,
          unit: '%',
        ),
        if (sel.type == 'arrow') _arrowControls(sel),
        if (sel.type == 'zone') _zoneControls(sel),
        Row(
          children: [
            IconButton(
              tooltip: (sel.locked ?? false) ? 'Entsperren' : 'Sperren',
              icon: Icon((sel.locked ?? false) ? Icons.lock : Icons.lock_open),
              onPressed: _toggleLock,
            ),
            const Spacer(),
            IconButton(
              tooltip: 'Nach hinten',
              icon: const Icon(Icons.flip_to_back),
              onPressed: () => _moveZ(false),
            ),
            IconButton(
              tooltip: 'Nach vorne',
              icon: const Icon(Icons.flip_to_front),
              onPressed: () => _moveZ(true),
            ),
            IconButton(
              tooltip: 'Duplizieren',
              icon: const Icon(Icons.copy),
              onPressed: _duplicate,
            ),
            IconButton(
              tooltip: 'Löschen',
              icon: const Icon(Icons.delete_outline),
              onPressed: _deleteSelected,
            ),
          ],
        ),
      ],
    );
  }

  Widget _arrowControls(DrillElement sel) {
    final lt = sel.lineType ?? (sel.dashed == true ? 'dashed' : 'solid');
    const types = [
      ('solid', 'Linie'),
      ('dashed', 'Strich'),
      ('wavy', 'Welle'),
      ('double', 'Doppelt'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final (id, label) in types)
                ChoiceChip(
                  label: Text(label),
                  selected: lt == id,
                  onSelected: (_) => _patch((e) => e.copyWith(lineType: id)),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ),
        Wrap(
          spacing: 6,
          children: [
            FilterChip(
              label: const Text('Spitze Start'),
              selected: (sel.lineStart ?? 'none') == 'arrow',
              onSelected: (v) =>
                  _patch((e) => e.copyWith(lineStart: v ? 'arrow' : 'none')),
              visualDensity: VisualDensity.compact,
            ),
            FilterChip(
              label: const Text('Spitze Ende'),
              selected: (sel.lineEnd ?? 'arrow') == 'arrow',
              onSelected: (v) =>
                  _patch((e) => e.copyWith(lineEnd: v ? 'arrow' : 'none')),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
        _sliderRow(
          Icons.gesture,
          'Bogen',
          (sel.curve ?? 0.0).clamp(-1.0, 1.0),
          -1,
          1,
          (v) => _patch((e) => e.copyWith(curve: v)),
          percent: true,
          unit: '%',
        ),
        _sliderRow(
          Icons.line_weight,
          'Stärke',
          (sel.strokeWidth ?? 2.5).clamp(1.0, 8.0),
          1,
          8,
          (v) => _patch((e) => e.copyWith(strokeWidth: v)),
          decimals: 1,
        ),
      ],
    );
  }

  Widget _zoneControls(DrillElement sel) {
    final ellipse = (sel.shape ?? 'rect') == 'ellipse';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Wrap(
            spacing: 6,
            children: [
              ChoiceChip(
                label: const Text('Rechteck'),
                selected: !ellipse,
                onSelected: (_) => _patch((e) => e.copyWith(shape: 'rect')),
                visualDensity: VisualDensity.compact,
              ),
              ChoiceChip(
                label: const Text('Ellipse'),
                selected: ellipse,
                onSelected: (_) => _patch((e) => e.copyWith(shape: 'ellipse')),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
        _sliderRow(
          Icons.opacity,
          'Füllung',
          (sel.fillOpacity ?? 0.2).clamp(0.0, 1.0),
          0,
          1,
          (v) => _patch((e) => e.copyWith(fillOpacity: v)),
          percent: true,
          unit: '%',
        ),
      ],
    );
  }

  /// Regler mit Beschriftung und synchronisiertem Zahlenfeld (Prozent/Winkel).
  Widget _sliderRow(
    IconData icon,
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged, {
    bool percent = false,
    String unit = '',
    int decimals = 0,
  }) {
    return Row(
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: 4),
        SizedBox(width: 66, child: Text(label, overflow: TextOverflow.ellipsis)),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
        const SizedBox(width: 6),
        _NumField(
          value: value,
          min: min,
          max: max,
          onChanged: onChanged,
          percent: percent,
          unit: unit,
          decimals: decimals,
        ),
      ],
    );
  }

  Widget _swatch(String hex, bool selected, {VoidCallback? onLongPress}) {
    return GestureDetector(
      onTap: () => _setColor(hex),
      onLongPress: onLongPress,
      child: Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          color: _hexColor(hex),
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? Colors.amber : Colors.black26,
            width: selected ? 3 : 1,
          ),
        ),
      ),
    );
  }

  Widget _buildCanvas(double maxW, double? maxH) {
    final aspect = aspectForField(_field); // Breite/Höhe
    var w = maxW;
    var h = w / aspect;
    if (maxH != null && h > maxH) {
      h = maxH;
      w = h * aspect;
    }
    final size = Size(w, h);
    return GestureDetector(
      onTapUp: (d) {
        _editorFocus.requestFocus();
        final n = _norm(d.localPosition, size);
        final hit = _hit(n);
        if (hit != null) {
          _selectHit(hit, _shiftHeld);
        } else if (_tool == 'select') {
          setState(() => _selection.clear());
        } else {
          _addByTap(n);
        }
      },
      onPanStart: (d) => _onPanStart(_norm(d.localPosition, size)),
      onPanUpdate: (d) =>
          _onPanUpdate(_norm(d.localPosition, size), d.delta, size),
      onPanEnd: (_) => _onPanEnd(),
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: CustomPaint(
            painter: _EditorPainter(
              DrillDiagram(field: _field, elements: _els, overlay: _overlay),
              _selection,
              _marquee,
            ),
            size: size,
          ),
        ),
      ),
    );
  }
}

/// Vollbild-Seite zum Bearbeiten der Skizze; gibt beim Schließen die bearbeitete
/// Skizze zurück.
class _FullscreenDiagramEditorPage extends StatefulWidget {
  const _FullscreenDiagramEditorPage({required this.initial});

  final DrillDiagram initial;

  @override
  State<_FullscreenDiagramEditorPage> createState() =>
      _FullscreenDiagramEditorPageState();
}

class _FullscreenDiagramEditorPageState
    extends State<_FullscreenDiagramEditorPage> {
  late DrillDiagram _current = widget.initial;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, _current);
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Skizze bearbeiten'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, _current),
              child: const Text(
                'Fertig',
                style: TextStyle(color: Colors.white),
              ),
            ),
          ],
        ),
        body: SafeArea(
          child: DrillDiagramEditor(
            initial: widget.initial,
            fullscreen: true,
            onChanged: (d) => _current = d,
          ),
        ),
      ),
    );
  }
}

/// Öffnet den Skizzen-Editor als Vollbild (mit allen Funktionen) und liefert die
/// bearbeitete Skizze zurück (null = Zurück ohne Übernahme).
Future<DrillDiagram?> editDiagramFullscreen(
  BuildContext context,
  DrillDiagram initial,
) {
  return Navigator.of(context).push<DrillDiagram>(
    MaterialPageRoute(
      builder: (_) => _FullscreenDiagramEditorPage(initial: initial),
    ),
  );
}

/// Kleines Zahlenfeld neben einem Regler. Zeigt den Wert (als Prozent oder mit
/// Einheit) und übernimmt eine Eingabe beim Verlassen/Enter. Bleibt mit dem
/// Regler synchron, solange das Feld nicht gerade bearbeitet wird.
class _NumField extends StatefulWidget {
  const _NumField({
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.percent = false,
    this.unit = '',
    this.decimals = 0,
  });

  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final bool percent;
  final String unit;
  final int decimals;

  @override
  State<_NumField> createState() => _NumFieldState();
}

class _NumFieldState extends State<_NumField> {
  late final TextEditingController _c = TextEditingController(text: _fmt());
  final FocusNode _focus = FocusNode();

  double get _shown => widget.percent ? widget.value * 100 : widget.value;

  String _fmt() => widget.decimals == 0
      ? _shown.round().toString()
      : _shown.toStringAsFixed(widget.decimals);

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(covariant _NumField old) {
    super.didUpdateWidget(old);
    // Regler bewegt → Feld nachziehen (nur wenn der Nutzer nicht gerade tippt).
    if (!_focus.hasFocus && widget.value != old.value) {
      _c.text = _fmt();
    }
  }

  void _commit() {
    final raw = double.tryParse(_c.text.trim().replaceAll(',', '.'));
    if (raw == null) {
      _c.text = _fmt();
      return;
    }
    var v = widget.percent ? raw / 100 : raw;
    v = v.clamp(widget.min, widget.max);
    widget.onChanged(v);
    _c.text = widget.decimals == 0
        ? (widget.percent ? (v * 100).round() : v.round()).toString()
        : (widget.percent ? v * 100 : v).toStringAsFixed(widget.decimals);
  }

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 72,
      child: TextField(
        controller: _c,
        focusNode: _focus,
        textAlign: TextAlign.end,
        keyboardType: const TextInputType.numberWithOptions(
          decimal: true,
          signed: true,
        ),
        decoration: InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          border: const OutlineInputBorder(),
          suffixText: widget.unit.isEmpty ? null : widget.unit,
          suffixStyle: const TextStyle(fontSize: 13),
        ),
        style: const TextStyle(fontSize: 14),
        onSubmitted: (_) => _commit(),
      ),
    );
  }
}

/// Painter wie [DrillDiagramPainter], zusätzlich Auswahl-Markierung: Ring um ein
/// Punkt-Objekt bzw. Griffe an den Endpunkten eines Pfeils/einer Zone.
class _EditorPainter extends DrillDiagramPainter {
  _EditorPainter(super.diagram, this.selected, this.marquee);
  final Set<int> selected;
  final Rect? marquee;

  @override
  void paint(Canvas canvas, Size size) {
    super.paint(canvas, size);
    final inset = size.shortestSide * 0.03;
    Offset at(double x, double y) => Offset(
      inset + x * (size.width - 2 * inset),
      inset + y * (size.height - 2 * inset),
    );
    final amber = Paint()
      ..color = Colors.amber
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;

    for (final idx in selected) {
      if (idx < 0 || idx >= diagram.elements.length) continue;
      _highlight(canvas, size, at, diagram.elements[idx], amber);
    }

    final m = marquee;
    if (m != null) {
      final rect = Rect.fromPoints(at(m.left, m.top), at(m.right, m.bottom));
      canvas.drawRect(
        rect,
        Paint()..color = Colors.amber.withValues(alpha: 0.12),
      );
      canvas.drawRect(
        rect,
        Paint()
          ..color = Colors.amber
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  void _highlight(
    Canvas canvas,
    Size size,
    Offset Function(double, double) at,
    DrillElement e,
    Paint amber,
  ) {
    if ((e.type == 'arrow' || e.type == 'zone') &&
        e.x2 != null &&
        e.y2 != null) {
      final hr = size.shortestSide * 0.016;
      _handle(canvas, at(e.x, e.y), hr, Colors.cyanAccent);
      _handle(canvas, at(e.x2!, e.y2!), hr, Colors.amber);
    } else {
      final o = at(e.x, e.y);
      final er = size.shortestSide * 0.045 * (e.size ?? 1.0);
      if (e.type == 'goal' || e.type == 'minigoal') {
        final big = e.type == 'goal';
        final w = (big ? er * 2.8 : er * 1.6) + er * 0.6;
        final h = (big ? er * 1.1 : er * 0.75) + er * 0.6;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(center: o, width: w, height: h),
            const Radius.circular(4),
          ),
          amber,
        );
      } else {
        canvas.drawCircle(o, er * 1.4, amber);
      }
    }
  }

  void _handle(Canvas c, Offset o, double r, Color color) {
    c.drawCircle(o, r, Paint()..color = color.withValues(alpha: 0.9));
    c.drawCircle(
      o,
      r,
      Paint()
        ..color = Colors.black
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant _EditorPainter old) =>
      old.diagram != diagram ||
      old.selected.length != selected.length ||
      !old.selected.containsAll(selected) ||
      old.marquee != marquee;
}
