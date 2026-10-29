import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/drill_diagram.dart';
import '../../widgets/drill_diagram_view.dart';

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
  String _tool = 'select';
  int? _selected;

  // Aktiver Zug: Art ('move' | 'start' | 'end' | 'draw') + betroffenes Element.
  String? _dragKind;
  int? _dragIndex;

  // Favoriten-Farben (persistent über shared_preferences).
  static const _favKey = 'skizze_color_favorites';
  List<String> _favColors = [];

  @override
  void initState() {
    super.initState();
    _loadFavs();
  }

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
  Offset _snap(Offset n) => Offset(_snapV(n.dx), _snapV(n.dy));
  DrillElement _snapEl(DrillElement e) => e.copyWith(
    x: _snapV(e.x),
    y: _snapV(e.y),
    x2: e.x2 == null ? null : _snapV(e.x2!),
    y2: e.y2 == null ? null : _snapV(e.y2!),
  );

  void _emit() =>
      widget.onChanged(DrillDiagram(field: _field, elements: List.of(_els)));

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
      _selected = _els.length - 1;
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
      _selected = _els.length - 1;
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

  void _onPanStart(Offset norm) {
    // 1) Endpunkt des gewählten Pfeils/Zone ziehen?
    if (_selected != null && _selected! < _els.length) {
      final which = _endpointHit(norm, _selected!);
      if (which != null) {
        _dragKind = which;
        _dragIndex = _selected;
        return;
      }
    }
    // 2) Vorhandenes Element verschieben?
    final hit = _hit(norm);
    if (hit != null) {
      setState(() => _selected = hit);
      _dragKind = 'move';
      _dragIndex = hit;
      return;
    }
    // 3) Auf leerer Fläche: Pfeil/Zone aufziehen.
    if (_tool == 'arrow' || _tool == 'zone') {
      final e = _snapEl(_newElement(_tool, norm, end: norm));
      setState(() {
        _els.add(e);
        _selected = _els.length - 1;
      });
      _dragKind = 'draw';
      _dragIndex = _selected;
    }
  }

  void _onPanUpdate(Offset norm, Offset delta, Size size) {
    final i = _dragIndex;
    if (i == null || i >= _els.length) return;
    // Start/Ende/Ziehen rasten aufs Gitter; Verschieben läuft übers Delta und
    // rastet erst beim Loslassen (_onPanEnd).
    final snapped = _snap(norm);
    setState(() {
      switch (_dragKind) {
        case 'move':
          _moveBy(i, Offset(delta.dx / size.width, delta.dy / size.height));
        case 'start':
          _els[i] = _els[i].copyWith(x: snapped.dx, y: snapped.dy);
        case 'end':
        case 'draw':
          _els[i] = _els[i].copyWith(x2: snapped.dx, y2: snapped.dy);
      }
    });
  }

  void _onPanEnd() {
    final i = _dragIndex;
    if (_dragKind == 'move' && i != null && i < _els.length) {
      setState(() => _els[i] = _snapEl(_els[i])); // beim Loslassen aufs Raster
    } else if (_dragKind == 'draw' && i != null && i < _els.length) {
      final e = _els[i];
      final len = (Offset(e.x, e.y) - Offset(e.x2 ?? e.x, e.y2 ?? e.y)).distance;
      if (len < 0.03) {
        // Zu kurz gezogen → verwerfen.
        setState(() {
          _els.removeAt(i);
          _selected = null;
        });
      }
    }
    _dragKind = null;
    _dragIndex = null;
    _emit();
  }

  void _setSize(double v) {
    final i = _selected;
    if (i == null || i >= _els.length) return;
    setState(() => _els[i] = _els[i].copyWith(size: v));
    _emit();
  }

  void _setColor(String hex) {
    final i = _selected;
    if (i == null || i >= _els.length) return;
    setState(() => _els[i] = _els[i].copyWith(color: hex));
    _emit();
  }

  /// Wendet eine Änderung auf das gewählte Element an.
  void _patch(DrillElement Function(DrillElement e) f) {
    final i = _selected;
    if (i == null || i >= _els.length) return;
    setState(() => _els[i] = f(_els[i]));
    _emit();
  }

  void _setLabel(String s) {
    final i = _selected;
    if (i == null || i >= _els.length) return;
    setState(() => _els[i] = _els[i].copyWith(label: s.trim()));
    _emit();
  }

  void _duplicate() {
    final i = _selected;
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
      _selected = _els.length - 1;
    });
    _emit();
  }

  void _moveZ(bool toFront) {
    final i = _selected;
    if (i == null || i >= _els.length) return;
    setState(() {
      final e = _els.removeAt(i);
      if (toFront) {
        _els.add(e);
        _selected = _els.length - 1;
      } else {
        _els.insert(0, e);
        _selected = 0;
      }
    });
    _emit();
  }

  void _deleteSelected() {
    final i = _selected;
    if (i == null || i >= _els.length) return;
    setState(() {
      _els.removeAt(i);
      _selected = null;
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
          initial: DrillDiagram(field: _field, elements: List.of(_els)),
        ),
      ),
    );
    if (result == null) return;
    setState(() {
      _field = result.field;
      _els = List.of(result.elements);
      _selected = null;
    });
    _emit();
  }

  @override
  Widget build(BuildContext context) {
    final toolbar = Wrap(
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

    final controls = Row(
      children: [
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
        const Spacer(),
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
                    _selected = null;
                  });
                  _emit();
                },
          icon: const Icon(Icons.clear_all, size: 18),
          label: const Text('Leeren'),
        ),
      ],
    );

    // Eigenschaften-Panel für das gewählte Objekt.
    final selEl = (_selected != null && _selected! < _els.length)
        ? _els[_selected!]
        : null;
    final panel = selEl == null
        ? const SizedBox.shrink()
        : _propertiesPanel(selEl);

    if (widget.fullscreen) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.all(8), child: toolbar),
          Expanded(
            child: LayoutBuilder(
              builder: (context, c) =>
                  Center(child: _buildCanvas(c.maxWidth, c.maxHeight)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: panel,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: controls,
          ),
        ],
      );
    }

    return Column(
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
    );
  }

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
                      // Aktuelle Farbe als Favorit speichern.
                      GestureDetector(
                        onTap: () {
                          if (sel.color != null) _addFav(sel.color!);
                        },
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
                    key: ValueKey('lbl$_selected'),
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
        Row(
          children: [
            const Icon(Icons.photo_size_select_large, size: 18),
            const SizedBox(width: 4),
            const Text('Größe'),
            Expanded(
              child: Slider(
                value: (sel.size ?? 1.0).clamp(0.4, 2.5),
                min: 0.4,
                max: 2.5,
                onChanged: _setSize,
              ),
            ),
          ],
        ),
        if (sel.type == 'arrow') _arrowControls(sel),
        if (sel.type == 'zone') _zoneControls(sel),
        Row(
          children: [
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
        Row(
          children: [
            const Icon(Icons.gesture, size: 18),
            const SizedBox(width: 4),
            const Text('Bogen'),
            Expanded(
              child: Slider(
                value: (sel.curve ?? 0.0).clamp(-1.0, 1.0),
                min: -1,
                max: 1,
                onChanged: (v) => _patch((e) => e.copyWith(curve: v)),
              ),
            ),
          ],
        ),
        Row(
          children: [
            const Icon(Icons.line_weight, size: 18),
            const SizedBox(width: 4),
            const Text('Stärke'),
            Expanded(
              child: Slider(
                value: (sel.strokeWidth ?? 2.5).clamp(1.0, 8.0),
                min: 1,
                max: 8,
                onChanged: (v) => _patch((e) => e.copyWith(strokeWidth: v)),
              ),
            ),
          ],
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
        Row(
          children: [
            const Icon(Icons.opacity, size: 18),
            const SizedBox(width: 4),
            const Text('Füllung'),
            Expanded(
              child: Slider(
                value: (sel.fillOpacity ?? 0.2).clamp(0.0, 1.0),
                min: 0,
                max: 1,
                onChanged: (v) => _patch((e) => e.copyWith(fillOpacity: v)),
              ),
            ),
          ],
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
        final n = _norm(d.localPosition, size);
        final hit = _hit(n);
        if (hit != null) {
          setState(() => _selected = hit);
        } else if (_tool == 'select') {
          setState(() => _selected = null);
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
              DrillDiagram(field: _field, elements: _els),
              _selected,
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

/// Painter wie [DrillDiagramPainter], zusätzlich Auswahl-Markierung: Ring um ein
/// Punkt-Objekt bzw. Griffe an den Endpunkten eines Pfeils/einer Zone.
class _EditorPainter extends DrillDiagramPainter {
  _EditorPainter(super.diagram, this.selected);
  final int? selected;

  @override
  void paint(Canvas canvas, Size size) {
    super.paint(canvas, size);
    if (selected == null || selected! >= diagram.elements.length) return;
    final e = diagram.elements[selected!];
    final inset = size.shortestSide * 0.03;
    Offset at(double x, double y) => Offset(
      inset + x * (size.width - 2 * inset),
      inset + y * (size.height - 2 * inset),
    );

    final amber = Paint()
      ..color = Colors.amber
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;

    if ((e.type == 'arrow' || e.type == 'zone') &&
        e.x2 != null &&
        e.y2 != null) {
      final hr = size.shortestSide * 0.028;
      // Start (cyan) und Ende (gelb) als ziehbare Griffe.
      _handle(canvas, at(e.x, e.y), hr, Colors.cyanAccent);
      _handle(canvas, at(e.x2!, e.y2!), hr, Colors.amber);
    } else {
      // Markierung umschließt das Objekt passend (zentriert auf seiner Position).
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
      old.diagram != diagram || old.selected != selected;
}
