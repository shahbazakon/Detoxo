import 'package:detoxo/core/design_system/foundations/motion.dart';
import 'package:detoxo/core/design_system/theme/app_theme.dart';
import 'package:detoxo/core/design_system/tokens/app_motion.dart';
import 'package:detoxo/core/design_system/tokens/app_spacing.dart';
import 'package:flutter/material.dart';

/// One selectable option in a [VariantCarousel]: a short label, a mini preview,
/// its selected state, and a tap handler. Kept self-contained (no generics) so
/// the carousel stays a simple, reusable, variance-clean widget.
class VariantOption {
  const VariantOption({
    required this.label,
    required this.preview,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final Widget preview;
  final bool selected;
  final VoidCallback onTap;
}

/// A compact, horizontally-scrolling picker of style variants — a live preview
/// per card with the label beneath; the selected card gets an accent ring +
/// check badge. Used by the counter's bubble / widget editors. The Appearance
/// background picker is the same shape with the name shown once below the row
/// (`_BgCard` there) — the next picker of either kind should reuse this one.
class VariantCarousel extends StatelessWidget {
  const VariantCarousel({
    required this.options,
    this.height = 104,
    this.cardWidth = 96,
    super.key,
  });

  final List<VariantOption> options;
  final double height;
  final double cardWidth;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
        itemCount: options.length,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.sm),
        itemBuilder: (context, i) {
          final option = options[i];
          return _VariantCard(
            label: option.label,
            selected: option.selected,
            width: cardWidth,
            onTap: option.onTap,
            child: option.preview,
          );
        },
      ),
    );
  }
}

class _VariantCard extends StatelessWidget {
  const _VariantCard({
    required this.label,
    required this.selected,
    required this.width,
    required this.onTap,
    required this.child,
  });

  final String label;
  final bool selected;
  final double width;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final accent = Theme.of(context).colorScheme.secondary;
    final borderWidth = selected ? 2.0 : 1.0;
    return AppPressable(
      onTap: onTap,
      selected: selected,
      child: AnimatedContainer(
        duration: AppDurations.fast,
        curve: AppCurves.standard,
        width: width,
        padding: const EdgeInsets.all(AppSpacing.xs),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.md),
          color: context.glass.fillBottom,
          border: Border.all(
            color: selected ? accent : context.glass.border,
            width: borderWidth,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: accent.withValues(alpha: 0.30),
                    blurRadius: 12,
                  ),
                ]
              : null,
        ),
        child: Column(
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Center(child: FittedBox(child: child)),
                  if (selected)
                    Positioned(
                      top: 0,
                      right: 0,
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: accent,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.check,
                          size: 12,
                          color: Theme.of(context).colorScheme.onSecondary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.labelSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: selected ? accent : context.glass.onGlassMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
