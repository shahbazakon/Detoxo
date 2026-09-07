import 'package:detoxo/core/design_system/tokens/app_spacing.dart';
import 'package:flutter/material.dart';

/// An uppercase group header for settings-style lists (label above a run of
/// glass rows, instead of nesting them inside another glass card). A heading
/// to a screen reader, so TalkBack can jump group to group down a long scroll.
///
/// Carries the list's vertical rhythm itself — `md` above, `sm` below — so a
/// screen places nothing between one section and the next.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(
        left: 4,
        top: AppSpacing.md,
        bottom: AppSpacing.sm,
      ),
      child: Semantics(
        header: true,
        child: Text(
          label.toUpperCase(),
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
          ),
        ),
      ),
    );
  }
}
