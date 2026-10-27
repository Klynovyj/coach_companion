/// Anpassbare Einstellungen der Startelf-Grafik (teamweit, cloud-synchron).
///
/// [title] überschreibt den angezeigten Vereinsnamen (null = Default = voller
/// Team-Name). [logo] ist ein eigenes Grafik-Logo als Base64-Data-URL (null =
/// Team-Logo). [bgImage] ist ein optionales Hintergrundfoto (Data-URL).
/// [gradTop]/[gradBottom] sind die Verlaufsfarben (Hex, z.B. „#0E3325") – sie
/// dienen auch als Farb-Tönung über dem Foto. [overlayOpacity] (0–100) steuert,
/// wie stark dieser Verlauf über dem Foto liegt (= Abdunkeln/Transparenz).
class GraphicSettings {
  final String id;
  final String? title;
  final String? logo;
  final String? bgImage;
  final String gradTop;
  final String gradBottom;
  final int overlayOpacity;

  /// Gegner-Logo mit auf die Grafik (optional, Default aus).
  final bool showOpponentLogo;

  static const defaultGradTop = '#0E3325';
  static const defaultGradBottom = '#15603F';
  static const defaultOverlay = 85;

  const GraphicSettings({
    required this.id,
    this.title,
    this.logo,
    this.bgImage,
    this.gradTop = defaultGradTop,
    this.gradBottom = defaultGradBottom,
    this.overlayOpacity = defaultOverlay,
    this.showOpponentLogo = false,
  });

  GraphicSettings copyWith({
    String? id,
    String? title,
    bool clearTitle = false,
    String? logo,
    bool clearLogo = false,
    String? bgImage,
    bool clearBgImage = false,
    String? gradTop,
    String? gradBottom,
    int? overlayOpacity,
    bool? showOpponentLogo,
  }) => GraphicSettings(
    id: id ?? this.id,
    title: clearTitle ? null : (title ?? this.title),
    logo: clearLogo ? null : (logo ?? this.logo),
    bgImage: clearBgImage ? null : (bgImage ?? this.bgImage),
    gradTop: gradTop ?? this.gradTop,
    gradBottom: gradBottom ?? this.gradBottom,
    overlayOpacity: overlayOpacity ?? this.overlayOpacity,
    showOpponentLogo: showOpponentLogo ?? this.showOpponentLogo,
  );

  Map<String, Object?> toMap() => {
    'id': id,
    'title': title,
    'logo': logo,
    'bg_image': bgImage,
    'grad_top': gradTop,
    'grad_bottom': gradBottom,
    'overlay_opacity': overlayOpacity,
    'show_opponent_logo': showOpponentLogo ? 1 : 0,
  };

  factory GraphicSettings.fromMap(Map<String, Object?> m) => GraphicSettings(
    id: m['id'] as String,
    title: (m['title'] as String?)?.trim().isEmpty == true
        ? null
        : m['title'] as String?,
    logo: m['logo'] as String?,
    bgImage: m['bg_image'] as String?,
    gradTop: (m['grad_top'] as String?) ?? defaultGradTop,
    gradBottom: (m['grad_bottom'] as String?) ?? defaultGradBottom,
    overlayOpacity: (m['overlay_opacity'] as num?)?.toInt() ?? defaultOverlay,
    showOpponentLogo:
        m['show_opponent_logo'] == true || m['show_opponent_logo'] == 1,
  );
}
