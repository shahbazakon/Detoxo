import 'package:detoxo/core/design_system/design_system.dart';
import 'package:flutter/material.dart';

export 'package:detoxo/core/design_system/components/feedback.dart'
    show EmptyState;
export 'package:detoxo/core/design_system/components/section_header.dart'
    show SectionHeader;

/// Shared composites kept at their original names/APIs so the ~13 screens that
/// already use them keep compiling — now reskinned over the glass design system.
/// New screens should prefer the design-system components directly
/// (`GlassCard`, `StatCard`, `GlassListTile`, `PrimaryButton`, …).

/// A titled, padded glass section used across screens.
class SectionCard extends StatelessWidget {
  const SectionCard({
    required this.child,
    this.title,
    this.trailing,
    this.padding = const EdgeInsets.all(14),
    super.key,
  });

  final Widget child;
  final String? title;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return GlassContainer(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    title!,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 10),
          ],
          child,
        ],
      ),
    );
  }
}

// EmptyState and SectionHeader now live in the design system
// (components/feedback.dart, components/section_header.dart) and are re-exported
// above so existing `common_widgets.dart` importers keep compiling.

/// A labelled navigation tile for the "more features" list. Pass [animatedIcon]
/// for a morphing badge glyph that plays on appear and replays on every tap;
/// [icon] is the static fallback for un-migrated call sites.
class FeatureTile extends StatefulWidget {
  const FeatureTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailing,
    this.animatedIcon,
    super.key,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Widget? trailing;
  final AppIcon? animatedIcon;

  @override
  State<FeatureTile> createState() => _FeatureTileState();
}

class _FeatureTileState extends State<FeatureTile> {
  final AnimatedIconController _iconController = AnimatedIconController();

  @override
  void dispose() {
    _iconController.dispose();
    super.dispose();
  }

  void _onTap() {
    if (widget.animatedIcon != null &&
        !(MediaQuery.maybeDisableAnimationsOf(context) ?? false)) {
      _iconController
        ..reset()
        ..animate();
    }
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.secondary;
    final leading = widget.animatedIcon != null
        ? AppAnimatedIcon(
            icon: widget.animatedIcon!,
            size: 20,
            color: accent,
            controller: _iconController,
            playOnAppear: true,
          )
        : Icon(widget.icon, size: 20, color: accent);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: GlassListTile(
        onTap: _onTap,
        leading: IconBadge(
          size: 38,
          shape: BoxShape.rectangle,
          fillAlpha: 0.16,
          child: leading,
        ),
        title: widget.title,
        subtitle: widget.subtitle,
        trailing: widget.trailing ?? const Icon(Icons.chevron_right),
      ),
    );
  }
}

/// A full-width primary button for screen-level call-to-actions.
class FullWidthButton extends StatelessWidget {
  const FullWidthButton({
    required this.label,
    required this.onPressed,
    super.key,
  });

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) =>
      PrimaryButton(label: label, onPressed: onPressed, expand: true);
}

/// Formats a [Duration] as mm:ss (or h:mm:ss).
String formatCountdown(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

/// A muted inline hint shown when a section is empty.
class InlineHint extends StatelessWidget {
  const InlineHint({required this.icon, required this.text, super.key});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Row(
        children: [
          Icon(icon, size: 18, color: context.glass.onGlassMuted),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: context.glass.onGlassMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
