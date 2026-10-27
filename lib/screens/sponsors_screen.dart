import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../models/sponsor.dart';
import '../state/app_state.dart';
import '../widgets/team_logo.dart';

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
                      Container(
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
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.upload, size: 18),
                          label: Text(
                            logo == null ? 'Logo wählen' : 'Logo ändern',
                          ),
                          onPressed: () async {
                            final picked = await _pickLogo();
                            if (picked != null) setSheet(() => logo = picked);
                          },
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
      await state.addSponsor(name, logo: logo, isMain: isMain);
    } else {
      await state.saveSponsor(
        existing.copyWith(name: name, logo: logo, isMain: isMain),
      );
    }
    await _load();
  }

  /// Wählt ein Logo aus der Galerie/Datei und kodiert es als Base64-Data-URL
  /// (wie die Vereinslogos).
  Future<String?> _pickLogo() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final file = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 600,
        maxHeight: 600,
        imageQuality: 90,
      );
      if (file == null) return null;
      final bytes = await file.readAsBytes();
      return 'data:image/png;base64,${base64Encode(bytes)}';
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
                    'Ziehen zum Sortieren – Haupt-Sponsor bleibt oben.',
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

  Widget _row(Sponsor s, int index) {
    final handle = s.isMain
        ? Icon(Icons.push_pin, size: 18, color: Theme.of(context).hintColor)
        : ReorderableDragStartListener(
            index: index,
            child: Icon(Icons.drag_handle, color: Theme.of(context).hintColor),
          );
    return ListTile(
      key: ValueKey(s.id),
      leading: SizedBox(
        width: 44,
        height: 44,
        child: s.logo != null
            ? TeamLogo(logoPath: s.logo, size: 44)
            : Icon(Icons.business, color: Theme.of(context).hintColor),
      ),
      title: Text(s.name),
      subtitle: s.isMain ? const Text('Haupt-Sponsor · Präsentiert von') : null,
      onTap: () => _editSponsor(existing: s),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          handle,
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'edit') _editSponsor(existing: s);
              if (v == 'delete') _delete(s);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'edit', child: Text('Bearbeiten')),
              PopupMenuItem(value: 'delete', child: Text('Löschen')),
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
