import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/cloud_service.dart';
import '../state/app_state.dart';
import 'home_screen.dart';
import 'onboarding_screen.dart';

/// Entscheidet beim Start, was angezeigt wird (Onboarding-Zwang):
/// - noch am Laden → Spinner,
/// - Cloud nicht bereit → Onboarding (Hinweis „keine Verbindung"),
/// - nicht angemeldet → Onboarding (Anmelden),
/// - angemeldet, aber kein aktives Team → Onboarding (Team wählen),
/// - sonst → HomeScreen.
class RootGate extends StatelessWidget {
  const RootGate({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (state.loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    // Ohne Cloud-Client gibt es keinen Auth-Stream – einmalig entscheiden.
    if (!CloudService.ready) return const OnboardingScreen();
    return StreamBuilder<AuthState>(
      stream: CloudService.authChanges,
      builder: (context, _) {
        if (!CloudService.signedIn) return const OnboardingScreen();
        if (state.activeCloudTeamId == null) return const OnboardingScreen();
        return const HomeScreen();
      },
    );
  }
}
