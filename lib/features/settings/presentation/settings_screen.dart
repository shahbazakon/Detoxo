import 'dart:async';

import 'package:detoxo/core/constants/app_constants.dart';
import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/core/di/injector.dart';
import 'package:detoxo/core/navigation/routes.dart';
import 'package:detoxo/core/storage/local_store.dart';
import 'package:detoxo/core/widgets/common_widgets.dart';
import 'package:detoxo/features/access_protection/domain/entities/pin_config.dart';
import 'package:detoxo/features/access_protection/presentation/pin_cubit.dart';
import 'package:detoxo/features/access_protection/presentation/pin_gate.dart';
import 'package:detoxo/features/additional_feature/app_upgrader/app_upgrader.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/app_settings.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/enums.dart';
import 'package:detoxo/features/blocking/shared/presentation/settings_cubit.dart';
import 'package:detoxo/features/limits/daily_limit/presentation/daily_limit_screen.dart';
import 'package:detoxo/features/permissions/domain/entities/permission_status.dart';
import 'package:detoxo/features/permissions/presentation/permission_actions.dart';
import 'package:detoxo/features/permissions/presentation/permissions_cubit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

/// The app's control hub: protection, feedback, usage, security & permissions,
/// appearance, about and reset — all in the glass design system. Plans, pause
/// and the platform blocklist live on the home screen, not here.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    context.read<PermissionsCubit>().refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The user typically grants permissions from a system screen and returns.
    if (state == AppLifecycleState.resumed && mounted) {
      context.read<PermissionsCubit>().refresh();
    }
  }

  /// Permissions live in a popup so the main screen stays short.
  Future<void> _openPermissions() async {
    await GlassBottomSheet.show<void>(
      context: context,
      title: 'Permissions',
      child: const _PermissionSheet(),
    );
  }

  /// Block-mode and appearance are chosen in popups too, so every choice on this
  /// screen opens the same kind of sheet (consistent with Permissions).
  Future<void> _openBlockMode() async {
    await GlassBottomSheet.show<void>(
      context: context,
      title: 'When a reel is detected',
      child: const _BlockModeSheet(),
    );
  }

  /// Disabling protection is a sensitive change, so it asks for the PIN (when
  /// the `settings` scope guards it); enabling proceeds directly. The switch is
  /// bound to `settings.masterEnabled`, so a cancelled PIN snaps it back.
  Future<void> _setMasterEnabled(
    BuildContext context, {
    required bool enabled,
  }) async {
    if (!enabled) {
      final ok = await requirePin(context, PinScope.settings);
      if (!ok || !context.mounted) return;
    }
    if (!context.mounted) return;
    await context.read<SettingsCubit>().setMasterEnabled(enabled: enabled);
  }

  Future<void> _resetData() async {
    // Reset wipes the PIN itself, so it's a protected change: ask for the PIN
    // first (no-op when none is configured).
    if (!await requirePin(context, PinScope.settings) || !mounted) return;
    final ok = await AppDialog.confirm(
      context: context,
      title: 'Reset app data?',
      message:
          'This wipes your settings, blocklists, limits and PIN, then restarts '
          'onboarding. This cannot be undone.',
      confirmLabel: 'Reset everything',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await sl<LocalStore>().clearAll();
    if (!mounted) return;
    context.go(Routes.splash);
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.secondary;
    // The Settings screen is a separate route (not under HomeShell's
    // UpgradeGate), so it hosts its own UpgradeCubit. It auto-checks on open so
    // the app-version banner can reveal a compact "Update" button when a newer
    // build is available.
    return BlocProvider(
      create: (_) => UpgradeCubit(sl<AppUpgradeService>())..check(),
      child: GlassScaffold(
        appBar: const GlassAppBar(title: Text('Settings')),
        body: BlocBuilder<SettingsCubit, AppSettings>(
          builder: (context, settings) {
            return ListView(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                0,
                AppSpacing.md,
                AppSpacing.xxl,
              ),
              children: [
                // ── Protection: how Detoxo blocks & limits reels ────────────
                const SectionHeader('Protection'),
                FeatureTile(
                  icon: Icons.hourglass_bottom,
                  animatedIcon: AppIcon.dailyLimit,
                  title: 'Daily limit',
                  subtitle: 'Cap your reel time per day',
                  onTap: () => context.push(Routes.dailyLimit),
                ),
                FeatureTile(
                  icon: Icons.touch_app_outlined,
                  title: 'When a reel is detected',
                  subtitle: _blockModeTitle(settings.defaultBlockMode),
                  onTap: _openBlockMode,
                ),
                _Spaced(
                  AppToggleTile(
                    leading: Icon(Icons.shield_outlined, color: accent),
                    title: 'Blocking active',
                    subtitle: 'Master switch for all detection',
                    value: settings.masterEnabled,
                    onChanged: (v) =>
                        unawaited(_setMasterEnabled(context, enabled: v)),
                  ),
                ),

                _Spaced(
                  AppToggleTile(
                    leading: Icon(Icons.vibration, color: accent),
                    title: 'Vibrate on block',
                    subtitle: 'Haptic buzz each time a reel is blocked',
                    value: settings.vibrationEnabled,
                    onChanged: (v) =>
                        context.read<SettingsCubit>().setVibration(enabled: v),
                  ),
                ),

                // ── Privacy: apps Detoxo must never touch ───────────────────
                const SectionHeader('Privacy'),
                FeatureTile(
                  icon: Icons.privacy_tip_outlined,
                  title: 'Protected apps',
                  subtitle:
                      'Banking & sensitive apps Detoxo completely ignores',
                  onTap: () => context.push(Routes.protectedApps),
                ),

                // ── Security: who can change things & system access ─────────
                const SectionHeader('Security'),
                _PinTile(),
                _PermissionsTile(onTap: _openPermissions),

                // ── General: appearance & app info ──────────────────────────
                const SectionHeader('General'),
                FeatureTile(
                  icon: _themeIcon(settings.themeMode),
                  title: 'Appearance',
                  subtitle: 'Theme, background & reel counter',
                  onTap: () => context.push(Routes.appearance),
                ),
                _Spaced(
                  AppToggleTile(
                    leading: Icon(Icons.feedback_outlined, color: accent),
                    title: 'Feedback button',
                    subtitle: 'Show a feedback button in every top bar',
                    value: settings.showFeedbackButton,
                    onChanged: (v) => context
                        .read<SettingsCubit>()
                        .setShowFeedbackButton(enabled: v),
                  ),
                ),
                const _VersionBanner(),

                // ── Reset ───────────────────────────────────────────────────
                const SizedBox(height: AppSpacing.lg),
                Center(
                  child: GhostButton(
                    label: 'Reset app data',
                    onPressed: _resetData,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Adds the standard inter-row gap below rows that don't bake it in themselves
/// ([FeatureTile] already includes a bottom gap), keeping list rhythm even.
class _Spaced extends StatelessWidget {
  const _Spaced(this.child);
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
    child: child,
  );
}

// ── App-version banner + update check ─────────────────────────────────────────

/// The app-version [InfoBanner], which doubles as the "check for updates"
/// surface. Tapping it runs a manual check (toasting when already current); when
/// a newer build is available it reveals a compact [_UpdateButton] that opens the
/// store. Backed by the screen-local `UpgradeCubit` (see `build`).
class _VersionBanner extends StatelessWidget {
  const _VersionBanner();

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<UpgradeCubit, UpgradeState>(
      listenWhen: (prev, next) => prev.view != next.view,
      listener: (context, state) {
        // Confirm "up to date" only for a user-initiated tap, not the auto-check.
        if (state.view == UpgradeView.upToDate && state.manual) {
          GlassToast.show(context, "You're on the latest version");
        }
      },
      builder: (context, state) {
        final update = state.view == UpgradeView.updateAvailable
            ? state.status
            : null;
        final version = update?.storeVersion;
        return InfoBanner(
          title: '${AppConstants.appName} v${AppConstants.appVersion}',
          text: update == null
              ? 'Take back control of your time and focus'
              : version != null
              ? 'Version $version is available.'
              : 'A new version is available.',
          onTap: () => context.read<UpgradeCubit>().check(manual: true),
          trailing: update == null
              ? null
              : _UpdateButton(
                  onPressed: () => context.read<UpgradeCubit>().openStore(),
                ),
        );
      },
    );
  }
}

/// A compact filled "Update" pill for the version banner.
class _UpdateButton extends StatelessWidget {
  const _UpdateButton({required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.seed,
        foregroundColor: Colors.white,
        minimumSize: Size.zero,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.xs,
        ),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: const StadiumBorder(),
        textStyle: Theme.of(context).textTheme.labelLarge,
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.system_update, size: 16),
          SizedBox(width: 6),
          Text('Update'),
        ],
      ),
    );
  }
}

// ── Block-mode + appearance option data ───────────────────────────────────────

const _blockModes = <(BlockingMode, String, String)>[
  (BlockingMode.pressBack, 'Press back', 'Gently exits the reel (recommended)'),
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

String _blockModeTitle(BlockingMode m) => _blockModes
    .firstWhere((e) => e.$1 == m, orElse: () => _blockModes.first)
    .$2;

IconData _themeIcon(AppThemeMode m) => switch (m) {
  AppThemeMode.system => Icons.brightness_auto,
  AppThemeMode.light => Icons.light_mode,
  AppThemeMode.dark => Icons.dark_mode,
};

// ── Selectable option row (used in pickers) ───────────────────────────────────

class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
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
      onTap: onTap,
    );
  }
}

// ── PIN lock: master switch + edit tile ───────────────────────────────────────

class _PinTile extends StatelessWidget {
  /// Master switch. Turning ON opens setup; turning OFF asks for the PIN and a
  /// confirmation, then disables. The switch is bound to `isConfigured`, so a
  /// cancelled turn-off (or a setup the user backs out of) snaps it back.
  Future<void> _toggle(BuildContext context, {required bool enable}) async {
    if (enable) {
      await context.push(Routes.pinSetup);
      return;
    }
    if (!await requirePin(context, PinScope.settings) || !context.mounted) {
      return;
    }
    final ok = await AppDialog.confirm(
      context: context,
      title: 'Turn off PIN lock?',
      message:
          'Detoxo and its protected sections will no longer ask for a PIN.',
      confirmLabel: 'Turn off',
      cancelLabel: 'Keep it on',
      destructive: true,
    );
    if (!ok || !context.mounted) return;
    await context.read<PinCubit>().disable();
  }

  /// Edit the configured PIN (type, auto-lock, biometrics). The `/pin/setup`
  /// route itself is wrapped in `PinGuard(scope: settings)`, so no gate here.
  Future<void> _openSettings(BuildContext context) async {
    await context.push(Routes.pinSetup);
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PinCubit, PinConfig>(
      builder: (context, config) {
        final on = config.isConfigured;
        final typeLabel = switch (config.type) {
          PinType.custom => 'Custom',
          PinType.date => 'Date',
          PinType.time => 'Time',
          _ => 'Unknown', // wire-compat types; never render a dangling bullet
        };
        return Column(
          children: [
            _Spaced(
              AppToggleTile(
                leading: Icon(
                  Icons.lock_outline,
                  color: Theme.of(context).colorScheme.secondary,
                ),
                title: 'PIN lock',
                subtitle: on
                    ? 'On • $typeLabel PIN'
                    : 'Off — protect Detoxo with a PIN',
                value: on,
                onChanged: (v) => unawaited(_toggle(context, enable: v)),
              ),
            ),
            if (on)
              FeatureTile(
                icon: Icons.tune,
                animatedIcon: AppIcon.pinLock,
                title: 'PIN settings',
                subtitle: 'Type, auto-lock & biometrics',
                onTap: () => _openSettings(context),
              ),
          ],
        );
      },
    );
  }
}

// ── Permissions: entry tile + popup ───────────────────────────────────────────

IconData _permissionIcon(AppPermission p) => switch (p) {
  AppPermission.accessibility => Icons.accessibility_new,
  AppPermission.overlay => Icons.layers,
  AppPermission.notifications => Icons.notifications,
  AppPermission.usageAccess => Icons.bar_chart,
  AppPermission.batteryOptimization => Icons.battery_charging_full,
  AppPermission.deviceAdmin => Icons.shield,
};

/// Main-screen entry: a single tile summarising permission status; opens the
/// full list in a popup.
class _PermissionsTile extends StatelessWidget {
  const _PermissionsTile({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PermissionsCubit, List<PermissionStatus>>(
      builder: (context, statuses) {
        final granted = statuses.where((s) => s.granted).length;
        final total = statuses.length;
        final allOk = total > 0 && granted == total;
        return FeatureTile(
          icon: Icons.verified_user_outlined,
          animatedIcon: AppIcon.shieldCheck,
          title: 'Permissions',
          subtitle: 'Accessibility, overlay, notifications & more',
          trailing: total == 0
              ? const Icon(Icons.chevron_right)
              : Pill(
                  label: allOk ? 'All set' : '$granted/$total',
                  tone: allOk ? AppTone.success : AppTone.warning,
                ),
          onTap: onTap,
        );
      },
    );
  }
}

/// Popup body: the full permission list with grant actions. Updates live as the
/// user grants from system screens and returns.
class _PermissionSheet extends StatelessWidget {
  const _PermissionSheet();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PermissionsCubit, List<PermissionStatus>>(
      builder: (context, statuses) {
        if (statuses.isEmpty) {
          return const Text('No permissions to manage.');
        }
        return SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final s in statuses)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                  child: GlassListTile(
                    leading: Icon(
                      _permissionIcon(s.kind),
                      color: Theme.of(context).colorScheme.secondary,
                    ),
                    title: s.kind.label,
                    subtitle: s.kind.why,
                    trailing: s.granted
                        ? const Pill(
                            label: 'Granted',
                            tone: AppTone.success,
                            icon: Icons.check,
                          )
                        : TextButton(
                            onPressed: () => requestPermission(context, s.kind),
                            child: Text(
                              s.blockedByRestrictedSettings
                                  ? 'Fix'
                                  : (s.kind.required ? 'Grant' : 'Enable'),
                            ),
                          ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

// ── Block-mode picker (popup) ───────────────────────────────────────────────────

class _BlockModeSheet extends StatelessWidget {
  const _BlockModeSheet();

  /// Applies [mode] and closes the sheet. "Lock app" gates the reel behind the
  /// user's PIN, so picking it without a PIN configured can't enforce anything —
  /// we send the user to PIN setup instead of silently selecting a dead mode.
  Future<void> _select(BuildContext context, BlockingMode mode) async {
    final needsPin =
        mode == BlockingMode.lockApp &&
        !context.read<PinCubit>().state.isConfigured;
    if (needsPin) {
      final router = GoRouter.of(context);
      final navigator = Navigator.of(context);
      final setUp = await AppDialog.confirm(
        context: context,
        title: 'Set a PIN first',
        message:
            'Lock app hides the reel behind your PIN, like an app locker. '
            'Set up a PIN to use this mode.',
        confirmLabel: 'Set up PIN',
      );
      if (!setUp) return;
      navigator.pop(); // close the sheet before leaving the screen
      unawaited(router.push(Routes.pinSetup));
      return;
    }
    unawaited(context.read<SettingsCubit>().setDefaultBlockMode(mode));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<SettingsCubit, AppSettings>(
      builder: (context, settings) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final e in _blockModes)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                child: _OptionTile(
                  title: e.$2,
                  subtitle: e.$3,
                  selected: settings.defaultBlockMode == e.$1,
                  onTap: () => unawaited(_select(context, e.$1)),
                ),
              ),
          ],
        );
      },
    );
  }
}
