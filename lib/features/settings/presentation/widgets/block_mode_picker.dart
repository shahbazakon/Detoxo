import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/core/widgets/common_widgets.dart';
import 'package:detoxo/features/blocking/blocking.dart' show BlockingMode;
import 'package:flutter/material.dart';

/// The block-mode picker and its entry tile, cubit-free so a widget test can
/// pump them bare (the `ModeSelector` precedent). The Settings screen supplies
/// the cubit reads and the permission funnel.
///
/// The picker offers four of `BlockingMode`'s values. `BLOCK_SCREEN` is the
/// only mode that raises the wall on a plan block; a spent daily limit, a
/// schedule or a drained Conscious bank raise it in every mode (native
/// `WallPolicy`).
const blockModes = <(BlockingMode, String, String)>[
  (BlockingMode.pressBack, 'Press back', 'Exits the reel (recommended)'),
  (
    BlockingMode.blockScreen,
    'Block screen',
    'Exits the reel and shows a full-screen wall with a way back',
  ),
  (
    BlockingMode.killApp,
    'Close the app',
    'Force-closes (exit app) the offending app',
  ),
  (
    BlockingMode.lockApp,
    'Lock app',
    'Locks the app behind your PIN, like an app locker',
  ),
];

String blockModeTitle(BlockingMode m) =>
    blockModes.firstWhere((e) => e.$1 == m, orElse: () => blockModes.first).$2;

/// A radio-style row for the pickers. `selected` reaches Semantics through
/// [GlassListTile], so a screen reader announces which option is active.
class OptionTile extends StatelessWidget {
  const OptionTile({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GlassListTile(
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color: selected
            ? Theme.of(context).colorScheme.secondary
            : context.glass.onGlassMuted,
      ),
      title: title,
      subtitle: subtitle,
      selected: selected,
      onTap: onTap,
    );
  }
}

/// "Needs X — tap to allow": the truthful row under a feature whose switch is
/// on but whose Android grant is missing (EVO-036 / EVO-042). One shape for
/// the block mode, the soft nudge and notification silence.
class PermissionNeededRow extends StatelessWidget {
  const PermissionNeededRow({
    required this.title,
    required this.subtitle,
    required this.onTap,
    super.key,
  });

  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: GlassListTile(
        leading: const Icon(Icons.error_outline, color: AppColors.warning),
        title: title,
        subtitle: subtitle,
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

/// The four selectable modes.
class BlockModeOptions extends StatelessWidget {
  const BlockModeOptions({
    required this.selected,
    required this.onSelect,
    super.key,
  });

  final BlockingMode selected;
  final ValueChanged<BlockingMode> onSelect;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final e in blockModes)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.xs),
            child: OptionTile(
              title: e.$2,
              subtitle: e.$3,
              selected: selected == e.$1,
              onTap: () => onSelect(e.$1),
            ),
          ),
      ],
    );
  }
}

/// Settings entry for the picker. With [needsOverlay] the Block screen mode
/// still bounces the reel but no wall can ever appear — the row says so and
/// [onGrant] offers the fix.
class BlockModeTile extends StatelessWidget {
  const BlockModeTile({
    required this.mode,
    required this.needsOverlay,
    required this.onTap,
    required this.onGrant,
    super.key,
  });

  final BlockingMode mode;
  final bool needsOverlay;
  final VoidCallback onTap;
  final VoidCallback onGrant;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        FeatureTile(
          icon: Icons.touch_app_outlined,
          title: 'When a reel is detected',
          subtitle: blockModeTitle(mode),
          onTap: onTap,
        ),
        if (needsOverlay)
          PermissionNeededRow(
            title: 'Needs “Display over other apps”',
            subtitle: 'No block screen can appear yet — tap to allow',
            onTap: onGrant,
          ),
      ],
    );
  }
}
