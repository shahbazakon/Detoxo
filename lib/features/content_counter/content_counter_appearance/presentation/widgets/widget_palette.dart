import 'dart:math' as math;

import 'package:detoxo/features/content_counter/content_counter_core/domain/entities/counter_style_enums.dart';
import 'package:detoxo/features/content_counter/content_counter_core/domain/usage_ladder.dart';
import 'package:flutter/material.dart';

/// One surface's colours. MIRROR CONTRACT: every literal reproduces the native
/// `Palette` / `paletteFor` in `widget/WidgetBitmapRenderer.kt` — the declared
/// source of truth for the home widget AND the block screen. Edit the Kotlin
/// first, then mirror here.
///
/// Contrast: `today` on `bgTop` ≥ 16:1 in both themes; `total` ≥ 9:1 dark and
/// ≥ 5.5:1 light; `label` (the accent) is ≈ 3.1:1 on the light glass and is
/// therefore used only as a fill / for large bold text, never for body copy.
class WidgetPalette {
  const WidgetPalette({
    required this.bgTop,
    required this.bgBottom,
    required this.stroke,
    required this.today,
    required this.label,
    required this.total,
  });

  final Color bgTop;
  final Color bgBottom;
  final Color stroke;
  final Color today;
  final Color label;
  final Color total;
}

WidgetPalette widgetPaletteFor(
  WidgetBackground background, {
  required bool dark,
  required int today,
}) {
  final textPrimary = dark ? const Color(0xFFFFFFFF) : const Color(0xFF14151A);
  final textAccent = dark ? const Color(0xFF44E2CD) : const Color(0xFF12A594);
  final textMuted = dark ? const Color(0xFFB8C0D9) : const Color(0xFF5A6072);
  final band = bandColorFor(today);

  switch (background) {
    case WidgetBackground.glassBrand:
      return WidgetPalette(
        bgTop: dark ? const Color(0xFF2E2470) : const Color(0xFFEDE7FF),
        bgBottom: dark ? const Color(0xFF10233A) : const Color(0xFFDFF6F1),
        stroke: dark ? const Color(0x5544E2CD) : const Color(0x3344E2CD),
        today: textPrimary,
        label: textAccent,
        total: textMuted,
      );
    case WidgetBackground.solid:
      return WidgetPalette(
        bgTop: dark ? const Color(0xFF141B2E) : const Color(0xFFF3F5FC),
        bgBottom: dark ? const Color(0xFF141B2E) : const Color(0xFFF3F5FC),
        stroke: dark ? const Color(0x1FFFFFFF) : const Color(0x1A101012),
        today: textPrimary,
        label: textAccent,
        total: textMuted,
      );
    case WidgetBackground.usageTint:
      final base = dark ? const Color(0xFF0B1326) : const Color(0xFFFFFFFF);
      return WidgetPalette(
        bgTop: Color.lerp(base, band, dark ? 0.30 : 0.20)!,
        bgBottom: Color.lerp(base, band, dark ? 0.14 : 0.34)!,
        stroke: band.withValues(alpha: 0.4),
        today: textPrimary,
        label: textAccent,
        total: textMuted,
      );
    case WidgetBackground.glassDark:
      return WidgetPalette(
        bgTop: dark ? const Color(0xFF171F33) : const Color(0xFFFFFFFF),
        bgBottom: dark ? const Color(0xFF0B1326) : const Color(0xFFEDF0FA),
        stroke: dark ? const Color(0x33FFFFFF) : const Color(0x22101012),
        today: textPrimary,
        label: textAccent,
        total: textMuted,
      );
  }
}

/// Text colour for a control filled with [fill]: navy where it reads best,
/// white otherwise. The accent takes navy at ≥ 6:1; "Colour by usage" swaps
/// the accent for the usage band, whose deep red drops navy to 3.6:1 while
/// white is 5.2:1. Mirrors `onColorFor` in `overlay/BlockScreenRenderer.kt`.
Color onColorFor(Color fill) {
  const navy = Color(0xFF0B1326);
  return _contrast(navy, fill) >= _contrast(Colors.white, fill)
      ? navy
      : Colors.white;
}

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}
