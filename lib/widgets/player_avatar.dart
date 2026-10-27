import 'package:flutter/material.dart';

import '../models/player.dart';
import 'team_logo.dart';

/// Rundes Spielerbild aus einer Data-URL; fehlt das Foto, wird die
/// Rückennummer bzw. der Anfangsbuchstabe angezeigt.
class PlayerAvatar extends StatelessWidget {
  const PlayerAvatar({super.key, required this.player, this.radius = 20});

  final Player player;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final bytes = TeamLogo.decode(player.photoPath);
    final fallback =
        player.number?.toString() ??
        (player.lastName.isNotEmpty ? player.lastName[0] : '?');
    return CircleAvatar(
      radius: radius,
      backgroundImage: bytes != null ? MemoryImage(bytes) : null,
      child: bytes == null ? Text(fallback) : null,
    );
  }
}
