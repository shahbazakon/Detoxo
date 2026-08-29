import 'package:detoxo/core/design_system/adaptive/adaptive_controls.dart';
import 'package:detoxo/core/design_system/adaptive/platform_adaptive.dart';
import 'package:detoxo/core/design_system/foundations/animated_icons.dart';
import 'package:detoxo/core/design_system/foundations/liquid_glass_border.dart';
import 'package:detoxo/core/design_system/foundations/motion.dart';
import 'package:detoxo/core/design_system/theme/app_theme.dart';
import 'package:detoxo/core/design_system/tokens/app_spacing.dart';
import 'package:flutter/material.dart';

/// Primary call-to-action. Native CNButton on iOS; on Android a [LiquidPill] —
/// a lit brand-gradient pill with a coloured glow, so the hero action reads as
/// the brightest thing on a dark glass screen instead of a flat Material fill.
/// `expand: true` makes it full-width (the old `FullWidthButton` behaviour).
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    required this.label,
    required this.onPressed,
    this.expand = false,
    this.icon,
    this.tint,
    super.key,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool expand;
  final IconData? icon;

  /// Fill hue. Defaults to the live (background-adaptive) brand primary.
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final brand = tint ?? Theme.of(context).colorScheme.primary;
    if (PlatformAdaptive.useCupertino) {
      return AdaptiveButton(
        label: label,
        onPressed: onPressed,
        tint: brand,
        expand: expand,
        icon: icon,
      );
    }
    return LiquidPill(
      tint: brand,
      expand: expand,
      onPressed: onPressed,
      semanticLabel: label,
      child: _PillContent(
        label: label,
        leading: icon == null
            ? null
            : Icon(icon, size: 20, color: onLiquid(brand)),
        color: onLiquid(brand),
      ),
    );
  }
}

/// Ink colour that stays legible on a [LiquidPill] of [fill].
Color onLiquid(Color fill) =>
    ThemeData.estimateBrightnessForColor(fill) == Brightness.dark
    ? Colors.white
    : const Color(0xFF0A0E17);

/// The hero-CTA skin: a single-hue brand sweep (lit from the top-left), a
/// specular [LiquidGlassBorder] rim and a coloured drop-glow, squishing on
/// press. Shared by [PrimaryButton] and [AnimatedIconButton]; pass any [child].
///
/// Deliberately the *only* filled-brand control — [SecondaryButton] is a
/// compact outlined pill so the two never read as the same weight.
class LiquidPill extends StatelessWidget {
  const LiquidPill({
    required this.child,
    required this.tint,
    required this.onPressed,
    this.expand = false,
    this.semanticLabel,
    super.key,
  });

  final Widget child;
  final Color tint;
  final VoidCallback? onPressed;
  final bool expand;
  final String? semanticLabel;

  /// Full-width CTAs sit at the bottom of a screen and carry more weight than
  /// an inline button, so they get a taller pill.
  static const double _expandedHeight = 56;

  @override
  Widget build(BuildContext context) {
    final disabled = onPressed == null;
    final hsl = HSLColor.fromColor(tint);
    final lit = hsl
        .withLightness((hsl.lightness + 0.09).clamp(0.0, 1.0))
        .toColor();
    final shade = hsl
        .withLightness((hsl.lightness - 0.13).clamp(0.0, 1.0))
        .toColor();

    final pill = Container(
      height: expand ? _expandedHeight : AppSizes.controlHeight,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: AppRadius.brPill,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [lit, tint, shade],
          stops: const [0, 0.55, 1],
        ),
        boxShadow: disabled
            ? null
            : [
                // Coloured glow under the pill + a cool depth shadow, the two
                // `box-shadow`s that make the CTA float off the glass.
                BoxShadow(
                  color: tint.withValues(alpha: 0.45),
                  blurRadius: 24,
                  spreadRadius: -6,
                  offset: const Offset(0, 10),
                ),
                BoxShadow(
                  color: context.shadow,
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
      ),
      child: child,
    );

    Widget content = LiquidGlassBorder(
      shape: const StadiumBorder(),
      tint: Colors.white.withValues(alpha: 0.5),
      child: pill,
    );
    if (expand) content = SizedBox(width: double.infinity, child: content);
    // A disabled button skips AppPressable, and with it AppPressable's
    // Semantics — so without this the control is announced as plain static
    // text, and a switch-access user cannot even focus it to learn that it is
    // disabled. Onboarding's sole forward control is disabled by default on two
    // of its steps, which is how this surfaced.
    if (disabled) {
      // `container: true` and no explicit label: the pill's own Text merges up
      // into this node, so the announcement keeps the visible wording instead
      // of needing it restated here.
      return Semantics(
        button: true,
        enabled: false,
        container: true,
        label: semanticLabel,
        child: Opacity(opacity: 0.45, child: content),
      );
    }
    return AppPressable(
      onTap: onPressed!,
      semanticLabel: semanticLabel,
      minTapTarget: AppSizes.minTapTargetSquare,
      child: content,
    );
  }
}

/// Label (+ optional leading widget) laid out for a [LiquidPill].
class _PillContent extends StatelessWidget {
  const _PillContent({
    required this.label,
    required this.color,
    this.leading,
    this.dense = false,
  });

  final String label;
  final Color color;
  final Widget? leading;

  /// Smaller type for the shorter [SecondaryButton] pill.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (leading != null) ...[
          leading!,
          const SizedBox(width: AppSpacing.xs),
        ],
        Text(
          label,
          style: (dense ? text.labelLarge : text.titleMedium)?.copyWith(
            color: color,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
      ],
    );
  }
}

/// Compact inline action (e.g. "Grant", "Restore purchases", "Resume now") —
/// the counterpart to [PrimaryButton], never a smaller copy of it.
///
/// Where the hero CTA is *filled* brand with a glow, this is **outlined**: a
/// short 36dp pill of translucent brand tint behind a brand hairline, brand-
/// coloured label, no gradient and no shadow. Different shape, different
/// weight, same hue — so a card can carry one of each without them competing.
/// Native tinted CNButton on iOS.
class SecondaryButton extends StatelessWidget {
  const SecondaryButton({
    required this.label,
    required this.onPressed,
    this.expand = false,
    this.icon,
    super.key,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool expand;
  final IconData? icon;

  /// Sits clearly below the 44dp hero pill; the 48dp tap floor is restored by
  /// `AppPressable.minTapTarget`, so the shrink is purely visual.
  static const double _height = 36;

  @override
  Widget build(BuildContext context) {
    if (PlatformAdaptive.useCupertino) {
      return AdaptiveButton(
        label: label,
        onPressed: onPressed,
        variant: AdaptiveButtonVariant.tinted,
        expand: expand,
        icon: icon,
      );
    }
    final brand = Theme.of(context).colorScheme.primary;
    final disabled = onPressed == null;

    Widget content = Container(
      height: _height,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: brand.withValues(alpha: 0.12),
        borderRadius: AppRadius.brPill,
        border: Border.all(color: brand.withValues(alpha: 0.45)),
      ),
      child: _PillContent(
        label: label,
        color: brand,
        dense: true,
        leading: icon == null ? null : Icon(icon, size: 18, color: brand),
      ),
    );
    if (expand) content = SizedBox(width: double.infinity, child: content);
    // Same reasoning as PrimaryButton: the disabled path must still announce
    // itself as a disabled button, not as decorative text.
    if (disabled) {
      return Semantics(
        button: true,
        enabled: false,
        container: true,
        label: label,
        child: ExcludeSemantics(child: Opacity(opacity: 0.45, child: content)),
      );
    }
    return AppPressable(
      onTap: onPressed!,
      semanticLabel: label,
      minTapTarget: AppSizes.minTapTargetSquare,
      child: content,
    );
  }
}

/// Text-only, lowest emphasis (e.g. "Skip", "Maybe later").
class GhostButton extends StatelessWidget {
  const GhostButton({required this.label, required this.onPressed, super.key});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => AdaptiveButton(
    label: label,
    onPressed: onPressed,
    variant: AdaptiveButtonVariant.plain,
  );
}

/// A filled CTA whose leading icon plays its morph on every press (and a
/// scale-squish from [AppPressable]). Fully Flutter-rendered so the animated
/// icon shows on every platform — use for hero actions ("Enable now",
/// "Upgrade", "Save limit"). Reduce-motion skips the morph.
class AnimatedIconButton extends StatefulWidget {
  const AnimatedIconButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.tint,
    this.expand = false,
    super.key,
  });

  final String label;
  final AppIcon icon;
  final VoidCallback? onPressed;

  /// Fill hue. Defaults to the live (background-adaptive) brand primary.
  final Color? tint;
  final bool expand;

  @override
  State<AnimatedIconButton> createState() => _AnimatedIconButtonState();
}

class _AnimatedIconButtonState extends State<AnimatedIconButton> {
  final AnimatedIconController _iconController = AnimatedIconController();

  @override
  void dispose() {
    _iconController.dispose();
    super.dispose();
  }

  void _onTap() {
    if (widget.onPressed == null) return;
    if (!(MediaQuery.maybeDisableAnimationsOf(context) ?? false)) {
      _iconController
        ..reset()
        ..animate();
    }
    widget.onPressed!();
  }

  @override
  Widget build(BuildContext context) {
    final brand = widget.tint ?? Theme.of(context).colorScheme.primary;
    final ink = onLiquid(brand);
    return LiquidPill(
      tint: brand,
      expand: widget.expand,
      onPressed: widget.onPressed == null ? null : _onTap,
      semanticLabel: widget.label,
      child: _PillContent(
        label: widget.label,
        color: ink,
        leading: AppAnimatedIcon(
          icon: widget.icon,
          size: 20,
          color: ink,
          controller: _iconController,
        ),
      ),
    );
  }
}

/// Tap-to-open explainer icon — carries a feature's copy in a tooltip instead
/// of an on-screen paragraph. Typically an app-bar action.
class InfoButton extends StatelessWidget {
  const InfoButton(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: message,
      triggerMode: TooltipTriggerMode.tap,
      showDuration: const Duration(seconds: 8),
      margin: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      child: const Padding(
        padding: EdgeInsets.all(AppSpacing.md),
        child: Icon(Icons.info_outline, size: 20),
      ),
    );
  }
}
