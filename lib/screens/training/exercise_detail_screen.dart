import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/drill_diagram.dart';
import '../../models/exercise.dart';
import '../../widgets/drill_animation_view.dart';
import '../../widgets/drill_diagram_view.dart';
import '../../widgets/photo_viewer.dart';
import '../../widgets/team_logo.dart';

/// Übung im bequemen Lese-Modus: eine Karte pro Sektion, horizontal
/// durchwischen (wie die Gegner-Analyse). Bearbeiten-Stift in der AppBar.
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
  const _ReadPage(this.icon, this.color, this.title, this.body);
}

class _ExerciseDetailScreenState extends State<ExerciseDetailScreen> {
  late final Exercise _ex = widget.exercise;
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
      ),
    ];
    if (e.diagram?.animation != null && e.diagram!.animation!.isNotEmpty) {
      pages.add(
        _ReadPage(
          Icons.play_circle_outline,
          const Color(0xFF00695C),
          'Animation',
          _animationBody(e),
        ),
      );
    }
    void textPage(IconData i, Color c, String t, String s) {
      if (s.trim().isNotEmpty) pages.add(_ReadPage(i, c, t, _textBody(s)));
    }

    textPage(Icons.architecture, const Color(0xFF1565C0), 'Aufbau', e.aufbau);
    textPage(
      Icons.format_list_numbered,
      const Color(0xFF3F51B5),
      'Ablauf',
      e.ablauf,
    );
    textPage(
      Icons.sports,
      const Color(0xFF00897B),
      'Coaching-Punkte',
      e.coachingPoints,
    );
    textPage(Icons.tune, const Color(0xFF7E57C2), 'Varianten', e.varianten);
    textPage(
      Icons.inventory_2_outlined,
      const Color(0xFF8D6E63),
      'Material',
      e.material,
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

  Widget _animationBody(Exercise e) => ListView(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
    children: [DrillAnimationView(diagram: e.diagram!)],
  );

  Widget _textBody(String s) => ListView(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
    children: [
      SelectableText(
        s.trim(),
        style: Theme.of(
          context,
        ).textTheme.bodyLarge?.copyWith(height: 1.45, fontSize: 16),
      ),
    ],
  );

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
