import 'fupa_dtos.dart';

/// Zerlegt einen FuPa-Teamlink in eine [FupaTeamRef].
///
/// Reine Identifikation (Slug/Anzeigename) aus der URL – es werden dabei
/// keinerlei FuPa-Inhalte abgerufen.
class FupaLinkParser {
  static final RegExp _host = RegExp(r'fupa\.net', caseSensitive: false);

  /// Validiert grob, ob der Text ein FuPa-Link ist.
  static bool looksLikeFupaLink(String input) {
    final t = input.trim();
    return _host.hasMatch(t) && (t.startsWith('http') || t.startsWith('www'));
  }

  /// Parst den Link. Gibt null zurück, wenn kein brauchbarer Ref ableitbar ist.
  static FupaTeamRef? parse(String input) {
    final raw = input.trim();
    if (raw.isEmpty) return null;

    var normalized = raw;
    if (!normalized.startsWith('http')) {
      normalized = 'https://$normalized';
    }

    final uri = Uri.tryParse(normalized);
    if (uri == null || !_host.hasMatch(uri.host)) return null;

    final segments =
        uri.pathSegments.where((s) => s.trim().isNotEmpty).toList();
    if (segments.isEmpty) return null;

    // Typische Muster:
    //   /team/<slug>
    //   /club/<verein>/team/<slug>
    //   /<verein>/team/<slug>
    String? slug;
    final teamIdx = segments.indexOf('team');
    if (teamIdx >= 0 && teamIdx + 1 < segments.length) {
      slug = segments[teamIdx + 1];
    } else {
      // Fallback: letztes Segment als Slug verwenden.
      slug = segments.last;
    }

    if (slug.trim().isEmpty) return null;

    return FupaTeamRef(
      url: raw,
      ref: slug.toLowerCase(),
      displayName: _humanize(slug),
    );
  }

  /// Macht aus einem Slug einen lesbaren Namen (best effort).
  static String _humanize(String slug) {
    final cleaned = slug
        .replaceAll(RegExp(r'[-_]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.isEmpty) return slug;
    return cleaned
        .split(' ')
        .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
        .join(' ');
  }
}
