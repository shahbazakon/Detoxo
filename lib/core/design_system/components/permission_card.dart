import 'package:detoxo/core/design_system/components/badges.dart';
import 'package:detoxo/core/design_system/components/buttons.dart';
import 'package:detoxo/core/design_system/foundations/glass_container.dart';
import 'package:detoxo/core/design_system/tokens/app_colors.dart';
import 'package:detoxo/core/design_system/tokens/app_spacing.dart';
import 'package:flutter/material.dart';

/// Generic shell for a permission row: leading icon, title + required/optional
/// pill, a one-line "why", and a trailing grant control or granted check.
/// Feature code (PermissionRow) binds an `AppPermission` to this shell.
class PermissionCard extends StatelessWidget {
  const PermissionCard({
    required this.icon,
    required this.title,
    required this.why,
    required this.granted,
    required this.onGrant,
    this.isRequired = false,
    this.unknown = false,
    this.permanentlyDenied = false,
    this.actionLabel,
    super.key,
  });

  final IconData icon;
  final String title;
  final String why;
  final bool granted;
  final bool isRequired;

  /// The status read didn't answer (channel hiccup) and there is no granted
  /// history to fall back on — render a neutral "Checking…" row, not a red
  /// denied state. Ignored when [granted] is true.
  ///
  /// Pass [actionLabel] alongside this to offer a way out (e.g. "Retry");
  /// without it the row is informational, which is right for the permission
  /// funnel where the next status read fixes itself.
  final bool unknown;

  /// When true the OS won't prompt again, so the action label becomes
  /// "Open settings" (its callback should route to the app's system settings).
  final bool permanentlyDenied;

  /// Overrides the action label — e.g. "Fix this" when the tap opens a help
  /// sheet rather than a system screen.
  final String? actionLabel;
  final VoidCallback onGrant;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final accent = Theme.of(context).colorScheme.secondary;
    return GlassContainer(
      enableBlur: false,
      borderColor: granted ? AppColors.success.withValues(alpha: 0.4) : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(AppSpacing.sm),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.16),
              borderRadius: AppRadius.brMd,
            ),
            child: Icon(icon, color: accent),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        style: text.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (isRequired) ...[
                      const SizedBox(width: AppSpacing.xs),
                      const Pill(label: 'Required', tone: AppTone.danger),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(why, style: text.bodySmall),
                const SizedBox(height: AppSpacing.sm),
                if (granted)
                  const Row(
                    children: [
                      Icon(
                        Icons.check_circle,
                        color: AppColors.success,
                        size: 18,
                      ),
                      SizedBox(width: AppSpacing.xs),
                      Text('Granted'),
                    ],
                  )
                else if (unknown)
                  Row(
                    children: [
                      Icon(
                        Icons.sync,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        size: 18,
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      Text(
                        'Checking…',
                        style: text.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      // An unknown state with no way out is a dead end: the
                      // permission funnel re-reads on its own, but a screen
                      // whose data failed to load needs the user to ask again.
                      // Opt-in via [actionLabel] so the funnel's rows, which
                      // recover by themselves, stay button-free.
                      if (actionLabel != null) ...[
                        const Spacer(),
                        SecondaryButton(
                          label: actionLabel!,
                          onPressed: onGrant,
                        ),
                      ],
                    ],
                  )
                else
                  SecondaryButton(
                    label:
                        actionLabel ??
                        (permanentlyDenied ? 'Open settings' : 'Grant'),
                    onPressed: onGrant,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
