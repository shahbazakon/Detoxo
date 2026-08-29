import 'dart:async';

import 'package:detoxo/core/constants/app_constants.dart';
import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/core/di/injector.dart';
import 'package:detoxo/core/navigation/app_gate.dart';
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
import 'package:detoxo/features/limits/limits.dart';
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

  Future<void> _openNudgeThreshold() async {
    await GlassBottomSheet.show<void>(
      context: context,
      title: 'Nudge me every',
      child: const _NudgeThresholdSheet(),
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

  /// Turning suppression on without Android's notification-access grant would
  /// silently do nothing, so the grant is funnelled first — through the same
  /// [requestPermission] entry point as everywhere else, which carries the
  /// prominent disclosure and the restricted-settings recovery.
  ///
  /// A **declined disclosure is a refusal**, and the setting is not committed:
  /// recording the feature as on right after the user read what it does and
  /// said no would be the app overriding an explicit consent decision.
  ///
  /// Proceeding past the disclosure does commit, because the system grant
  /// screen returns no result — the user is still standing on Android's list
  /// when this resolves, so "not granted yet" is not "not wanted". The tile
  /// renders that gap truthfully instead of pretending (see `_SuppressionTile`).
  Future<void> _setSuppressNotifications(
    BuildContext context, {
    required bool enabled,
  }) async {
    final permissions = context.read<PermissionsCubit>();
    if (enabled) {
      final status = permissions.state.firstWhere(
        (s) => s.kind == AppPermission.notificationListener,
        orElse: () =>
            const PermissionStatus(kind: AppPermission.notificationListener),
      );
      if (!permissions.effectivelyGranted(status)) {
        final proceeded = await requestPermission(
          context,
          AppPermission.notificationListener,
        );
        if (!proceeded || !context.mounted) return;
      }
    }
    await context.read<SettingsCubit>().setSuppressNotifications(
      enabled: enabled,
    );
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
    // Slam the router's gate shut BEFORE navigating. This path re-enters the
    // splash without restarting the process, so the gate still holds the flags
    // from before the wipe — leaving them set would wave the user straight
    // through to home and the bootstrap would never run.
    sl<AppGate>().reset();
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

                const _AllowanceTile(),

                _NudgeTile(
                  settings: settings,
                  onChanged: (v) =>
                      context.read<SettingsCubit>().setNudgeEnabled(enabled: v),
                  onTuning: _openNudgeThreshold,
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

                _SuppressionTile(
                  enabled: settings.suppressNotifications,
                  onChanged: (v) =>
                      unawaited(_setSuppressNotifications(context, enabled: v)),
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

/// Notification silence, rendered truthfully (EVO-036).
///
/// The switch has a permission dependency, so "on" and "working" are two
/// different things: the grant can still be pending on Android's own screen, or
/// have been revoked from system settings while the switch stayed on. Showing a
/// plain ON in either case is the app claiming to do something it cannot —
/// the same shape `ContentCount.bubbleBlocked` solves for the counter bubble.
///
/// When the grant is missing the row says so and offers the fix; the permission
/// state refreshes on every resume, so returning from Android's list clears it.
/// Soft nudge: the switch, and — when it is on — the tuning row.
///
/// Like [_SuppressionTile], "on" and "working" are two different things here.
/// The nudge draws its card in a `TYPE_APPLICATION_OVERLAY` window, so without
/// "Display over other apps" `NudgeOverlay.show` returns false and the engine
/// deliberately reports nothing — the switch would read ON while not one card
/// could ever appear. This is the same grant, and the same shape, that
/// `ContentCount.bubbleBlocked` solves for the counter bubble (EVO-022).
/// EVO-053 — how many per-target allowances ("Allow Instagram for 15 minutes")
/// may be spent per day.
///
/// Ships as **Unlimited**, so nothing changes for anyone who does not opt in.
/// It lives here rather than on a blocklist screen because it governs every
/// grant surface at once — a row, the wall, the website list — and because
/// Settings is what the PIN already guards.
class _AllowanceTile extends StatelessWidget {
  const _AllowanceTile();

  static const List<int> _options = [0, 1, 2, 3, 5];

  static String _label(int limit) => limit == 0 ? 'Unlimited' : '$limit a day';

  @override
  Widget build(BuildContext context) {
    final limit = context.select<UnblockCubit, int>(
      (c) => c.state.config.grantLimit,
    );
    return _Spaced(
      FeatureTile(
        icon: Icons.timer_outlined,
        title: 'Allowances',
        subtitle: '${_label(limit)} · "Allow this for a while"',
        onTap: () => _pick(context, limit),
      ),
    );
  }

  Future<void> _pick(BuildContext context, int current) async {
    final cubit = context.read<UnblockCubit>();
    final picked = await GlassBottomSheet.show<int>(
      context: context,
      title: 'Allowances a day',
      child: Builder(
        builder: (sheetContext) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              spacing: AppSpacing.xs,
              children: [
                for (final o in _options)
                  AppChip(
                    label: _label(o),
                    selected: o == current,
                    onSelected: () => Navigator.of(sheetContext).pop(o),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            const InlineHint(
              icon: Icons.info_outline,
              text:
                  'A locked rule already costs an override to lift. This is the '
                  'other half: how often you can free one app, feed or site for '
                  'a few minutes before tomorrow.',
            ),
          ],
        ),
      ),
    );
    if (picked == null || picked == current) return;
    await cubit.setGrantLimit(picked);
  }
}

class _NudgeTile extends StatelessWidget {
  const _NudgeTile({
    required this.settings,
    required this.onChanged,
    required this.onTuning,
  });

  final AppSettings settings;
  final ValueChanged<bool> onChanged;
  final VoidCallback onTuning;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.secondary;
    final enabled = settings.nudgeEnabled;
    return BlocBuilder<PermissionsCubit, List<PermissionStatus>>(
      builder: (context, statuses) {
        final cubit = context.read<PermissionsCubit>();
        final status = statuses.firstWhere(
          (s) => s.kind == AppPermission.overlay,
          orElse: () => const PermissionStatus(kind: AppPermission.overlay),
        );
        // Only a *definite* missing grant is a problem — an unknown read falls
        // back to lastKnownGranted (EVO-014), so a flaky channel call never
        // accuses a working setup of being broken.
        final blocked = enabled && !cubit.effectivelyGranted(status);
        return Column(
          children: [
            _Spaced(
              AppToggleTile(
                leading: Icon(
                  Icons.timer_outlined,
                  color: blocked ? AppColors.warning : accent,
                ),
                title: 'Soft nudge',
                subtitle:
                    'A card that says how long you’ve been in a distracting '
                    'app. Nothing is blocked.',
                value: enabled,
                onChanged: onChanged,
              ),
            ),
            if (blocked)
              _Spaced(
                GlassListTile(
                  leading: const Icon(
                    Icons.error_outline,
                    color: AppColors.warning,
                  ),
                  title: 'Needs “Display over other apps”',
                  subtitle: 'No cards can appear yet — tap to allow',
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => unawaited(
                    requestPermission(context, AppPermission.overlay),
                  ),
                ),
              ),
            if (enabled)
              FeatureTile(
                icon: Icons.tune,
                title: 'Nudge me every',
                subtitle: _nudgeTitle(settings),
                onTap: onTuning,
              ),
          ],
        );
      },
    );
  }
}

class _SuppressionTile extends StatelessWidget {
  const _SuppressionTile({required this.enabled, required this.onChanged});

  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.secondary;
    return BlocBuilder<PermissionsCubit, List<PermissionStatus>>(
      builder: (context, statuses) {
        final cubit = context.read<PermissionsCubit>();
        final status = statuses.firstWhere(
          (s) => s.kind == AppPermission.notificationListener,
          orElse: () =>
              const PermissionStatus(kind: AppPermission.notificationListener),
        );
        // Only a *definite* missing grant is a problem. An unknown read is
        // covered by effectivelyGranted's lastKnownGranted fallback (EVO-014),
        // so a flaky channel call never accuses a working setup of being broken.
        final blocked = enabled && !cubit.effectivelyGranted(status);
        return Column(
          children: [
            _Spaced(
              AppToggleTile(
                leading: Icon(
                  Icons.notifications_off,
                  color: blocked ? AppColors.warning : accent,
                ),
                title: 'Notification silence',
                subtitle: 'Mute apps while they’re blocked',
                value: enabled,
                onChanged: onChanged,
              ),
            ),
            if (blocked)
              _Spaced(
                GlassListTile(
                  leading: const Icon(
                    Icons.error_outline,
                    color: AppColors.warning,
                  ),
                  title: 'Needs “Notification access”',
                  subtitle: 'Nothing is being muted yet — tap to allow',
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => unawaited(
                    requestPermission(
                      context,
                      AppPermission.notificationListener,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
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
  (BlockingMode.pressBack, 'Press back', 'Exits the reel (recommended)'),
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

/// Minutes offered for the soft nudge. Deliberately no value under 5: a card
/// every couple of minutes stops being information and becomes nagging.
/// Both lists sit inside the native clamps (1–60 min, 1–50 cards).
const _nudgeMinutes = <int>[5, 10, 15, 30];
const _nudgeCaps = <int>[2, 4, 6, 10];

String _nudgeTitle(AppSettings s) =>
    '${s.nudgeThresholdMinutes} min · up to ${s.nudgeDailyCap} per app a day';

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
  AppPermission.notificationListener => Icons.notifications_off,
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
        // Required only, via effectivelyGranted — the same predicate the
        // funnel's "N of M" row and Continue button use, so the two can never
        // contradict each other. Counting all of AppPermission.values made
        // "All set" unreachable: it demanded uninstall protection and
        // notification access, both of which ship off by design.
        final cubit = context.read<PermissionsCubit>();
        final required = statuses.where((s) => s.kind.required).toList();
        final granted = required.where(cubit.effectivelyGranted).length;
        final total = required.length;
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
                    trailing:
                        context.read<PermissionsCubit>().effectivelyGranted(s)
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

/// Picks how often the soft nudge speaks, and how many times a day it may.
///
/// The copy is explicit that the threshold is per visit, because "nudge me
/// every 5 minutes" and "nudge me after 30 minutes today" are different
/// features and the second one is the Daily limit, one tile up this screen.
class _NudgeThresholdSheet extends StatelessWidget {
  const _NudgeThresholdSheet();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<SettingsCubit, AppSettings>(
      builder: (context, settings) {
        final cubit = context.read<SettingsCubit>();
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final m in _nudgeMinutes)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                child: _OptionTile(
                  title: '$m minutes',
                  subtitle: 'Counted from opening the app, not across the day',
                  selected: settings.nudgeThresholdMinutes == m,
                  onTap: () {
                    unawaited(cubit.setNudgeThresholdMinutes(m));
                    Navigator.of(context).pop();
                  },
                ),
              ),
            const SizedBox(height: AppSpacing.md),
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.xs),
              child: Text(
                'Most nudges per app, per day',
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
            Wrap(
              spacing: AppSpacing.xs,
              children: [
                for (final cap in _nudgeCaps)
                  AppChip(
                    label: '$cap',
                    // The visible text is a bare number; without this a screen
                    // reader announces "4, selected" with no idea of what.
                    semanticLabel: '$cap nudges per app per day',
                    selected: settings.nudgeDailyCap == cap,
                    onSelected: () {
                      unawaited(cubit.setNudgeDailyCap(cap));
                      Navigator.of(context).pop();
                    },
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}
