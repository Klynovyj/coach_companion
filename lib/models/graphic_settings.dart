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

  /// Spielerfotos in der Ergebnis-Grafik (Torschützen/Karten), Default aus.
  final bool showPhotos;

  /// Eingebautes Hintergrund-Design (z.B. 'stripes'); null = Verlauf.
  /// Ein eigenes Hintergrundbild [bgImage] hat Vorrang.
  final String? bgPreset;

  /// Logo für dunkle Hintergründe (Data-URL). Im Design-Modus wird je nach
  /// Hintergrundhelligkeit [logo] oder [logoDark] genutzt.
  final String? logoDark;

  /// Design-Modus: eigenes Branding-Design als Hintergrund, App-Logo/Titel aus;
  /// nur die Spiel-Infos werden (verschiebbar) darübergelegt.
  final bool designMode;

  /// Position des Info-Blocks im Design-Modus (0..1, normiert).
  final double infoX;
  final double infoY;

  /// Akzentfarbe (Hex, z.B. „#D4AF37") für Highlights (Trennlinie, VS, Score,
  /// Datum/Uhrzeit, Rubrik-Label). null = Weiß wie bisher.
  final String? accent;

  /// Deckkraft des Hintergrundbilds (0–100). Darunter scheint der Verlauf durch.
  final int bgOpacity;

  /// Mischmodus des Hintergrundbilds mit dem Verlauf darunter:
  /// 'normal' | 'overlay' (Ineinanderkopieren) | 'multiply' | 'screen' |
  /// 'softlight'.
  final String bgBlend;

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
    this.showPhotos = false,
    this.bgPreset,
    this.logoDark,
    this.designMode = false,
    this.infoX = 0.5,
    this.infoY = 0.72,
    this.accent,
    this.bgOpacity = 100,
    this.bgBlend = 'normal',
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
    bool? showPhotos,
    String? bgPreset,
    bool clearBgPreset = false,
    String? logoDark,
    bool clearLogoDark = false,
    bool? designMode,
    double? infoX,
    double? infoY,
    String? accent,
    bool clearAccent = false,
    int? bgOpacity,
    String? bgBlend,
  }) => GraphicSettings(
    id: id ?? this.id,
    title: clearTitle ? null : (title ?? this.title),
    logo: clearLogo ? null : (logo ?? this.logo),
    bgImage: clearBgImage ? null : (bgImage ?? this.bgImage),
    gradTop: gradTop ?? this.gradTop,
    gradBottom: gradBottom ?? this.gradBottom,
    overlayOpacity: overlayOpacity ?? this.overlayOpacity,
    showOpponentLogo: showOpponentLogo ?? this.showOpponentLogo,
    showPhotos: showPhotos ?? this.showPhotos,
    bgPreset: clearBgPreset ? null : (bgPreset ?? this.bgPreset),
    logoDark: clearLogoDark ? null : (logoDark ?? this.logoDark),
    designMode: designMode ?? this.designMode,
    infoX: infoX ?? this.infoX,
    infoY: infoY ?? this.infoY,
    accent: clearAccent ? null : (accent ?? this.accent),
    bgOpacity: bgOpacity ?? this.bgOpacity,
    bgBlend: bgBlend ?? this.bgBlend,
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
    'show_photos': showPhotos ? 1 : 0,
    'bg_preset': bgPreset,
    'logo_dark': logoDark,
    'design_mode': designMode ? 1 : 0,
    'info_x': infoX,
    'info_y': infoY,
    'accent': accent,
    'bg_opacity': bgOpacity,
    'bg_blend': bgBlend,
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
    showPhotos: m['show_photos'] == true || m['show_photos'] == 1,
    bgPreset: (m['bg_preset'] as String?)?.trim().isEmpty == true
        ? null
        : m['bg_preset'] as String?,
    logoDark: (m['logo_dark'] as String?)?.trim().isEmpty == true
        ? null
        : m['logo_dark'] as String?,
    designMode: m['design_mode'] == true || m['design_mode'] == 1,
    infoX: (m['info_x'] as num?)?.toDouble() ?? 0.5,
    infoY: (m['info_y'] as num?)?.toDouble() ?? 0.72,
    accent: (m['accent'] as String?)?.trim().isEmpty == true
        ? null
        : m['accent'] as String?,
    bgOpacity: (m['bg_opacity'] as num?)?.toInt() ?? 100,
    bgBlend: (m['bg_blend'] as String?)?.trim().isNotEmpty == true
        ? m['bg_blend'] as String
        : 'normal',
  );
}
