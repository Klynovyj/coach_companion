import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../models/player.dart';
import '../services/player_photos.dart';
import '../services/share_service.dart';
import '../state/app_state.dart';

/// Die vier Fotos eines Spielers: FuPa, eigenes FuPa-Foto, Verein, Action.
/// Jedes Foto in Originalformat ansehen, teilen, ersetzen oder als Profilbild
/// (rundes Bild in Kader, Listen und Grafiken) wählen.
class PlayerPhotosScreen extends StatefulWidget {
  const PlayerPhotosScreen({super.key, required this.player});

  final Player player;

  @override
  State<PlayerPhotosScreen> createState() => _PlayerPhotosScreenState();
}

class _PlayerPhotosScreenState extends State<PlayerPhotosScreen> {
  late Player _p = widget.player;
  late final AppState _app = context.read<AppState>();
  final Map<PlayerPhotoSlot, String?> _stored = {};
  PlayerPhotoSlot _profile = PlayerPhotoSlot.fupa;
  final Set<PlayerPhotoSlot> _busy = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _readLocal() async {
    final p = await _app.playerById(_p.id) ?? _p;
    final stored = <PlayerPhotoSlot, String?>{
      for (final s in PlayerPhotoSlot.values) s: await _app.playerPhoto(p.id, s),
    };
    final profile = await _app.profilePhotoSlot(p);
    if (!mounted) return;
    setState(() {
      _p = p;
      _stored
        ..clear()
        ..addAll(stored);
      _profile = profile;
      _loading = false;
    });
  }

  /// Lokal sofort zeigen, dann Cloud-Abgleich; fehlt das große FuPa-Foto,
  /// wird es von FuPa nachgeladen.
  Future<void> _load() async {
    await _readLocal();
    try {
      await _app.refreshPlayerPhotos(_p.id);
    } catch (_) {}
    await _readLocal();
    if (_stored[PlayerPhotoSlot.fupa] == null &&
        (_p.externalId ?? '').isNotEmpty) {
      await _loadFupa(silent: true);
    }
  }

  Future<void> _loadFupa({bool silent = false}) async {
    setState(() => _busy.add(PlayerPhotoSlot.fupa));
    final messenger = ScaffoldMessenger.of(context);
    final url = await _app.fetchFupaOriginalPhoto(_p);
    if (!mounted) return;
    setState(() => _busy.remove(PlayerPhotoSlot.fupa));
    if (url == null && !silent) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('FuPa-Foto konnte nicht geladen werden.'),
        ),
      );
    }
    await _readLocal();
  }

  /// Angezeigtes Bild eines Fachs: gespeichertes Original, sonst (ältere
  /// Daten) das kleine FuPa- bzw. eigene Foto des Spielers.
  String? _shown(PlayerPhotoSlot s) {
    final stored = _stored[s];
    if (stored != null) return stored;
    if (s == PlayerPhotoSlot.fupa) return _p.fupaPhoto;
    if (s == PlayerPhotoSlot.own && _profile == PlayerPhotoSlot.own) {
      return _p.customPhoto;
    }
    return null;
  }

  Future<void> _pick(PlayerPhotoSlot slot, ImageSource source) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final file = await ImagePicker().pickImage(source: source);
      if (file == null || !mounted) return;
      setState(() => _busy.add(slot));
      final raw = await file.readAsBytes();
      final url = await compute(encodeOriginalPhoto, raw);
      final p = await _app.setPlayerPhoto(
        _p,
        slot,
        url,
        // Erstes eigenes Foto wird automatisch Profilbild (wie bisher).
        asProfile: slot == PlayerPhotoSlot.own && _stored[slot] == null,
      );
      _p = p;
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Foto konnte nicht geladen werden: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy.remove(slot));
    }
    await _readLocal();
  }

  Future<void> _share(PlayerPhotoSlot slot) async {
    final bytes = dataUrlBytes(_shown(slot));
    if (bytes == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final name = '${_p.fullName}_${slot.label}';
    final path = await shareOrSaveImage(
      bytes,
      name,
      ext: imageExtension(bytes),
    );
    if (path != null) {
      messenger.showSnackBar(SnackBar(content: Text('Gespeichert: $path')));
    }
  }

  Future<void> _setProfile(PlayerPhotoSlot slot) async {
    setState(() => _busy.add(slot));
    final p = await _app.setProfilePhoto(_p, slot);
    if (!mounted) return;
    setState(() {
      _p = p;
      _profile = slot;
      _busy.remove(slot);
    });
  }

  Future<void> _remove(PlayerPhotoSlot slot) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${slot.description} entfernen?'),
        content: const Text('Das Foto wird auf allen Geräten entfernt.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Entfernen'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    _p = await _app.setPlayerPhoto(_p, slot, null);
    await _readLocal();
  }

  void _view(PlayerPhotoSlot slot) {
    final bytes = dataUrlBytes(_shown(slot));
    if (bytes == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (ctx) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            title: Text(slot.description),
            actions: [
              IconButton(
                tooltip: 'Teilen',
                icon: const Icon(Icons.share),
                onPressed: () => _share(slot),
              ),
            ],
          ),
          body: InteractiveViewer(
            maxScale: 6,
            child: Center(child: Image.memory(bytes, fit: BoxFit.contain)),
          ),
        ),
      ),
    );
  }

  Future<void> _actions(PlayerPhotoSlot slot) async {
    final has = _shown(slot) != null;
    final isMobile = Platform.isAndroid || Platform.isIOS;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                slot.description,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
            if (has) ...[
              ListTile(
                leading: const Icon(Icons.fullscreen),
                title: const Text('Ansehen'),
                onTap: () => Navigator.pop(ctx, 'view'),
              ),
              ListTile(
                leading: const Icon(Icons.share),
                title: const Text('Teilen (Originalformat)'),
                onTap: () => Navigator.pop(ctx, 'share'),
              ),
              if (_profile != slot)
                ListTile(
                  leading: const Icon(Icons.account_circle_outlined),
                  title: const Text('Als Profilbild verwenden'),
                  onTap: () => Navigator.pop(ctx, 'profile'),
                ),
            ],
            if (slot == PlayerPhotoSlot.fupa)
              ListTile(
                leading: const Icon(Icons.cloud_download_outlined),
                title: const Text('Von FuPa laden (960×1200)'),
                onTap: () => Navigator.pop(ctx, 'fupa'),
              ),
            if (isMobile)
              ListTile(
                leading: const Icon(Icons.photo_camera),
                title: const Text('Kamera'),
                onTap: () => Navigator.pop(ctx, 'camera'),
              ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: Text(isMobile ? 'Aus Galerie wählen' : 'Bild auswählen'),
              onTap: () => Navigator.pop(ctx, 'gallery'),
            ),
            if (_stored[slot] != null)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title: const Text('Entfernen'),
                onTap: () => Navigator.pop(ctx, 'remove'),
              ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    switch (choice) {
      case 'view':
        _view(slot);
      case 'share':
        await _share(slot);
      case 'profile':
        await _setProfile(slot);
      case 'fupa':
        await _loadFupa();
      case 'camera':
        await _pick(slot, ImageSource.camera);
      case 'gallery':
        await _pick(slot, ImageSource.gallery);
      case 'remove':
        await _remove(slot);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text('Fotos · ${_p.fullName}')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(
              builder: (ctx, c) {
                final cols = c.maxWidth > 700 ? 4 : 2;
                return GridView.count(
                  padding: const EdgeInsets.all(12),
                  crossAxisCount: cols,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 0.66,
                  children: [
                    for (final s in PlayerPhotoSlot.values) _card(s, scheme),
                  ],
                );
              },
            ),
    );
  }

  Widget _card(PlayerPhotoSlot slot, ColorScheme scheme) {
    final bytes = dataUrlBytes(_shown(slot));
    final isProfile = _profile == slot && bytes != null;
    final small = _stored[slot] == null && bytes != null;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => bytes != null ? _view(slot) : _actions(slot),
        onLongPress: () => _actions(slot),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(
                    color: scheme.surfaceContainerHighest,
                    child: bytes != null
                        ? Image.memory(
                            bytes,
                            fit: BoxFit.contain,
                            gaplessPlayback: true,
                          )
                        : Icon(
                            Icons.add_a_photo_outlined,
                            size: 36,
                            color: scheme.onSurfaceVariant,
                          ),
                  ),
                  if (_busy.contains(slot))
                    const ColoredBox(
                      color: Colors.black38,
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  if (isProfile)
                    Positioned(
                      left: 6,
                      top: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.primary,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          'Profilbild',
                          style: TextStyle(
                            color: scheme.onPrimary,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 0, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          slot.label,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          bytes == null
                              ? 'Noch kein Foto'
                              : (small ? 'Nur kleine Version' : 'Original'),
                          style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(context).hintColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (bytes != null)
                    IconButton(
                      tooltip: 'Teilen',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.share, size: 20),
                      onPressed: () => _share(slot),
                    ),
                  IconButton(
                    tooltip: 'Mehr',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.more_vert, size: 20),
                    onPressed: () => _actions(slot),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
