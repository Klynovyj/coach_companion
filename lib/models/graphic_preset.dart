/// Eine gespeicherte Hintergrund-Vorlage (kompletter Look) für die Grafiken.
/// Team-weit, cloud-synchron. Enthält Bild + Farben + Deckkraft/Mischmodus +
/// Akzent, sodass ein Tipp den ganzen Look wiederherstellt.
class GraphicPreset {
  final String id;
  final String name;
  final String? bgImage; // Hintergrundbild als Data-URL (optional)
  final String gradTop;
  final String gradBottom;
  final int overlayOpacity;
  final int bgOpacity;
  final String bgBlend;
  final String? accent;
  final String createdAt; // ISO-8601

  const GraphicPreset({
    required this.id,
    required this.name,
    this.bgImage,
    required this.gradTop,
    required this.gradBottom,
    required this.overlayOpacity,
    required this.bgOpacity,
    required this.bgBlend,
    this.accent,
    required this.createdAt,
  });

  GraphicPreset copyWith({String? name}) => GraphicPreset(
    id: id,
    name: name ?? this.name,
    bgImage: bgImage,
    gradTop: gradTop,
    gradBottom: gradBottom,
    overlayOpacity: overlayOpacity,
    bgOpacity: bgOpacity,
    bgBlend: bgBlend,
    accent: accent,
    createdAt: createdAt,
  );

  Map<String, Object?> toMap() => {
    'id': id,
    'name': name,
    'bg_image': bgImage,
    'grad_top': gradTop,
    'grad_bottom': gradBottom,
    'overlay_opacity': overlayOpacity,
    'bg_opacity': bgOpacity,
    'bg_blend': bgBlend,
    'accent': accent,
    'created_at': createdAt,
  };

  factory GraphicPreset.fromMap(Map<String, Object?> m) => GraphicPreset(
    id: m['id'] as String,
    name: (m['name'] as String?)?.trim().isNotEmpty == true
        ? m['name'] as String
        : 'Vorlage',
    bgImage: (m['bg_image'] as String?)?.trim().isEmpty == true
        ? null
        : m['bg_image'] as String?,
    gradTop: (m['grad_top'] as String?) ?? '#0E3325',
    gradBottom: (m['grad_bottom'] as String?) ?? '#15603F',
    overlayOpacity: (m['overlay_opacity'] as num?)?.toInt() ?? 85,
    bgOpacity: (m['bg_opacity'] as num?)?.toInt() ?? 100,
    bgBlend: (m['bg_blend'] as String?)?.trim().isNotEmpty == true
        ? m['bg_blend'] as String
        : 'normal',
    accent: (m['accent'] as String?)?.trim().isEmpty == true
        ? null
        : m['accent'] as String?,
    createdAt:
        (m['created_at'] as String?) ?? DateTime.now().toIso8601String(),
  );
}
