import 'package:detoxo/core/design_system/components/buttons.dart';
import 'package:detoxo/core/design_system/components/cards.dart';
import 'package:detoxo/core/design_system/components/overlays.dart';
import 'package:detoxo/core/design_system/theme/app_theme.dart';
import 'package:detoxo/core/design_system/tokens/app_colors.dart';
import 'package:detoxo/core/design_system/tokens/app_spacing.dart';
import 'package:flutter/material.dart';

/// A standardized dialog body — an optional leading icon, a title, a [message] or
/// custom [content], and a right-aligned [actions] row — laid out over the frosted
/// [GlassDialog] chrome. Use [AppDialog.show] for a custom dialog and
/// [AppDialog.confirm] for a yes/no prompt.
class AppDialog extends StatelessWidget {
  const AppDialog({
    required this.title,
    this.message,
    this.content,
    this.actions,
    this.icon,
    this.accent,
    super.key,
  });

  final String title;

  /// A simple body line. Ignored when [content] is supplied.
  final String? message;

  /// Custom body (e.g. form fields). Rendered below [message] if both are given.
  final Widget? content;
  final List<Widget>? actions;
  final IconData? icon;
  final Color? accent;

  /// Shows an [AppDialog] over the frosted [GlassDialog]. Returns whatever the
  /// dialog is popped with. Set [barrierDismissible] to `false` and [blocking]
  /// to `true` for a mandatory dialog the user cannot dismiss (e.g. a forced
  /// app update) — the caller must then supply an action that pops it.
  static Future<T?> show<T>({
    required BuildContext context,
    required String title,
    String? message,
    Widget? content,
    List<Widget>? actions,
    IconData? icon,
    Color? accent,
    bool barrierDismissible = true,
    bool blocking = false,
  }) {
    return GlassDialog.show<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      blocking: blocking,
      child: AppDialog(
        title: title,
        message: message,
        content: content,
        actions: actions,
        icon: icon,
        accent: accent,
      ),
    );
  }

  /// A yes/no confirmation. Resolves to `true` when confirmed, `false` when
  /// cancelled or dismissed. [destructive] tints the confirm action red.
  static Future<bool> confirm({
    required BuildContext context,
    required String title,
    String? message,
    String confirmLabel = 'Confirm',
    String cancelLabel = 'Cancel',
    bool destructive = false,
    IconData? icon,
  }) async {
    final confirmed = await show<bool>(
      context: context,
      title: title,
      message: message,
      icon: icon,
      accent: destructive ? AppColors.danger : null,
      actions: [
        GhostButton(
          label: cancelLabel,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        PrimaryButton(
          label: confirmLabel,
          tint: destructive ? AppColors.danger : null,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
    return confirmed ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final actionList = actions;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header + content scroll on overflow (large text scale + IME on a
        // short screen); the action row below stays pinned and reachable.
        Flexible(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (icon != null) ...[
                  IconBadge(icon: icon, color: accent),
                  const SizedBox(height: AppSpacing.md),
                ],
                Text(
                  title,
                  style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                if (message != null) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    message!,
                    style: text.bodyMedium?.copyWith(
                      color: context.glass.onGlassMuted,
                    ),
                  ),
                ],
                if (content != null) ...[
                  const SizedBox(height: AppSpacing.md),
                  content!,
                ],
              ],
            ),
          ),
        ),
        if (actionList != null && actionList.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.lg),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              for (var i = 0; i < actionList.length; i++) ...[
                if (i > 0) const SizedBox(width: AppSpacing.sm),
                actionList[i],
              ],
            ],
          ),
        ],
      ],
    );
  }
}
