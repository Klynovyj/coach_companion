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
    if (bytes == null) {
      return CircleAvatar(radius: radius, child: Text(fallback));
    }
    // Rund gefüllt; hochkante (eigene) Fotos wie bei FuPa von OBEN
    // ausschneiden (Kopf + Schultern) statt aus der Mitte.
    return ClipOval(
      child: Image.memory(
        bytes,
        width: radius * 2,
        height: radius * 2,
        fit: BoxFit.cover,
        alignment: Alignment.topCenter,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) =>
            CircleAvatar(radius: radius, child: Text(fallback)),
      ),
    );
  }
}
