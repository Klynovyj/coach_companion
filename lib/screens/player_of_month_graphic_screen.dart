import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/player.dart';
import '../models/player_stat.dart';
import '../models/sponsor.dart';
import '../services/share_service.dart';
import '../state/app_state.dart';
import '../widgets/team_logo.dart';

/// Ausgabeformate für den Spieler des Monats.
enum _Fmt { post, story, urkunde }

extension _FmtX on _Fmt {
  String get label => switch (this) {
    _Fmt.post => 'Post 1:1',
    _Fmt.story => 'Story 9:16',
    _Fmt.urkunde => 'Urkunde A4',
  };

  // Logische Zeichengröße (Breite×Höhe) und Export-Zielbreite in Pixeln.
  Size get logical => switch (this) {
    _Fmt.post => const Size(360, 360),
    _Fmt.story => const Size(360, 640),
    _Fmt.urkunde => const Size(420, 594), // A4-Verhältnis 210:297
  };

  double get targetWidth => switch (this) {
    _Fmt.post => 1080, // 1080×1080
    _Fmt.story => 1080, // 1080×1920
    _Fmt.urkunde => 1748, // ≈1748×2472 (210 dpi)
  };

  String get fileSuffix => switch (this) {
    _Fmt.post => 'Post',
    _Fmt.story => 'Story',
    _Fmt.urkunde => 'Urkunde-A4',
  };
}

const _green = Color(0xFF0B6B43);
const _greenDark = Color(0xFF0E3D28);
const _gold = Color(0xFFC9A24B);
const _paper = Color(0xFFFBF7EE);
const _ink = Color(0xFF1F2A24);

/// Erzeugt die teilbaren Grafiken zum „Spieler des Monats": moderne
/// Social-Grafik (Instagram Post 1:1 / Story 9:16) und klassische DIN-A4-
/// Urkunde zum Drucken. Enthält Monatsnote, Monats-Ereignisse (live getrackt),
/// FuPa-Saison und die Sponsoren-Leiste. Export per RepaintBoundary → PNG über
/// das System-Teilen-Menü (Handy, inkl. Instagram) bzw. Download (Desktop).
class PlayerOfMonthGraphicScreen extends StatefulWidget {
  const PlayerOfMonthGraphicScreen({
    super.key,
    required this.player,
    required this.yearMonth,
    required this.avg,
    required this.ratedCount,
    required this.teamName,
    required this.teamLogo,
  });

  final Player player;
  final String yearMonth; // YYYY-MM
  final double? avg;
  final int ratedCount;
  final String teamName;
  final String? teamLogo;

  @override
  State<PlayerOfMonthGraphicScreen> createState() =>
      _PlayerOfMonthGraphicScreenState();
}

class _PlayerOfMonthGraphicScreenState
    extends State<PlayerOfMonthGraphicScreen> {
  final GlobalKey _boundaryKey = GlobalKey();
  _Fmt _fmt = _Fmt.post;
  bool _loading = true;
  bool _sharing = false;

  List<Sponsor> _sponsors = [];
  PlayerMonthStats _month = const PlayerMonthStats();
  PlayerStat? _fupa;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    final sponsors = await state.sponsors();
    final month = await state.playerMonthStats(
      widget.player.teamId,
      widget.yearMonth,
      widget.player.id,
    );
    final fupa = await state.playerSeasonStat(
      widget.player.teamId,
      widget.player.dedupKey,
    );
    if (!mounted) return;
    setState(() {
      _sponsors = sponsors;
      _month = month;
      _fupa = fupa;
      _loading = false;
    });
  }

  List<Sponsor> get _barSponsors =>
      _sponsors.where((s) => s.logo != null).toList();

  String get _monthLabel {
    final y = int.tryParse(widget.yearMonth.substring(0, 4)) ?? 2000;
    final m = int.tryParse(widget.yearMonth.substring(5, 7)) ?? 1;
    return DateFormat('MMMM yyyy', 'de_DE').format(DateTime(y, m));
  }

  Future<void> _share() async {
    if (_sharing) return;
    setState(() => _sharing = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final boundary =
          _boundaryKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) return;
      final image = await boundary.toImage(
        pixelRatio: _fmt.targetWidth / _fmt.logical.width,
      );
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return;
      final safeName = widget.player.fullName.replaceAll(' ', '-');
      final savedPath = await shareOrSaveImage(
        data.buffer.asUint8List(),
        'SpielerDesMonats_${safeName}_${widget.yearMonth}_${_fmt.fileSuffix}',
        text: 'Spieler des Monats $_monthLabel – ${widget.player.fullName}',
      );
      if (savedPath != null && mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: Text('Als Bild gespeichert und geöffnet:\n$savedPath'),
            duration: const Duration(seconds: 6),
          ),
        );
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Teilen fehlgeschlagen: $e')),
      );
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final size = _fmt.logical;
    final graphic = _fmt == _Fmt.urkunde
        ? _UrkundeGraphic(
            player: widget.player,
            teamName: widget.teamName,
            teamLogo: widget.teamLogo,
            monthLabel: _monthLabel,
            avg: widget.avg,
            ratedCount: widget.ratedCount,
            month: _month,
            fupa: _fupa,
            barSponsors: _barSponsors,
          )
        : _SocialGraphic(
            player: widget.player,
            teamName: widget.teamName,
            teamLogo: widget.teamLogo,
            monthLabel: _monthLabel,
            avg: widget.avg,
            ratedCount: widget.ratedCount,
            month: _month,
            fupa: _fupa,
            barSponsors: _barSponsors,
            compact: _fmt == _Fmt.post,
          );
    return Scaffold(
      appBar: AppBar(title: const Text('Spieler des Monats – teilen')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: SegmentedButton<_Fmt>(
              segments: [
                for (final f in _Fmt.values)
                  ButtonSegment(value: f, label: Text(f.label)),
              ],
              selected: {_fmt},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() => _fmt = s.first),
            ),
          ),
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: FittedBox(
                  fit: BoxFit.contain,
                  child: RepaintBoundary(
                    key: _boundaryKey,
                    child: SizedBox(
                      width: size.width,
                      height: size.height,
                      child: graphic,
                    ),
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _sharing ? null : _share,
                  icon: _sharing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.ios_share),
                  label: Text(
                    _fmt == _Fmt.urkunde ? 'Urkunde teilen/drucken' : 'Teilen',
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Rundes Spielerfoto in fester Größe mit Goldring; Rückfall auf Initialen.
class _PhotoRing extends StatelessWidget {
  const _PhotoRing({required this.player, required this.diameter});

  final Player player;
  final double diameter;

  @override
  Widget build(BuildContext context) {
    final bytes = TeamLogo.decode(player.photoPath);
    final fallback = player.lastName.isNotEmpty
        ? player.lastName[0].toUpperCase()
        : '?';
    return Container(
      width: diameter,
      height: diameter,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: _greenDark,
        border: Border.all(color: _gold, width: 4),
        image: bytes != null
            ? DecorationImage(image: MemoryImage(bytes), fit: BoxFit.cover)
            : null,
      ),
      alignment: Alignment.center,
      child: bytes == null
          ? Text(
              fallback,
              style: TextStyle(
                color: Colors.white,
                fontSize: diameter * 0.4,
                fontWeight: FontWeight.w800,
              ),
            )
          : null,
    );
  }
}

Widget _logoChip(Uint8List bytes, {required double height}) => Container(
  height: height,
  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
  decoration: BoxDecoration(
    color: Colors.white,
    borderRadius: BorderRadius.circular(5),
  ),
  child: Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true),
);

/// Kompakte Statistik-Kachel „Zahl + Label".
class _StatTile extends StatelessWidget {
  const _StatTile({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.w900,
            height: 1.0,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label.toUpperCase(),
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.75),
            fontSize: 9,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
          ),
        ),
      ],
    );
  }
}

/// Moderne Social-Grafik (Instagram). [compact] = Post 1:1, sonst Story 9:16.
class _SocialGraphic extends StatelessWidget {
  const _SocialGraphic({
    required this.player,
    required this.teamName,
    required this.teamLogo,
    required this.monthLabel,
    required this.avg,
    required this.ratedCount,
    required this.month,
    required this.fupa,
    required this.barSponsors,
    required this.compact,
  });

  final Player player;
  final String teamName;
  final String? teamLogo;
  final String monthLabel;
  final double? avg;
  final int ratedCount;
  final PlayerMonthStats month;
  final PlayerStat? fupa;
  final List<Sponsor> barSponsors;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final pad = compact ? 18.0 : 22.0;
    final photo = compact ? 120.0 : 168.0;
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_green, _greenDark],
        ),
      ),
      child: Padding(
        padding: EdgeInsets.all(pad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(),
            SizedBox(height: compact ? 8 : 14),
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: SizedBox(
                  width: 320,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _PhotoRing(player: player, diameter: photo),
                      const SizedBox(height: 12),
                      Text(
                        player.fullName.toUpperCase(),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 26,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.5,
                          height: 1.05,
                        ),
                      ),
                      if ((player.position ?? '').isNotEmpty ||
                          player.number != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          [
                            if (player.number != null) '#${player.number}',
                            if ((player.position ?? '').isNotEmpty)
                              player.position!,
                          ].join('  ·  ').toUpperCase(),
                          style: TextStyle(
                            color: _gold,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1,
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      if (avg != null) _noteBadge(),
                      const SizedBox(height: 14),
                      _statRow(),
                    ],
                  ),
                ),
              ),
            ),
            if (barSponsors.isNotEmpty) ...[
              SizedBox(height: compact ? 8 : 12),
              _sponsorBar(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _header() {
    return Column(
      children: [
        Row(
          children: [
            if (teamLogo != null) ...[
              TeamLogo(logoPath: teamLogo, size: compact ? 30 : 38),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Text(
                teamName.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.9),
                  fontSize: compact ? 12 : 14,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            const Text('🏆', style: TextStyle(fontSize: 22)),
          ],
        ),
        const SizedBox(height: 8),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            children: [
              Text(
                'SPIELER DES MONATS',
                style: TextStyle(
                  color: _gold,
                  fontSize: compact ? 22 : 26,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.5,
                  height: 1.0,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                monthLabel.toUpperCase(),
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.85),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _noteBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: _gold,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star_rounded, color: _greenDark, size: 20),
          const SizedBox(width: 6),
          Text(
            'Ø ${avg!.toStringAsFixed(1)}',
            style: const TextStyle(
              color: _greenDark,
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '($ratedCount Bew.)',
            style: TextStyle(
              color: _greenDark.withValues(alpha: 0.8),
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _statRow() {
    final tiles = <Widget>[];
    void add(String v, String l) => tiles.add(_StatTile(value: v, label: l));
    // Monat (live getrackt) – nur wenn vorhanden.
    if (month.hasAny) {
      add('${month.goals}', 'Tore');
      add('${month.assists}', 'Vorlagen');
      if (month.redTotal > 0) add('${month.redTotal}', 'Rot');
      if (month.yellow > 0) add('${month.yellow}', 'Gelb');
    }
    // FuPa-Saison als Ergänzung.
    final f = fupa;
    if (f != null) {
      add('${f.matches}', 'Spiele S.');
      add('${f.goals}', 'Tore S.');
    }
    if (tiles.isEmpty) return const SizedBox.shrink();
    return Column(
      children: [
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 22,
          runSpacing: 10,
          children: tiles,
        ),
        if (month.hasAny || fupa != null) ...[
          const SizedBox(height: 6),
          Text(
            month.hasAny ? 'Monat · S. = Saison (FuPa)' : 'Saison (FuPa)',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 9,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ],
    );
  }

  Widget _sponsorBar() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final s in barSponsors)
            if (TeamLogo.decode(s.logo) != null)
              _logoChip(TeamLogo.decode(s.logo)!, height: compact ? 24 : 30),
        ],
      ),
    );
  }
}

/// Klassische DIN-A4-Urkunde (Hochformat) zum Drucken.
class _UrkundeGraphic extends StatelessWidget {
  const _UrkundeGraphic({
    required this.player,
    required this.teamName,
    required this.teamLogo,
    required this.monthLabel,
    required this.avg,
    required this.ratedCount,
    required this.month,
    required this.fupa,
    required this.barSponsors,
  });

  final Player player;
  final String teamName;
  final String? teamLogo;
  final String monthLabel;
  final double? avg;
  final int ratedCount;
  final PlayerMonthStats month;
  final PlayerStat? fupa;
  final List<Sponsor> barSponsors;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _paper,
      padding: const EdgeInsets.all(14),
      child: Container(
        decoration: BoxDecoration(border: Border.all(color: _gold, width: 3)),
        child: Container(
          margin: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            border: Border.all(color: _gold.withValues(alpha: 0.5), width: 1),
          ),
          padding: const EdgeInsets.fromLTRB(26, 22, 26, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Kopf: Logo + Verein.
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (teamLogo != null) ...[
                    TeamLogo(logoPath: teamLogo, size: 40),
                    const SizedBox(width: 10),
                  ],
                  Flexible(
                    child: Text(
                      teamName.toUpperCase(),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: _ink,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              const Text(
                '🏆',
                style: TextStyle(fontSize: 34),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              Text(
                'URKUNDE',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _gold,
                  fontSize: 40,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 6,
                  height: 1.0,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Spieler des Monats',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _ink,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                monthLabel,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _ink.withValues(alpha: 0.7),
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 18),
              Center(child: _PhotoRing(player: player, diameter: 108)),
              const SizedBox(height: 12),
              Text(
                player.fullName,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: _ink,
                  fontSize: 30,
                  fontWeight: FontWeight.w900,
                  height: 1.05,
                ),
              ),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  'wird für herausragende Leistungen im Monat $monthLabel '
                  'zum Spieler des Monats ernannt.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _ink.withValues(alpha: 0.85),
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _statsBlock(),
              const Spacer(),
              _signatureRow(),
              if (barSponsors.isNotEmpty) ...[
                const SizedBox(height: 14),
                _sponsorBar(),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _statsBlock() {
    final f = fupa;
    Widget col(String title, List<(String, String)> rows) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: TextStyle(
              color: _gold,
              fontSize: 11,
              fontWeight: FontWeight.w900,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 6),
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    r.$1,
                    style: TextStyle(
                      color: _ink.withValues(alpha: 0.8),
                      fontSize: 12,
                    ),
                  ),
                  Text(
                    r.$2,
                    style: const TextStyle(
                      color: _ink,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );

    final monthRows = <(String, String)>[
      if (avg != null) ('Ø-Note', '${avg!.toStringAsFixed(1)} ($ratedCount)'),
      ('Spiele', '${month.games}'),
      ('Tore', '${month.goals}'),
      ('Vorlagen', '${month.assists}'),
      if (month.yellow > 0) ('Gelbe Karten', '${month.yellow}'),
      if (month.redTotal > 0) ('Rote Karten', '${month.redTotal}'),
    ];
    final seasonRows = <(String, String)>[
      ('Spiele', '${f?.matches ?? 0}'),
      ('Tore', '${f?.goals ?? 0}'),
      ('Vorlagen', '${f?.assists ?? 0}'),
      ('Minuten', '${f?.minutes ?? 0}'),
      if ((f?.topEleven ?? 0) > 0) ('⭐ Top11', '${f!.topEleven}'),
    ];

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _green.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _gold.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          col('Dieser Monat', monthRows),
          Container(
            width: 1,
            height: 96,
            margin: const EdgeInsets.symmetric(horizontal: 14),
            color: _gold.withValues(alpha: 0.4),
          ),
          col('Saison (FuPa)', seasonRows),
        ],
      ),
    );
  }

  Widget _signatureRow() {
    final today = DateFormat('dd.MM.yyyy', 'de_DE').format(DateTime.now());
    Widget sig(String label, String value) => Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(width: 130, height: 1, color: _ink.withValues(alpha: 0.5)),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            color: _ink.withValues(alpha: 0.7),
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (value.isNotEmpty)
          Text(
            value,
            style: TextStyle(color: _ink.withValues(alpha: 0.6), fontSize: 10),
          ),
      ],
    );
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [sig('Trainerteam', ''), sig('Datum', today)],
    );
  }

  Widget _sponsorBar() {
    return Column(
      children: [
        Text(
          'MIT FREUNDLICHER UNTERSTÜTZUNG',
          style: TextStyle(
            color: _ink.withValues(alpha: 0.6),
            fontSize: 8,
            fontWeight: FontWeight.w700,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final s in barSponsors)
              if (TeamLogo.decode(s.logo) != null)
                Container(
                  height: 28,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(color: _ink.withValues(alpha: 0.15)),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Image.memory(
                    TeamLogo.decode(s.logo)!,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                  ),
                ),
          ],
        ),
      ],
    );
  }
}
