import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/drill_diagram.dart';
import '../../models/exercise.dart';
import '../../services/cloud_service.dart';
import '../../state/app_state.dart';
import '../../widgets/drill_animation_view.dart';
import '../../widgets/drill_diagram_view.dart';
import '../../widgets/photo_viewer.dart';
import '../../widgets/team_logo.dart';
import 'drill_diagram_editor.dart';

/// Übung im bequemen Lese-Modus: eine Karte pro Sektion, horizontal
/// durchwischen (wie die Gegner-Analyse). Bearbeiten direkt pro Karte über den
/// Stift in der Karten-Kopfzeile – kein globaler Umschalter.
class ExerciseDetailScreen extends StatefulWidget {
  const ExerciseDetailScreen({super.key, required this.exercise});

  final Exercise exercise;

  @override
  State<ExerciseDetailScreen> createState() => _ExerciseDetailScreenState();
}

class _ReadPage {
  final IconData icon;
  final Color color;
  final String title;
  final Widget body;
  final VoidCallback? onEdit;
  const _ReadPage(this.icon, this.color, this.title, this.body, {this.onEdit});
}

class _ExerciseDetailScreenState extends State<ExerciseDetailScreen> {
  late Exercise _ex = widget.exercise;

  Future<void> _save(Exercise updated) async {
    final state = context.read<AppState>();
    setState(() => _ex = updated);
    await state.upsertExercise(updated);
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  /// Fokussierter Editor für genau ein Textfeld (eine Karte).
  Future<void> _editText(
    String title,
    String current,
    Exercise Function(Exercise e, String v) apply,
  ) async {
    final ctrl = TextEditingController(text: current);
    final res = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: double.maxFinite,
          child: TextField(
            controller: ctrl,
            autofocus: true,
            minLines: 6,
            maxLines: 16,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
    if (res != null) _save(apply(_ex, res.trim()));
  }

  Future<void> _editDiagram() async {
    final res = await editDiagramFullscreen(
      context,
      _ex.diagram ?? const DrillDiagram(field: 'box'),
    );
    if (res == null) return;
    _save(
      _ex.copyWith(
        diagram: res.isEmpty ? null : res,
        clearDiagram: res.isEmpty,
      ),
    );
  }

  /// KI erzeugt/überarbeitet die Animation der Skizze.
  Future<void> _aiAnimate() async {
    final e = _ex;
    if (e.diagram == null || e.diagram!.elements.isEmpty) {
      _snack('Erst eine Skizze anlegen (Übersicht → Skizze bearbeiten).');
      return;
    }
    final nav = Navigator.of(context);
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
        'diagram': e.diagram!.toJson(),
        'ablauf': e.ablauf,
      });
      nav.pop();
      final anim = res?['animation'];
      if (anim is! List) {
        _snack('Keine Animation von der KI.');
        return;
      }
      final steps = [
        for (final s in anim)
          DrillAnimStep.fromJson(Map<String, dynamic>.from(s as Map)),
      ];
      _save(e.copyWith(diagram: e.diagram!.copyWith(animation: steps)));
    } catch (err) {
      nav.pop();
      _snack('KI-Fehler: $err');
    }
  }
  final _pc = PageController();
  int _page = 0;

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  List<_ReadPage> _buildPages(Exercise e) {
    final pages = <_ReadPage>[
      _ReadPage(
        Icons.info_outline,
        const Color(0xFF2E7D4F),
        'Übersicht',
        _overview(e),
        onEdit: _editDiagram,
      ),
      // Animations-Karte immer (Play wenn vorhanden, sonst „Mit KI erstellen").
      _ReadPage(
        Icons.play_circle_outline,
        const Color(0xFF00695C),
        'Animation',
        _animationBody(e),
      ),
    ];
    void textPage(
      IconData i,
      Color c,
      String t,
      String current,
      Exercise Function(Exercise e, String v) setField,
    ) {
      pages.add(
        _ReadPage(
          i,
          c,
          t,
          current.trim().isEmpty ? _emptyBody() : _textBody(current),
          onEdit: () => _editText(t, current, setField),
        ),
      );
    }

    textPage(
      Icons.architecture,
      const Color(0xFF1565C0),
      'Aufbau',
      e.aufbau,
      (x, v) => x.copyWith(aufbau: v),
    );
    textPage(
      Icons.format_list_numbered,
      const Color(0xFF3F51B5),
      'Ablauf',
      e.ablauf,
      (x, v) => x.copyWith(ablauf: v),
    );
    textPage(
      Icons.sports,
      const Color(0xFF00897B),
      'Coaching-Punkte',
      e.coachingPoints,
      (x, v) => x.copyWith(coachingPoints: v),
    );
    textPage(
      Icons.tune,
      const Color(0xFF7E57C2),
      'Varianten',
      e.varianten,
      (x, v) => x.copyWith(varianten: v),
    );
    textPage(
      Icons.inventory_2_outlined,
      const Color(0xFF8D6E63),
      'Material',
      e.material,
      (x, v) => x.copyWith(material: v),
    );
    if (e.videoLinks.isNotEmpty) {
      pages.add(
        _ReadPage(
          Icons.ondemand_video,
          const Color(0xFFC62828),
          'Videos',
          _videos(e),
        ),
      );
    }
    if (e.sketchPhotoUrl != null) {
      pages.add(
        _ReadPage(
          Icons.photo_camera,
          const Color(0xFF546E7A),
          'Original-Skizze',
          _photo(e),
        ),
      );
    }
    return pages;
  }

  Widget _emptyBody() => const Center(
    child: Padding(
      padding: EdgeInsets.all(24),
      child: Text(
        'Noch nichts. Tippe oben auf ✎ zum Hinzufügen.',
        textAlign: TextAlign.center,
        style: TextStyle(color: Colors.grey),
      ),
    ),
  );

  Widget _overview(Exercise e) {
    final meta = <String>[
      if (e.minPlayers != null) 'ab ${e.minPlayers} Spielern',
      if ((e.goalkeepers ?? 0) > 0)
        '${e.goalkeepers} Torhüter'
      else if (e.needsGoalkeeper)
        'Torwart nötig',
      if (e.durationMin != null) '${e.durationMin} Min',
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      children: [
        if (e.categories.isNotEmpty)
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [for (final c in e.categories) Chip(label: Text(c))],
          ),
        if (meta.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              meta.join('  ·  '),
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ),
        if (e.diagram != null) ...[
          const SizedBox(height: 14),
          GestureDetector(
            onTap: () => _openDiagram(e.diagram!),
            child: DrillDiagramView(diagram: e.diagram!),
          ),
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text(
              'Zum Vergrößern antippen',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
        ],
      ],
    );
  }

  Widget _animationBody(Exercise e) {
    final hasAnim =
        e.diagram?.animation != null && e.diagram!.animation!.isNotEmpty;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      children: [
        if (hasAnim)
          DrillAnimationView(diagram: e.diagram!)
        else
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Column(
              children: [
                Icon(Icons.movie_outlined, size: 48, color: Colors.grey),
                SizedBox(height: 8),
                Text(
                  'Noch keine Animation.\nLass die KI die Übung beleben.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey),
                ),
              ],
            ),
          ),
        const SizedBox(height: 12),
        Center(
          child: FilledButton.icon(
            onPressed: _aiAnimate,
            icon: const Icon(Icons.auto_awesome),
            label: Text(hasAnim ? 'Neu generieren (KI)' : 'Mit KI erstellen'),
          ),
        ),
      ],
    );
  }

  Widget _textBody(String s) => ListView(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
    children: [for (final line in s.trim().split('\n')) _line(line)],
  );

  Widget _line(String raw) {
    final t = raw.trimRight();
    final style = Theme.of(
      context,
    ).textTheme.bodyLarge?.copyWith(height: 1.4, fontSize: 16);
    final primary = Theme.of(context).colorScheme.primary;
    if (t.trim().isEmpty) return const SizedBox(height: 8);
    final numbered = RegExp(r'^\s*(\d+)[.)]\s+');
    final bullet = RegExp(r'^\s*[-•*]\s+');
    final nm = numbered.firstMatch(t);
    if (nm != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 26,
              child: Text(
                '${nm.group(1)}.',
                style: style?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: primary,
                ),
              ),
            ),
            Expanded(child: SelectableText(t.substring(nm.end), style: style)),
          ],
        ),
      );
    }
    if (bullet.hasMatch(t)) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 7, left: 2, right: 10),
              child: Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(shape: BoxShape.circle, color: primary),
              ),
            ),
            Expanded(
              child: SelectableText(t.replaceFirst(bullet, ''), style: style),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: SelectableText(t, style: style),
    );
  }

  Widget _videos(Exercise e) => ListView(
    padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
    children: [
      for (final link in e.videoLinks)
        ListTile(
          leading: const Icon(Icons.ondemand_video),
          title: Text(link, maxLines: 2, overflow: TextOverflow.ellipsis),
          onTap: () =>
              launchUrl(Uri.parse(link), mode: LaunchMode.externalApplication),
        ),
    ],
  );

  Widget _photo(Exercise e) {
    final bytes = TeamLogo.decode(e.sketchPhotoUrl);
    if (bytes == null) return const SizedBox.shrink();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      children: [
        GestureDetector(
          onTap: () => showPhotoFullscreen(context, bytes),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.memory(bytes, fit: BoxFit.contain),
          ),
        ),
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text(
            'Zum Vergrößern antippen',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
      ],
    );
  }

  void _openDiagram(DrillDiagram d) {
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.black,
        pageBuilder: (_, _, _) => Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            children: [
              Positioned.fill(
                child: InteractiveViewer(
                  minScale: 1,
                  maxScale: 5,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: DrillDiagramView(diagram: d),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: MediaQuery.of(context).padding.top + 8,
                right: 8,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white, size: 28),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final e = _ex;
    final pages = _buildPages(e);
    if (_page >= pages.length) _page = pages.length - 1;
    return Scaffold(
      appBar: AppBar(title: Text(e.title)),
      body: Column(
        children: [
          Expanded(
            child: PageView.builder(
              controller: _pc,
              onPageChanged: (i) => setState(() => _page = i),
              itemCount: pages.length,
              itemBuilder: (_, i) => _card(pages[i], i, pages.length),
            ),
          ),
          if (pages.length > 1) _navBar(pages.length),
        ],
      ),
    );
  }

  Widget _card(_ReadPage p, int i, int n) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
    child: Card(
      elevation: 3,
      color: Theme.of(context).colorScheme.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: p.color,
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
            child: Row(
              children: [
                Icon(p.icon, color: Colors.white, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    p.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                if (p.onEdit != null)
                  IconButton(
                    tooltip: 'Bearbeiten',
                    icon: const Icon(Icons.edit, color: Colors.white, size: 20),
                    onPressed: p.onEdit,
                    visualDensity: VisualDensity.compact,
                  ),
                Text(
                  '${i + 1}/$n',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.85)),
                ),
              ],
            ),
          ),
          Expanded(child: p.body),
        ],
      ),
    ),
  );

  Widget _navBar(int n) {
    final primary = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 8),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: _page > 0
                ? () => _pc.previousPage(
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOut,
                  )
                : null,
          ),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < n; i++)
                  Container(
                    width: i == _page ? 10 : 7,
                    height: i == _page ? 10 : 7,
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i == _page
                          ? primary
                          : primary.withValues(alpha: 0.3),
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: _page < n - 1
                ? () => _pc.nextPage(
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOut,
                  )
                : null,
          ),
        ],
      ),
    );
  }
}
