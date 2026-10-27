import 'package:flutter/material.dart';

import '../models/enums.dart';
import '../models/player.dart';
import 'availability_controls.dart';
import 'team_logo.dart';

/// Quadratisches, abgerundetes Spielerfoto mit optionaler FuPa-artiger
/// Status-Ecke oben links (nur wenn nicht „Fit"). Fehlt das Foto, wird die
/// Rückennummer bzw. der Anfangsbuchstabe angezeigt.
class PlayerPhoto extends StatelessWidget {
  const PlayerPhoto({
    super.key,
    required this.player,
    this.size = 44,
    this.radius = 10,
    this.showStatus = true,
    this.cornerFraction = 0.5,
  });

  final Player player;
  final double size;
  final double radius;
  final bool showStatus;

  /// Kantenlänge der Status-Ecke als Anteil der Fotogröße (0.5 = halbe Seite).
  final double cornerFraction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bytes = TeamLogo.decode(player.photoPath);
    final fallback =
        player.number?.toString() ??
        (player.lastName.isNotEmpty ? player.lastName[0] : '?');
    final status = player.status;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          children: [
            Positioned.fill(
              child: bytes != null
                  ? Image.memory(
                      bytes,
                      // Stabiler Key je Spieler: verhindert, dass beim
                      // Neuaufbau der Liste (gaplessPlayback) das alte Bild
                      // einer anderen Zeile stehen bleibt (falsches Foto).
                      key: ValueKey('photo_${player.id}'),
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                    )
                  : Container(
                      color: scheme.surfaceContainerHighest,
                      alignment: Alignment.center,
                      child: Text(
                        fallback,
                        style: TextStyle(
                          fontSize: size * 0.34,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
            ),
            if (showStatus && status != PlayerStatus.fit)
              Positioned(
                left: 0,
                top: 0,
                child: StatusCorner(
                  status: status,
                  size: size * cornerFraction,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Weißes Symbol je Verfügbarkeitsstatus (wird auf farbigem Grund genutzt:
/// Status-Ecke, Status-Plakette). Verletzt = medizinisches Pluskreuz.
IconData playerStatusIcon(PlayerStatus s) => switch (s) {
  PlayerStatus.verletzt => Icons.add,
  PlayerStatus.krank => Icons.sick,
  PlayerStatus.gesperrt => Icons.block,
  PlayerStatus.urlaub => Icons.beach_access,
  PlayerStatus.abwesend => Icons.business_center,
  PlayerStatus.inaktiv => Icons.pause,
  PlayerStatus.fit => Icons.check,
};

/// FuPa-artige farbige Ecke oben links für den Verfügbarkeitsstatus. Farbe =
/// [playerStatusColor], dazu ein weißes Symbol je Status. Wird auf der
/// Spielerkarte und über den Kader-Fotos genutzt.
class StatusCorner extends StatelessWidget {
  const StatusCorner({super.key, required this.status, this.size = 60});

  final PlayerStatus status;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = playerStatusColor(status);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(painter: _CornerTrianglePainter(color)),
          ),
          Positioned(
            left: size * 0.09,
            top: size * 0.09,
            child: Icon(
              playerStatusIcon(status),
              size: size * 0.34,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

/// Runde farbige Status-Plakette mit weißem Symbol (für Listen/Chips). Farbe =
/// [playerStatusColor], Symbol = [playerStatusIcon] – einheitlich mit der
/// Status-Ecke auf den Fotos.
class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.status, this.size = 20});

  final PlayerStatus status;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: playerStatusColor(status),
        shape: BoxShape.circle,
      ),
      child: Icon(
        playerStatusIcon(status),
        size: size * 0.66,
        color: Colors.white,
      ),
    );
  }
}

/// Zeichnet das farbige Dreieck in der oberen linken Ecke.
class _CornerTrianglePainter extends CustomPainter {
  _CornerTrianglePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _CornerTrianglePainter old) =>
      old.color != color;
}
