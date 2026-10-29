import 'package:flutter/material.dart';

import '../../models/drill_diagram.dart';
import '../../widgets/drill_diagram_view.dart';

/// Bearbeitbare Übungs-Skizze: Werkzeug wählen, auf das Feld tippen zum
/// Hinzufügen, vorhandene Elemente ziehen zum Verschieben, Auswahl löschen.
class DrillDiagramEditor extends StatefulWidget {
  const DrillDiagramEditor({
    super.key,
    required this.initial,
    required this.onChanged,
  });

  final DrillDiagram initial;
  final ValueChanged<DrillDiagram> onChanged;

  @override
  State<DrillDiagramEditor> createState() => _DrillDiagramEditorState();
}

class _DrillDiagramEditorState extends State<DrillDiagramEditor> {
  late List<DrillElement> _els = List.of(widget.initial.elements);
  late String _field = widget.initial.field;
  String _tool = 'player';
  int? _selected;
  int? _dragging;

  static const _tools = <(String, String, IconData)>[
    ('player', 'Spieler', Icons.person),
    ('opp', 'Gegner', Icons.person_outline),
    ('cone', 'Hütchen', Icons.change_history),
    ('goal', 'Tor', Icons.sports_soccer),
    ('ball', 'Ball', Icons.circle),
    ('arrow', 'Pfeil', Icons.north_east),
    ('zone', 'Zone', Icons.crop_square),
    ('text', 'Text', Icons.title),
  ];

  void _emit() =>
      widget.onChanged(DrillDiagram(field: _field, elements: List.of(_els)));

  int? _hit(Offset norm) {
    int? best;
    double bestD = 0.06; // Trefferschwelle (relativ)
    for (var i = 0; i < _els.length; i++) {
      final e = _els[i];
      final d = (Offset(e.x, e.y) - norm).distance;
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    return best;
  }

  Offset _norm(Offset local, Size size) {
    final inset = size.shortestSide * 0.04;
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
      _els.add(DrillElement(type: 'text', x: norm.dx, y: norm.dy, label: text));
      _selected = _els.length - 1;
    });
    _emit();
  }

  void _add(Offset norm) {
    if (_tool == 'text') {
      _addText(norm);
      return;
    }
    final DrillElement e;
    switch (_tool) {
      case 'opp':
        e = DrillElement(
          type: 'player',
          x: norm.dx,
          y: norm.dy,
          color: '#C62828',
        );
      case 'arrow':
        e = DrillElement(
          type: 'arrow',
          x: norm.dx,
          y: norm.dy,
          x2: (norm.dx + 0.18).clamp(0.0, 1.0),
          y2: (norm.dy - 0.12).clamp(0.0, 1.0),
        );
      case 'zone':
        e = DrillElement(
          type: 'zone',
          x: norm.dx,
          y: norm.dy,
          x2: (norm.dx + 0.22).clamp(0.0, 1.0),
          y2: (norm.dy + 0.18).clamp(0.0, 1.0),
        );
      default:
        e = DrillElement(type: _tool, x: norm.dx, y: norm.dy);
    }
    setState(() {
      _els.add(e);
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

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Werkzeug-Leiste.
        Wrap(
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
        ),
        const SizedBox(height: 6),
        LayoutBuilder(
          builder: (context, c) {
            final size = Size(c.maxWidth, c.maxWidth / 1.5);
            return GestureDetector(
              onTapUp: (d) {
                final n = _norm(d.localPosition, size);
                final hit = _hit(n);
                if (hit != null) {
                  setState(() => _selected = hit);
                } else {
                  _add(n);
                }
              },
              onPanStart: (d) {
                final n = _norm(d.localPosition, size);
                final hit = _hit(n);
                if (hit != null) {
                  setState(() {
                    _dragging = hit;
                    _selected = hit;
                  });
                }
              },
              onPanUpdate: (d) {
                if (_dragging == null) return;
                setState(() {
                  _moveBy(
                    _dragging!,
                    Offset(d.delta.dx / size.width, d.delta.dy / size.height),
                  );
                });
              },
              onPanEnd: (_) {
                if (_dragging != null) {
                  _dragging = null;
                  _emit();
                }
              },
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
          },
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            DropdownButton<String>(
              value: _field,
              items: const [
                DropdownMenuItem(value: 'full', child: Text('Ganzes Feld')),
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
            IconButton(
              tooltip: 'Auswahl löschen',
              icon: const Icon(Icons.delete_outline),
              onPressed: _selected == null
                  ? null
                  : () {
                      setState(() {
                        _els.removeAt(_selected!);
                        _selected = null;
                      });
                      _emit();
                    },
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
        ),
      ],
    );
  }
}

/// Painter wie [DrillDiagramPainter], zusätzlich ein Ring um das gewählte
/// Element.
class _EditorPainter extends DrillDiagramPainter {
  _EditorPainter(super.diagram, this.selected);
  final int? selected;

  @override
  void paint(Canvas canvas, Size size) {
    super.paint(canvas, size);
    if (selected == null || selected! >= diagram.elements.length) return;
    final e = diagram.elements[selected!];
    final inset = size.shortestSide * 0.04;
    final o = Offset(
      inset + e.x * (size.width - 2 * inset),
      inset + e.y * (size.height - 2 * inset),
    );
    canvas.drawCircle(
      o,
      size.shortestSide * 0.07,
      Paint()
        ..color = Colors.amber
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
  }

  @override
  bool shouldRepaint(covariant _EditorPainter old) =>
      old.diagram != diagram || old.selected != selected;
}
