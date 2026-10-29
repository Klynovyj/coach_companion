import 'package:flutter/material.dart';

import '../models/drill_diagram.dart';
import 'drill_diagram_view.dart';

/// Spielt eine KI-Animation der Skizze ab: Spieler/Ball bewegen sich schrittweise
/// zu ihren Zielpositionen. Pfeile (= Laufwege) werden während der Animation
/// ausgeblendet. Mit Play/Pause, Von-vorn und Schleife.
class DrillAnimationView extends StatefulWidget {
  const DrillAnimationView({super.key, required this.diagram, this.aspectRatio});

  final DrillDiagram diagram;
  final double? aspectRatio;

  @override
  State<DrillAnimationView> createState() => _DrillAnimationViewState();
}

class _DrillAnimationViewState extends State<DrillAnimationView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  bool _loop = true;

  int get _totalMs {
    var t = 0;
    for (final s in widget.diagram.animation ?? const <DrillAnimStep>[]) {
      t += s.ms > 0 ? s.ms : 1000;
    }
    return t <= 0 ? 1000 : t;
  }

  @override
  void initState() {
    super.initState();
    _ctrl =
        AnimationController(
            vsync: this,
            duration: Duration(milliseconds: _totalMs),
          )
          ..addListener(() => setState(() {}))
          ..addStatusListener((s) {
            if (s == AnimationStatus.completed && _loop) {
              _ctrl.forward(from: 0);
            }
          });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// Baut die Skizze für den aktuellen Fortschritt (interpolierte Positionen).
  DrillDiagram _frame() {
    final d = widget.diagram;
    final steps = d.animation ?? const <DrillAnimStep>[];
    final pos = [for (final e in d.elements) Offset(e.x, e.y)];
    if (steps.isNotEmpty) {
      var elapsed = _ctrl.value * _totalMs; // ms
      for (final s in steps) {
        final dur = (s.ms > 0 ? s.ms : 1000).toDouble();
        final t = (elapsed / dur).clamp(0.0, 1.0);
        for (final m in s.moves) {
          if (m.index < 0 || m.index >= pos.length) continue;
          pos[m.index] = Offset.lerp(pos[m.index], Offset(m.x, m.y), t)!;
        }
        if (t >= 1.0) {
          elapsed -= dur;
        } else {
          break;
        }
      }
    }
    final els = <DrillElement>[];
    for (var i = 0; i < d.elements.length; i++) {
      final e = d.elements[i];
      if (e.type == 'arrow') continue; // Laufwege während Animation ausblenden
      els.add(e.copyWith(x: pos[i].dx, y: pos[i].dy));
    }
    return DrillDiagram(field: d.field, overlay: d.overlay, elements: els);
  }

  List<int> get _cumMs {
    final out = <int>[];
    var t = 0;
    for (final s in widget.diagram.animation ?? const <DrillAnimStep>[]) {
      t += s.ms > 0 ? s.ms : 1000;
      out.add(t);
    }
    return out;
  }

  int get _currentStep {
    final steps = widget.diagram.animation ?? const <DrillAnimStep>[];
    if (steps.isEmpty) return 0;
    final elapsed = _ctrl.value * _totalMs;
    final cum = _cumMs;
    for (var i = 0; i < cum.length; i++) {
      if (elapsed < cum[i] - 0.5) return i;
    }
    return steps.length - 1;
  }

  void _seekStep(int i) {
    final steps = widget.diagram.animation ?? const <DrillAnimStep>[];
    if (steps.isEmpty) return;
    final idx = i.clamp(0, steps.length - 1);
    final startMs = idx == 0 ? 0 : _cumMs[idx - 1];
    _ctrl.stop();
    setState(() => _ctrl.value = (startMs / _totalMs).clamp(0.0, 1.0));
  }

  void _togglePlay() {
    if (_ctrl.isAnimating) {
      _ctrl.stop();
    } else if (_ctrl.value >= 1.0) {
      _ctrl.forward(from: 0);
    } else {
      _ctrl.forward();
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final steps = widget.diagram.animation ?? const <DrillAnimStep>[];
    final cur = _currentStep;
    final label = cur < steps.length ? steps[cur].label : null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        DrillDiagramView(diagram: _frame(), aspectRatio: widget.aspectRatio),
        const SizedBox(height: 8),
        // Timeline: Schritt-Chips
        if (steps.length > 1)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (var i = 0; i < steps.length; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: GestureDetector(
                      onTap: () => _seekStep(i),
                      child: Container(
                        width: 30,
                        height: 30,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: i == cur ? primary : primary.withValues(alpha: 0.15),
                        ),
                        child: Text(
                          '${i + 1}',
                          style: TextStyle(
                            color: i == cur ? Colors.white : primary,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        if (label != null && label.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: Text(
              'Schritt ${cur + 1}: ${label.trim()}',
              textAlign: TextAlign.center,
              style: const TextStyle(height: 1.3),
            ),
          ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              tooltip: 'Schritt zurück',
              icon: const Icon(Icons.skip_previous),
              onPressed: steps.length > 1 ? () => _seekStep(cur - 1) : null,
            ),
            IconButton(
              tooltip: _ctrl.isAnimating ? 'Pause' : 'Abspielen',
              icon: Icon(
                _ctrl.isAnimating ? Icons.pause : Icons.play_arrow,
                size: 32,
              ),
              onPressed: _togglePlay,
            ),
            IconButton(
              tooltip: 'Schritt vor',
              icon: const Icon(Icons.skip_next),
              onPressed: steps.length > 1 ? () => _seekStep(cur + 1) : null,
            ),
            IconButton(
              tooltip: 'Von vorn',
              icon: const Icon(Icons.replay),
              onPressed: () => _ctrl.forward(from: 0),
            ),
            IconButton(
              tooltip: 'Schleife',
              icon: Icon(Icons.loop, color: _loop ? primary : null),
              onPressed: () => setState(() => _loop = !_loop),
            ),
          ],
        ),
      ],
    );
  }
}
