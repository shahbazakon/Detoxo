import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/features/blocking/block_screen/domain/entities/block_screen_copy.dart';
import 'package:detoxo/features/blocking/block_screen/domain/entities/block_screen_payload.dart';
import 'package:detoxo/features/blocking/block_screen/domain/entities/block_screen_style.dart';
import 'package:detoxo/features/content_counter/content_counter.dart';
import 'package:flutter/material.dart';

/// Flutter mirror of the native block screen (`overlay/BlockScreenRenderer.kt`
/// — the declared source of truth): gradient backdrop from the shared widget
/// palette, plan chip, headline, reason, stat lines and the button column.
/// Sizes scale with [height] against a 640-dp phone; [compact] renders a
/// landscape crop (chip + headline + button row) for the Appearance card.
///
/// MIRROR CONTRACT: colours come from [widgetPaletteFor], copy from
/// [BlockScreenCopy]; only the layout ratios live here.
class BlockScreenPreview extends StatelessWidget {
  const BlockScreenPreview({
    required this.style,
    this.payload,
    this.height = 300,
    this.compact = false,
    super.key,
  });

  final BlockScreenStyle style;
  final BlockScreenPayload? payload;
  final double height;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final p = (payload ?? BlockScreenPayload.preview()).sanitised();
    final dark = switch (style.theme) {
      WidgetTheme.light => false,
      WidgetTheme.dark => true,
      WidgetTheme.system => Theme.of(context).brightness == Brightness.dark,
    };
    final today = p.todayCount < 0 ? 0 : p.todayCount;
    final palette = widgetPaletteFor(
      style.background,
      dark: dark,
      today: today,
    );
    final accent = style.accentByUsage && p.todayCount >= 0
        ? bandColorFor(p.todayCount)
        : palette.label;
    final copy = BlockScreenCopy.from(p, style);
    // A 640-dp phone renders at scale 1; the hub's compact card is smaller.
    final scale = (compact ? height / 220 : height / 640).clamp(0.3, 1.0);
    final aspect = compact ? 16 / 10 : 9 / 19.5;

    return Semantics(
      label: 'Block screen preview. ${copy.semanticsLabel}',
      excludeSemantics: true,
      child: SizedBox(
        height: height,
        width: height * aspect,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.lg * scale + 6),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [palette.bgTop, palette.bgBottom],
              ),
              border: Border.all(color: palette.stroke),
              borderRadius: BorderRadius.circular(AppRadius.lg * scale + 6),
            ),
            child: Padding(
              padding: EdgeInsets.all(28 * scale),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!compact) const Spacer(flex: 3),
                  if (copy.chip.isNotEmpty) ...[
                    _Chip(
                      label: copy.chip,
                      accent: accent,
                      text: palette.today,
                      scale: scale,
                    ),
                    SizedBox(height: 14 * scale),
                  ],
                  Text(
                    copy.headline,
                    maxLines: compact ? 2 : 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.today,
                      fontSize: 28 * scale,
                      fontWeight: FontWeight.w800,
                      height: 1.15,
                    ),
                  ),
                  if (!compact && copy.reason.isNotEmpty) ...[
                    SizedBox(height: 10 * scale),
                    Text(
                      copy.reason,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.total,
                        fontSize: 16 * scale,
                        height: 1.3,
                      ),
                    ),
                  ],
                  if (!compact)
                    for (final line in copy.stats) ...[
                      SizedBox(height: 12 * scale),
                      Text(
                        line,
                        style: TextStyle(
                          color: palette.today,
                          fontSize: 18 * scale,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  const Spacer(flex: 4),
                  if (compact)
                    Row(
                      children: [
                        for (final b in copy.buttons.take(2)) ...[
                          Expanded(
                            child: _Button(
                              button: b,
                              palette: palette,
                              accent: accent,
                              scale: scale,
                            ),
                          ),
                          SizedBox(width: 8 * scale),
                        ],
                      ],
                    )
                  else
                    for (final b in copy.buttons) ...[
                      _Button(
                        button: b,
                        palette: palette,
                        accent: accent,
                        scale: scale,
                      ),
                      SizedBox(height: 12 * scale),
                    ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.accent,
    required this.text,
    required this.scale,
  });

  final String label;
  final Color accent;
  final Color text;
  final double scale;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: 14 * scale,
        vertical: 7 * scale,
      ),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.2),
        border: Border.all(color: accent.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: text,
          fontSize: 13 * scale,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8 * scale,
        ),
      ),
    );
  }
}

class _Button extends StatelessWidget {
  const _Button({
    required this.button,
    required this.palette,
    required this.accent,
    required this.scale,
  });

  final BlockScreenButton button;
  final WidgetPalette palette;
  final Color accent;
  final double scale;

  @override
  Widget build(BuildContext context) {
    final fill = button.primary
        ? accent
        : button.ghost
        ? Colors.transparent
        : palette.today.withValues(alpha: 0.12);
    // A locked ghost exit (its countdown running) is dimmed like the real one.
    return Opacity(
      opacity: button.locked ? 0.55 : 1,
      child: Container(
        height: 48 * scale,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(14 * scale),
          border: button.primary || button.ghost
              ? null
              : Border.all(color: palette.stroke),
        ),
        child: Text(
          button.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            // Navy on the accent, white on a deep-red usage band — whichever
            // reads (the native renderer picks the same way).
            color: button.primary ? onColorFor(accent) : palette.today,
            fontSize: 16 * scale,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
