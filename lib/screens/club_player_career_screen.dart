import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/player.dart';
import '../services/fupa/fupa_dtos.dart';
import '../state/app_state.dart';
import '../widgets/player_avatar.dart';

enum _CFilter { all, goals, assists, cards }

/// Spieler-Detail aus der Vereins-Bilanz: die FuPa-Laufbahn Saison für Saison
/// (Verein/Wettbewerb → Spiele/Tore/Vorlagen) plus die Karriere-Gesamtbilanz.
/// Filter Alle/Tore/Vorlagen/Karten. FuPa liefert Karten nur als Gesamt (nicht
/// pro Saison) und keine Einzelspiele.
class ClubPlayerCareerScreen extends StatefulWidget {
  const ClubPlayerCareerScreen({super.key, required this.player});

  final Player player;

  @override
  State<ClubPlayerCareerScreen> createState() => _ClubPlayerCareerScreenState();
}

class _ClubPlayerCareerScreenState extends State<ClubPlayerCareerScreen> {
  static const _gold = Color(0xFFC9A24B);
  FupaCareer? _career;
  bool _loading = true;
  _CFilter _filter = _CFilter.all;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    final c = await state.playerFupaCareer(widget.player.teamId, widget.player);
    if (!mounted) return;
    setState(() {
      _career = c;
      _loading = false;
    });
  }

  List<FupaCareerStation> _stations() {
    final list = [...?_career?.stations];
    switch (_filter) {
      case _CFilter.goals:
        list.sort((a, b) => b.goals.compareTo(a.goals));
      case _CFilter.assists:
        list.sort((a, b) => b.assists.compareTo(a.assists));
      case _CFilter.all:
      case _CFilter.cards:
        break; // Reihenfolge von FuPa (neueste zuerst)
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.player.fullName)),
      body: _loading
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 12),
                  Text('FuPa-Laufbahn wird geladen …'),
                ],
              ),
            )
          : _career == null || _career!.stations.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Keine FuPa-Laufbahn gefunden.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                _bilanzCard(),
                _filterChips(),
                if (_filter == _CFilter.cards)
                  _cardsInfo()
                else ...[
                  for (final s in _stations()) _stationRow(s),
                ],
              ],
            ),
    );
  }

  Widget _bilanzCard() {
    final c = _career!;
    final scheme = Theme.of(context).colorScheme;
    final spell = c.currentClubSpell();
    final clubName =
        spell?.clubName ??
        (c.stations.isNotEmpty ? c.stations.first.clubName : 'Verein');
    final ct = c.clubTotal(clubName: clubName);
    Widget stat(String v, String l) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          v,
          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18),
        ),
        Text(l, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
    final cards = <String>[
      if (c.totalYellow > 0) '🟨 ${c.totalYellow}',
      if (c.totalYellowRed > 0) '🟨🟥 ${c.totalYellowRed}',
      if (c.totalRed > 0) '🟥 ${c.totalRed}',
    ].join('   ');
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            Row(
              children: [
                PlayerAvatar(player: widget.player, radius: 24),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.player.fullName,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                        ),
                      ),
                      Text(
                        '$clubName · Pflichtspiele',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.grey,
                        ),
                      ),
                      if (spell?.sinceYear != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            '${spell!.clubName} seit ${spell.sinceYear} · '
                            '${spell.yearsUntil(DateTime.now().year)} Jahre '
                            '(ohne Unterbrechung)',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: _gold,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                stat('${ct.matches}', 'Spiele'),
                stat('${ct.goals}', 'Tore'),
                stat('${ct.assists}', 'Vorlagen'),
                stat('${ct.scorerPoints}', 'Scorer'),
                if (c.totalTopEleven > 0)
                  stat('${c.totalTopEleven}', 'Elf d.W.'),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'Karriere gesamt (alle Vereine): ${c.totalMatches} Spiele · '
                '${c.totalGoals} Tore · ${c.totalAssists} Vorlagen'
                '${cards.isEmpty ? '' : '   $cards'}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _filterChips() {
    Widget chip(String label, _CFilter f) => Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: _filter == f,
        onSelected: (_) => setState(() => _filter = f),
      ),
    );
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        children: [
          chip('Alle', _CFilter.all),
          chip('Tore', _CFilter.goals),
          chip('Vorlagen', _CFilter.assists),
          chip('Karten', _CFilter.cards),
        ],
      ),
    );
  }

  Widget _cardsInfo() {
    final c = _career!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Karten gesamt (Karriere): '
            '🟨 ${c.totalYellow}   🟨🟥 ${c.totalYellowRed}   🟥 ${c.totalRed}',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            'FuPa führt Karten nur als Karriere-Gesamt – eine Aufschlüsselung '
            'pro Saison oder pro Spiel ist bei FuPa nicht hinterlegt.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _stationRow(FupaCareerStation s) {
    final highlightGoals = _filter == _CFilter.goals;
    final highlightAssists = _filter == _CFilter.assists;
    Widget num(String v, String l, {bool strong = false}) => SizedBox(
      width: 56,
      child: Column(
        children: [
          Text(
            v,
            style: TextStyle(
              fontWeight: strong ? FontWeight.w900 : FontWeight.w600,
              color: strong ? _gold : null,
              fontSize: strong ? 16 : 14,
            ),
          ),
          Text(l, style: const TextStyle(fontSize: 9, color: Colors.grey)),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s.clubName,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                  s.competition,
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),
          ),
          num('${s.matches}', 'Sp'),
          num('${s.goals}', 'Tore', strong: highlightGoals),
          num('${s.assists}', 'Vorl.', strong: highlightAssists),
        ],
      ),
    );
  }
}
