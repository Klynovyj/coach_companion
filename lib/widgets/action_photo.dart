import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../models/player.dart';
import '../services/player_photos.dart';
import '../state/app_state.dart';

/// Actionfoto eines Spielers für Grafiken (Tor, Spieler des Spiels, Anlass,
/// Spielankündigung). Gibt es noch keins, wird direkt nachgefragt: Galerie
/// oder Kamera (Foto landet gleich im Profil-Fach „Action“ und wird künftig
/// automatisch genommen) bzw. ersatzweise das Profilfoto.
///
/// Liefert eine Data-URL oder null (abgebrochen / kein Foto).
Future<String?> resolveActionPhoto(BuildContext context, Player p) async {
  final state = context.read<AppState>();
  final messenger = ScaffoldMessenger.of(context);
  // Neuesten Stand aus der Cloud (z. B. auf dem anderen Gerät hinterlegt).
  try {
    await state.refreshPlayerPhotos(p.id).timeout(const Duration(seconds: 6));
  } catch (_) {}
  final stored = await state.playerPhoto(p.id, PlayerPhotoSlot.action);
  if (stored != null) return stored;
  if (!context.mounted) return null;

  final canCamera = Platform.isAndroid || Platform.isIOS;
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
            child: Text(
              'Noch kein Actionfoto von ${p.displayName}',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              'Das gewählte Foto wird im Profil als Actionfoto gespeichert '
              'und künftig automatisch verwendet.',
              style: TextStyle(fontSize: 12),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Aus Galerie'),
            onTap: () => Navigator.pop(ctx, 'gallery'),
          ),
          if (canCamera)
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Kamera'),
              onTap: () => Navigator.pop(ctx, 'camera'),
            ),
          if (p.photoPath != null)
            ListTile(
              leading: const Icon(Icons.account_circle_outlined),
              title: const Text('Profilfoto nehmen'),
              subtitle: const Text('Kein Actionfoto speichern'),
              onTap: () => Navigator.pop(ctx, 'profile'),
            ),
          ListTile(
            leading: const Icon(Icons.close),
            title: const Text('Ohne Foto weiter'),
            onTap: () => Navigator.pop(ctx, 'none'),
          ),
        ],
      ),
    ),
  );
  if (choice == null || choice == 'none') return null;
  if (choice == 'profile') return p.photoPath;
  try {
    final file = await ImagePicker().pickImage(
      source: choice == 'camera' ? ImageSource.camera : ImageSource.gallery,
    );
    if (file == null) return null;
    final raw = await file.readAsBytes();
    final url = await compute(encodeOriginalPhoto, raw);
    await state.setPlayerPhoto(p, PlayerPhotoSlot.action, url);
    return url;
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('Foto konnte nicht geladen werden: $e')),
    );
    return null;
  }
}
