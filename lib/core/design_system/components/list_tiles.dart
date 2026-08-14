import 'package:detoxo/core/design_system/components/badges.dart';
import 'package:detoxo/core/design_system/components/toggle.dart';
import 'package:detoxo/core/design_system/foundations/glass_container.dart';
import 'package:detoxo/core/design_system/foundations/motion.dart';
import 'package:detoxo/core/design_system/tokens/app_spacing.dart';
import 'package:flutter/material.dart';

/// A glass row used in lists (feature entries, quick actions). Flat translucent
/// fill (no per-row blur) so a long list stays smooth.
class GlassListTile extends StatelessWidget {
  const GlassListTile({
    required this.title,
    this.leading,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.selected = false,
    super.key,
  });

  final Widget? leading;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// Elevates the row to the premium active state (see [GlassContainer.selected]).
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final row = GlassContainer(
      enableBlur: false,
      selected: selected,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          if (leading != null) ...[
            leading!,
            const SizedBox(width: AppSpacing.sm),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: text.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: text.bodySmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: AppSpacing.sm),
            trailing!,
          ],
        ],
      ),
    );
    if (onTap == null) return row;
    return AppPressable(
      onTap: onTap!,
      // Forward to Semantics so screen readers announce the picked state.
      selected: selected,
      minTapTarget: const Size(0, AppSizes.minTapTarget),
      child: row,
    );
  }
}

/// A labelled row with a trailing [AppToggle]. When [locked], shows a
/// "Premium" pill in the same trailing slot instead of the switch — keeping
/// every row in a list visually consistent (fixes the blocklist inconsistency).
class AppToggleTile extends StatelessWidget {
  const AppToggleTile({
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.leading,
    this.enabled = true,
    this.locked = false,
    this.onLockedTap,
    this.selected = false,
    super.key,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool enabled;
  final bool locked;
  final VoidCallback? onLockedTap;

  /// Elevates the row to the premium active state (see [GlassContainer.selected]).
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final trailing = locked
        ? const Pill(
            label: 'Premium',
            tone: AppTone.warning,
            icon: Icons.lock_outline,
          )
        : AppToggle(
            value: value,
            onChanged: onChanged,
            enabled: enabled,
            semanticLabel: title,
          );
    return GlassListTile(
      leading: leading,
      title: title,
      subtitle: subtitle,
      trailing: trailing,
      selected: selected,
      onTap: locked ? onLockedTap : null,
    );
  }
}
