import 'package:flutter/material.dart';

/// Verletzt-/Sanitäter-Icon: weißes Pluskreuz auf rotem Grund. Wird überall
/// statt des 🤕-Emojis für „Verletzt" genutzt (Kader, Status, Ticker).
class InjuryCross extends StatelessWidget {
  const InjuryCross({super.key, this.size = 16});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.error,
        shape: BoxShape.circle,
      ),
      child: Icon(Icons.add, size: size * 0.78, color: Colors.white),
    );
  }
}
