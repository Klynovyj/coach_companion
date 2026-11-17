import 'package:flutter/material.dart';

/// Einheitlicher Baukasten für die Einstellungs-Panels im Designer
/// (handygerecht): Abschnitte als Karten, Zeilen mit dem Bedienelement immer
/// bündig rechts, Auswahlen als gleich große Vorschau-Kacheln.

const double kPanelGap = 16;

/// ⓘ: Erklärung beim Antippen (bzw. Überfahren am PC).
class InfoIcon extends StatelessWidget {
  const InfoIcon(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: text,
    triggerMode: TooltipTriggerMode.tap,
    showDuration: const Duration(seconds: 6),
    preferBelow: false,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Icon(
        Icons.info_outline,
        size: 18,
        color: Theme.of(context).hintColor,
      ),
    ),
  );
}

/// Kennzeichen „Team“: Option gilt für alle Grafiken des Teams.
class TeamBadge extends StatelessWidget {
  const TeamBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message:
          'Gilt für alle Grafiken des Teams – auch bei den anderen Trainern. '
          'Rückgängig geht wie gewohnt.',
      triggerMode: TooltipTriggerMode.tap,
      showDuration: const Duration(seconds: 6),
      child: Container(
        margin: const EdgeInsets.only(left: 6),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: scheme.tertiaryContainer,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.groups, size: 13, color: scheme.onTertiaryContainer),
            const SizedBox(width: 3),
            Text(
              'Team',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: scheme.onTertiaryContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Abschnitt als Karte: Kopf „Titel · [Team] · ⓘ“, darunter der Inhalt.
class PanelSection extends StatelessWidget {
  const PanelSection({
    super.key,
    required this.title,
    required this.children,
    this.info,
    this.team = false,
    this.trailing,
  });

  final String title;
  final String? info;
  final bool team;
  final Widget? trailing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 30,
            child: Row(
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: scheme.primary,
                  ),
                ),
                if (team) const TeamBadge(),
                if (info != null) InfoIcon(info!),
                const Spacer(),
                ?trailing,
              ],
            ),
          ),
          const SizedBox(height: 4),
          ...children,
        ],
      ),
    );
  }
}

/// Zeile: Name (+ⓘ direkt daneben) links, Bedienelement bündig rechts.
class PanelRow extends StatelessWidget {
  const PanelRow({
    super.key,
    required this.title,
    this.info,
    this.leading,
    this.trailing,
    this.onTap,
    this.team = false,
  });

  final String title;
  final String? info;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool team;

  @override
  Widget build(BuildContext context) {
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 52),
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 12)],
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(title, style: const TextStyle(fontSize: 15)),
                ),
                if (team) const TeamBadge(),
                if (info != null) InfoIcon(info!),
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ],
      ),
    );
    if (onTap == null) return row;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: row,
    );
  }
}

/// Schalter-Zeile (Schalter immer am rechten Rand).
class PanelSwitch extends StatelessWidget {
  const PanelSwitch({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.info,
    this.team = false,
  });

  final String title;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? info;
  final bool team;

  @override
  Widget build(BuildContext context) => PanelRow(
    title: title,
    info: info,
    team: team,
    onTap: onChanged == null ? null : () => onChanged!(!value),
    trailing: Switch(value: value, onChanged: onChanged),
  );
}

/// Regler: Kopf mit Wert rechts, Regler über die volle Breite darunter.
class PanelSlider extends StatelessWidget {
  const PanelSlider({
    super.key,
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.onChangeEnd,
    this.valueText,
    this.divisions,
    this.info,
  });

  final String title;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;
  final String? valueText;
  final int? divisions;
  final String? info;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(
          children: [
            Flexible(child: Text(title, style: const TextStyle(fontSize: 15))),
            if (info != null) InfoIcon(info!),
            const Spacer(),
            Text(
              valueText ?? value.round().toString(),
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      Slider(
        value: value.clamp(min, max).toDouble(),
        min: min,
        max: max,
        divisions: divisions,
        onChanged: onChanged,
        onChangeEnd: onChangeEnd,
      ),
    ],
  );
}

/// Segment-Knopf über die volle Breite (2–4 Optionen).
class PanelSegment<T> extends StatelessWidget {
  const PanelSegment({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  /// (Wert, Name, Symbol?)
  final List<(T, String, IconData?)> options;
  final T selected;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: SizedBox(
      width: double.infinity,
      child: SegmentedButton<T>(
        showSelectedIcon: false,
        segments: [
          for (final o in options)
            ButtonSegment<T>(
              value: o.$1,
              icon: o.$3 == null ? null : Icon(o.$3, size: 18),
              label: FittedBox(fit: BoxFit.scaleDown, child: Text(o.$2)),
            ),
        ],
        selected: {selected},
        onSelectionChanged: (s) => onChanged(s.first),
      ),
    ),
  );
}

/// Waagerecht scrollbare Reihe gleich großer Kacheln.
class PanelTiles extends StatelessWidget {
  const PanelTiles({super.key, required this.children, this.height = 92});

  final List<Widget> children;
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: children.length,
      separatorBuilder: (_, _) => const SizedBox(width: 10),
      itemBuilder: (_, i) => children[i],
    ),
  );
}

/// Eine Vorschau-Kachel (64 px) mit Namen; gewählt = Rand + ✓.
class PanelTile extends StatelessWidget {
  const PanelTile({
    super.key,
    required this.preview,
    required this.label,
    required this.selected,
    required this.onTap,
    this.onLongPress,
    this.size = 64,
  });

  final Widget preview;
  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: size + 8,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          children: [
            Stack(
              children: [
                Container(
                  width: size,
                  height: size,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: selected ? scheme.primary : scheme.outlineVariant,
                      width: selected ? 3 : 1,
                    ),
                  ),
                  child: preview,
                ),
                if (selected)
                  Positioned(
                    right: 3,
                    top: 3,
                    child: Container(
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        shape: BoxShape.circle,
                      ),
                      padding: const EdgeInsets.all(2),
                      child: Icon(
                        Icons.check,
                        size: 12,
                        color: scheme.onPrimary,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Farbkreise gleicher Größe (+ optional „eigene Farbe“).
class PanelColorDots extends StatelessWidget {
  const PanelColorDots({
    super.key,
    required this.colors,
    required this.selected,
    required this.onPick,
    this.onCustom,
    this.customSelected,
  });

  /// (Wert, Farbe, Name)
  final List<(String, Color, String)> colors;
  final String selected;
  final ValueChanged<String> onPick;
  final VoidCallback? onCustom;

  /// Eigene (nicht in [colors]) gewählte Farbe zur Anzeige.
  final Color? customSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget dot(
      Color c,
      bool sel,
      VoidCallback onTap,
      String tip, {
      Widget? child,
    }) => Tooltip(
      message: tip,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: c,
            shape: BoxShape.circle,
            border: Border.all(
              color: sel ? scheme.primary : scheme.outlineVariant,
              width: sel ? 3 : 1,
            ),
          ),
          child:
              child ??
              (sel
                  ? Icon(
                      Icons.check,
                      size: 18,
                      color: c.computeLuminance() > 0.5
                          ? Colors.black
                          : Colors.white,
                    )
                  : null),
        ),
      ),
    );
    final known = colors.any((c) => c.$1 == selected);
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(vertical: 6),
        children: [
          for (final c in colors)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: dot(c.$2, c.$1 == selected, () => onPick(c.$1), c.$3),
            ),
          if (!known && customSelected != null)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: dot(customSelected!, true, () {}, 'Eigene Farbe'),
            ),
          if (onCustom != null)
            dot(
              Colors.transparent,
              false,
              onCustom!,
              'Eigene Farbe wählen',
              child: Container(
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: SweepGradient(
                    colors: [
                      Colors.red,
                      Colors.yellow,
                      Colors.green,
                      Colors.cyan,
                      Colors.blue,
                      Colors.purple,
                      Colors.red,
                    ],
                  ),
                ),
                child: const Icon(Icons.add, color: Colors.white, size: 20),
              ),
            ),
        ],
      ),
    );
  }
}

/// Aktionsknopf über die volle Breite.
class PanelAction extends StatelessWidget {
  const PanelAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
    this.info,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool primary;
  final String? info;

  @override
  Widget build(BuildContext context) {
    final style = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size.fromHeight(48)),
      alignment: Alignment.centerLeft,
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 16),
      ),
    );
    final btn = primary
        ? FilledButton.icon(
            style: style,
            onPressed: onTap,
            icon: Icon(icon),
            label: Text(label),
          )
        : FilledButton.tonalIcon(
            style: style,
            onPressed: onTap,
            icon: Icon(icon),
            label: Text(label),
          );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: btn),
          if (info != null) InfoIcon(info!),
        ],
      ),
    );
  }
}

/// Zugeklappte „Feinheiten“ (Profi-Optionen) in einer Karte.
class PanelFinetune extends StatelessWidget {
  const PanelFinetune({super.key, required this.children, this.title});

  final List<Widget> children;
  final String? title;

  @override
  Widget build(BuildContext context) => Theme(
    data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
    child: ExpansionTile(
      title: Text(
        title ?? 'Feinheiten',
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
      leading: const Icon(Icons.tune, size: 20),
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 4),
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  );
}
