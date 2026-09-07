import 'package:detoxo/core/design_system/components/cards.dart';
import 'package:detoxo/core/design_system/foundations/motion.dart';
import 'package:detoxo/core/design_system/tokens/app_spacing.dart';
import 'package:flutter/material.dart';

/// The hamburger control that opens the app's right-side drawer. A single
/// source of truth so the Dashboard, Blocklist and Activity headers stay
/// identical: a primary-tinted circle with a [Icons.menu_rounded] glyph.
///
/// Lives in the design system rather than under the dashboard because three
/// features draw it; reaching into `dashboard/presentation/` for it was a
/// boundary violation the gate could not see (2026-09-06).
class DrawerMenuButton extends StatelessWidget {
  const DrawerMenuButton({required this.onTap, super.key});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: 'Menu',
      child: InkWell(
        borderRadius: AppRadius.brPill,
        onTap: onTap == null
            ? null
            : () {
                AppHaptics.selection();
                onTap!();
              },
        child: IconBadge(
          size: AppSizes.minTapTarget,
          color: scheme.primary,
          fillAlpha: 0.12,
          bordered: true,
          borderWidth: 2,
          child: Icon(Icons.menu_rounded, size: 22, color: scheme.primary),
        ),
      ),
    );
  }
}
