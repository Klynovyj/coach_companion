import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../models/sponsor.dart';
import '../state/app_state.dart';
import '../widgets/team_logo.dart';
import 'logo_editor_screen.dart';

/// Verwaltung der Vereins-Sponsoren. Die hier eingetragenen Logos erscheinen
/// automatisch auf der Startelf-Grafik: der Haupt-Sponsor als „Präsentiert von
/// …", alle übrigen in der Logo-Leiste.
class SponsorsScreen extends StatefulWidget {
  const SponsorsScreen({super.key});

  @override
  State<SponsorsScreen> createState() => _SponsorsScreenState();
}

class _SponsorsScreenState extends State<SponsorsScreen> {
  late final AppState _app = context.read<AppState>();
  List<Sponsor> _sponsors = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    // Live aktualisieren, wenn per Realtime Sponsoren anderer Geräte ankommen.
    _app.addListener(_onChanged);
    _load();
    // Lokale Sponsoren (evtl. vor Existenz der Cloud-Tabelle angelegt) in die
    // Cloud nachschieben, damit sie auf anderen Geräten erscheinen.
    _app.pushSponsorsToCloud();
  }

  @override
  void dispose() {
    _app.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) _load();
  }

  Future<void> _load() async {
    final list = await _app.sponsors();
    if (!mounted) return;
    setState(() {
      _sponsors = list;
      _loading = false;
    });
  }

  Future<void> _editSponsor({Sponsor? existing}) async {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    String? logo = existing?.logo;
    bool isMain = existing?.isMain ?? false;
    String chip = existing?.chip ?? 'auto';

    // Logo im Editor bearbeiten (zuschneiden, Ränder/Weiß weg, Feld).
    Future<void> edit(StateSetter setSheet, Uint8List bytes) async {
      final r = await Navigator.of(context).push<LogoEditResult>(
        MaterialPageRoute(
          builder: (_) => LogoEditorScreen(
            imageBytes: bytes,
            chip: chip,
            name: nameCtrl.text,
          ),
        ),
      );
      if (r == null) return;
      setSheet(() {
        logo = 'data:image/png;base64,${base64Encode(r.bytes)}';
        chip = r.chip;
      });
    }

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: StatefulBuilder(
          builder: (ctx, setSheet) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    existing == null ? 'Sponsor anlegen' : 'Sponsor bearbeiten',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      GestureDetector(
                        onTap: () {
                          final b = TeamLogo.decode(logo);
                          if (b != null) edit(setSheet, b);
                        },
                        child: Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            color: Theme.of(
                              ctx,
                            ).colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          alignment: Alignment.center,
                          child: logo != null
                              ? TeamLogo(logoPath: logo, size: 48)
                              : Icon(
                                  Icons.image_outlined,
                                  color: Theme.of(ctx).hintColor,
                                ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            OutlinedButton.icon(
                              icon: const Icon(Icons.upload, size: 18),
                              label: Text(
                                logo == null ? 'Logo wählen' : 'Logo ändern',
                              ),
                              onPressed: () async {
                                final picked = await _pickLogo();
                                if (picked == null) return;
                                // Erst das Rohbild übernehmen, dann direkt
                                // den Editor öffnen (Abbrechen = so lassen).
                                setSheet(
                                  () => logo =
                                      'data:image/png;base64,'
                                      '${base64Encode(picked)}',
                                );
                                await edit(setSheet, picked);
                              },
                            ),
                            if (logo != null) ...[
                              const SizedBox(height: 6),
                              FilledButton.tonalIcon(
                                icon: const Icon(Icons.tune, size: 18),
                                label: const Text('Logo bearbeiten'),
                                onPressed: () {
                                  final b = TeamLogo.decode(logo);
                                  if (b != null) edit(setSheet, b);
                                },
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: nameCtrl,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'Name',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Haupt-Sponsor'),
                    subtitle: const Text('Erscheint als „Präsentiert von …"'),
                    value: isMain,
                    onChanged: (v) => setSheet(() => isMain = v),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Abbrechen'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('Speichern'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    if (saved != true || !mounted) return;
    final name = nameCtrl.text.trim();
    if (name.isEmpty) return;
    final state = context.read<AppState>();
    if (existing == null) {
      await state.addSponsor(name, logo: logo, isMain: isMain, chip: chip);
    } else {
      await state.saveSponsor(
        existing.copyWith(name: name, logo: logo, isMain: isMain, chip: chip),
      );
    }
    await _load();
  }

  /// Wählt ein Logo aus der Galerie/Datei und kodiert es als Base64-Data-URL
  /// (wie die Vereinslogos).
  Future<Uint8List?> _pickLogo() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final file = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1200,
        maxHeight: 1200,
      );
      if (file == null) return null;
      return await file.readAsBytes();
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Logo konnte nicht geladen werden: $e')),
      );
      return null;
    }
  }

  Future<void> _delete(Sponsor s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sponsor löschen?'),
        content: Text('„${s.name}" wird entfernt.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await context.read<AppState>().deleteSponsor(s.id);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sponsoring')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _editSponsor(),
        icon: const Icon(Icons.add),
        label: const Text('Sponsor'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _sponsors.isEmpty
          ? _empty(context)
          : Column(
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(
                    'Diese Logos erscheinen automatisch auf der Startelf-Grafik. '
                    'Ziehen zum Sortieren – Haupt-Sponsor bleibt oben. Mit dem '
                    'Schalter deaktivierte Sponsoren erscheinen auf keiner Grafik.',
                    style: TextStyle(fontSize: 12.5, color: Colors.grey),
                  ),
                ),
                Expanded(
                  child: ReorderableListView.builder(
                    padding: const EdgeInsets.only(bottom: 88),
                    buildDefaultDragHandles: false,
                    itemCount: _sponsors.length,
                    onReorder: _onReorder,
                    itemBuilder: (ctx, i) => _row(_sponsors[i], i),
                  ),
                ),
              ],
            ),
    );
  }

  /// Neue Reihenfolge übernehmen. Haupt-Sponsor bleibt immer oben (Index 0).
  Future<void> _onReorder(int oldIndex, int newIndex) async {
    if (newIndex > oldIndex) newIndex -= 1;
    final hasMain = _sponsors.isNotEmpty && _sponsors.first.isMain;
    final minIndex = hasMain ? 1 : 0;
    if (oldIndex < minIndex) return; // Haupt-Sponsor nicht verschieben
    if (newIndex < minIndex) newIndex = minIndex;
    final list = [..._sponsors];
    final moved = list.removeAt(oldIndex);
    list.insert(newIndex, moved);
    setState(() => _sponsors = list);
    await _app.reorderSponsors(list);
  }

  /// Schaltet einen Sponsor aktiv/inaktiv. Deaktivierte erscheinen auf keiner
  /// Grafik, bleiben aber in der Liste erhalten.
  Future<void> _toggleEnabled(Sponsor s, bool v) async {
    setState(() {
      final i = _sponsors.indexWhere((e) => e.id == s.id);
      if (i >= 0) _sponsors[i] = _sponsors[i].copyWith(enabled: v);
    });
    await _app.saveSponsor(s.copyWith(enabled: v));
  }

  Widget _row(Sponsor s, int index) {
    final handle = s.isMain
        ? Icon(Icons.push_pin, size: 18, color: Theme.of(context).hintColor)
        : ReorderableDragStartListener(
            index: index,
            child: Icon(Icons.drag_handle, color: Theme.of(context).hintColor),
          );
    final dim = s.enabled ? 1.0 : 0.4;
    final Widget? subtitle = !s.enabled
        ? Text(
            'Deaktiviert · erscheint auf keiner Grafik',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          )
        : (s.isMain ? const Text('Haupt-Sponsor · Präsentiert von') : null);
    return ListTile(
      key: ValueKey(s.id),
      leading: Opacity(
        opacity: dim,
        child: SizedBox(
          width: 44,
          height: 44,
          child: s.logo != null
              ? TeamLogo(logoPath: s.logo, size: 44)
              : Icon(Icons.business, color: Theme.of(context).hintColor),
        ),
      ),
      title: Opacity(opacity: dim, child: Text(s.name)),
      subtitle: subtitle,
      onTap: () => _editSponsor(existing: s),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch(
            value: s.enabled,
            onChanged: (v) => _toggleEnabled(s, v),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          handle,
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'edit') _editSponsor(existing: s);
              if (v == 'toggle') _toggleEnabled(s, !s.enabled);
              if (v == 'delete') _delete(s);
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'edit', child: Text('Bearbeiten')),
              PopupMenuItem(
                value: 'toggle',
                child: Text(s.enabled ? 'Deaktivieren' : 'Aktivieren'),
              ),
              const PopupMenuItem(value: 'delete', child: Text('Löschen')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _empty(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.handshake_outlined,
              size: 56,
              color: Theme.of(context).hintColor,
            ),
            const SizedBox(height: 12),
            const Text(
              'Noch keine Sponsoren',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 6),
            const Text(
              'Lege Sponsoren mit Logo an – sie erscheinen automatisch auf der '
              'Startelf-Grafik.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
