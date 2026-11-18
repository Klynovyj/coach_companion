import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/enums.dart';
import '../models/match.dart';
import '../services/fupa/fupa_redux_importer.dart';
import '../state/app_state.dart';
import 'team_logo.dart';

/// Ergebnis des Spiel-Dialogs (neu anlegen oder bearbeiten).
class MatchEditData {
  final String opponent;
  final DateTime? kickoff;
  final Venue venue;
  final String? competition;
  final String? fupaUrl;
  final String? logo;
  MatchEditData(
    this.opponent,
    this.kickoff,
    this.venue,
    this.competition, {
    this.fupaUrl,
    this.logo,
  });
}

/// Dialog „Neues Spiel" bzw. „Spiel bearbeiten" (mit [initial]). Optional mit
/// FuPa-Link des Gegners – dann werden Kader und Wappen geladen.
class MatchEditSheet extends StatefulWidget {
  const MatchEditSheet({super.key, this.initial});
  final GameMatch? initial;
  @override
  State<MatchEditSheet> createState() => _MatchEditSheetState();
}

class _MatchEditSheetState extends State<MatchEditSheet> {
  final _opp = TextEditingController();
  final _comp = TextEditingController();
  final _link = TextEditingController();
  DateTime? _kickoff;
  Venue _venue = Venue.home;

  /// Normalisierter FuPa-Teamlink (null = kein/ungültiger Link).
  String? _fupaUrl;
  String? _previewName;
  String? _previewLogo;
  bool _previewBusy = false;
  String? _previewError;
  String? _autoName; // zuletzt automatisch eingetragener Gegnername
  int _previewSeq = 0;

  bool get _editing => widget.initial != null;

  @override
  void initState() {
    super.initState();
    final m = widget.initial;
    if (m != null) {
      _opp.text = m.opponentName;
      _comp.text = m.competition ?? '';
      _link.text = m.opponentFupaUrl ?? '';
      _fupaUrl = m.opponentFupaUrl;
      _kickoff = m.kickoff;
      _venue = m.venue;
    }
  }

  @override
  void dispose() {
    _opp.dispose();
    _comp.dispose();
    _link.dispose();
    super.dispose();
  }

  Future<void> _pasteLink() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) return;
    _link.text = text;
    await _onLinkChanged(text);
  }

  Future<void> _onLinkChanged(String text) async {
    final url = FupaReduxImporter.extractTeamUrl(text);
    final seq = ++_previewSeq;
    setState(() {
      _fupaUrl = url;
      _previewName = null;
      _previewLogo = null;
      _previewError = text.trim().isNotEmpty && url == null
          ? 'Bitte einen FuPa-Mannschaftslink einfügen (fupa.net/team/…).'
          : null;
      _previewBusy = url != null;
    });
    if (url == null) return;
    try {
      final p = await context.read<AppState>().fupaTeamPreview(url);
      if (!mounted || seq != _previewSeq) return;
      setState(() {
        _previewBusy = false;
        _previewName = p.name;
        _previewLogo = p.logo;
        final name = p.name?.trim() ?? '';
        final cur = _opp.text.trim();
        if (name.isNotEmpty && (cur.isEmpty || cur == _autoName)) {
          _opp.text = name;
          _autoName = name;
        }
      });
    } catch (_) {
      if (!mounted || seq != _previewSeq) return;
      setState(() {
        _previewBusy = false;
        _previewError =
            'Mannschaft konnte gerade nicht geladen werden – der Kader wird '
            'beim Öffnen des Spiels erneut versucht.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final df = DateFormat('dd.MM.yyyy HH:mm', 'de_DE');
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _editing ? 'Spiel bearbeiten' : 'Neues Spiel',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _link,
              keyboardType: TextInputType.url,
              onChanged: _onLinkChanged,
              decoration: InputDecoration(
                labelText: 'FuPa-Link des Gegners (optional)',
                hintText: 'fupa.net/team/…',
                helperText: _previewError == null
                    ? 'Damit werden Kader und Wappen des Gegners geladen.'
                    : null,
                errorText: _previewError,
                errorMaxLines: 3,
                prefixIcon: const Icon(Icons.link),
                suffixIcon: _link.text.isEmpty
                    ? IconButton(
                        tooltip: 'Link einfügen',
                        icon: const Icon(Icons.content_paste),
                        onPressed: _pasteLink,
                      )
                    : IconButton(
                        tooltip: 'Link entfernen',
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _link.clear();
                          _onLinkChanged('');
                        },
                      ),
              ),
            ),
            if (_previewBusy || _previewName != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    if (_previewBusy)
                      const SizedBox(
                        width: 32,
                        height: 32,
                        child: Padding(
                          padding: EdgeInsets.all(6),
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    else
                      TeamLogo(logoPath: _previewLogo, size: 32),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _previewBusy
                            ? 'Mannschaft wird geladen …'
                            : '${_previewName!} – Kader & Wappen werden '
                                  'übernommen',
                        style: TextStyle(color: scheme.onSecondaryContainer),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _opp,
              decoration: const InputDecoration(labelText: 'Gegner'),
            ),
            const SizedBox(height: 12),
            SegmentedButton<Venue>(
              segments: const [
                ButtonSegment(value: Venue.home, label: Text('Heim')),
                ButtonSegment(value: Venue.away, label: Text('Auswärts')),
              ],
              selected: {_venue},
              onSelectionChanged: (s) => setState(() => _venue = s.first),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _pickDate,
              icon: const Icon(Icons.schedule),
              label: Text(
                _kickoff == null ? 'Anstoßzeit wählen' : df.format(_kickoff!),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _comp,
              decoration: const InputDecoration(
                labelText: 'Wettbewerb (optional)',
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () {
                if (_opp.text.trim().isEmpty) return;
                Navigator.pop(
                  context,
                  MatchEditData(
                    _opp.text.trim(),
                    _kickoff,
                    _venue,
                    _comp.text.trim().isEmpty ? null : _comp.text.trim(),
                    fupaUrl: _fupaUrl,
                    logo: _previewLogo,
                  ),
                );
              },
              child: Text(_editing ? 'Speichern' : 'Spiel anlegen'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _kickoff ?? now,
      firstDate: DateTime(
        (_kickoff != null && _kickoff!.year < now.year - 1)
            ? _kickoff!.year
            : now.year - 1,
      ),
      lastDate: DateTime(now.year + 2),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: _kickoff == null
          ? const TimeOfDay(hour: 15, minute: 0)
          : TimeOfDay.fromDateTime(_kickoff!),
    );
    setState(() {
      _kickoff = DateTime(
        date.year,
        date.month,
        date.day,
        time?.hour ?? 15,
        time?.minute ?? 0,
      );
    });
  }
}
