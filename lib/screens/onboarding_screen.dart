import 'package:flutter/material.dart';

import '../services/cloud_service.dart';
import 'cloud_screen.dart';

/// Erststart-Ablauf: erst anmelden/registrieren, dann ein Team wählen
/// (anlegen/beitreten/aktivieren). Erst mit angemeldetem Konto UND aktivem Team
/// schaltet das [RootGate] auf den HomeScreen um.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final signedIn = CloudService.signedIn;

    Widget body;
    if (!CloudService.ready) {
      body = const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Keine Verbindung zur Cloud.\n'
            'Für die erste Anmeldung ist Internet nötig. '
            'Prüfe die Verbindung und starte die App neu.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        ),
      );
    } else if (!signedIn) {
      body = AuthForm(onDone: () => setState(() {}));
    } else {
      body = TeamsView(onChanged: () => setState(() {}));
    }

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Willkommens-Kopf mit Schritt-Hinweis.
            Container(
              width: double.infinity,
              color: scheme.primary,
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Willkommen bei myCoach',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: scheme.onPrimary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    !signedIn
                        ? 'Schritt 1 von 2: Anmelden oder Konto erstellen'
                        : 'Schritt 2 von 2: Team wählen oder anlegen',
                    style: TextStyle(
                      color: scheme.onPrimary.withValues(alpha: 0.9),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(child: body),
            // Beim Team-Schritt: Konto wechseln (abmelden).
            if (signedIn && CloudService.ready)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: TextButton.icon(
                  onPressed: () async {
                    await CloudService.signOut();
                    if (mounted) setState(() {});
                  },
                  icon: const Icon(Icons.logout, size: 18),
                  label: const Text('Abmelden / Konto wechseln'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
