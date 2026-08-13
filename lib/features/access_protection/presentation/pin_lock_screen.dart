import 'dart:async';

import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/core/navigation/routes.dart';
import 'package:detoxo/core/widgets/common_widgets.dart';
import 'package:detoxo/features/access_protection/presentation/pin_cubit.dart';
import 'package:detoxo/features/access_protection/presentation/pin_help_sheet.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/enums.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

/// Full-screen PIN gate. Serves three roles via its callbacks:
/// * **Launch gate** (routed via `/pin/lock`): the router supplies an
///   [onUnlocked] that resumes the splash's gating order (permissions →
///   home); a null [onUnlocked] falls back to navigating home directly.
/// * **Inline guard** (see `PinGuard`): calls [onUnlocked] to reveal the screen.
/// * **Action gate** (see `requirePin`): pushed as a route; [onUnlocked] /
///   [onCancel] pop a result.
///
/// The system back gesture never dismisses it; a close affordance is shown only
/// when [onCancel] is provided.
class PinLockScreen extends StatefulWidget {
  const PinLockScreen({
    super.key,
    this.scope = PinScope.app,
    this.onUnlocked,
    this.onCancel,
  });

  /// Which protected scope is being unlocked (drives the heading).
  final PinScope scope;

  /// Called on a correct PIN / biometric unlock. When null this is the launch
  /// gate and the screen navigates to home itself.
  final VoidCallback? onUnlocked;

  /// Called when the user backs out of an optional (in-app) gate. When null no
  /// cancel affordance is shown (forced gate).
  final VoidCallback? onCancel;

  /// Whether a *forced* app-scope gate (launch gate or auto-relock — the
  /// non-cancellable ones) is currently on screen. `PinAutoRelock` consults
  /// this so a background/resume cycle at the lock never stacks a second lock.
  static bool get appGateVisible => _appGateCount > 0;
  static int _appGateCount = 0;

  @override
  State<PinLockScreen> createState() => _PinLockScreenState();
}

class _PinLockScreenState extends State<PinLockScreen> {
  /// Entry buffer + error line as notifiers, so a keystroke repaints only the
  /// dots and the status row — never all twelve (blur-heavy) keys.
  final ValueNotifier<String> _entry = ValueNotifier('');
  final ValueNotifier<String?> _error = ValueNotifier(null);
  Timer? _lockTimer;

  /// The lockout window we've already surfaced as a dialog, so the 1 Hz rebuild
  /// (and repeated keypad pokes) can't re-fire it. Re-shows when the window changes.
  DateTime? _shownFor;
  final AnimatedIconController _lockController = AnimatedIconController();
  final AnimatedIconController _backspaceController = AnimatedIconController();

  bool get _reduceMotion =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  bool get _isForcedAppGate =>
      widget.scope == PinScope.app && widget.onCancel == null;

  @override
  void initState() {
    super.initState();
    if (_isForcedAppGate) PinLockScreen._appGateCount++;
    final config = context.read<PinCubit>().state;
    if (config.biometricEnabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _tryBiometric());
    }
  }

  @override
  void dispose() {
    if (_isForcedAppGate) PinLockScreen._appGateCount--;
    _lockTimer?.cancel();
    _entry.dispose();
    _error.dispose();
    _lockController.dispose();
    _backspaceController.dispose();
    super.dispose();
  }

  /// Schedules exactly one rebuild for the moment the lockout window ends, so
  /// the keypad re-enables itself. The ticking countdown lives inside
  /// [_LockoutText] — a periodic tick here would rebuild the whole screen at
  /// 1 Hz for windows that can last 24 h.
  void _syncLockTimer(DateTime? lockedUntil) {
    if (lockedUntil != null) {
      final wait = lockedUntil.difference(DateTime.now());
      _lockTimer ??= Timer(wait.isNegative ? Duration.zero : wait, () {
        _lockTimer = null;
        if (mounted) setState(() {});
      });
    } else {
      _lockTimer?.cancel();
      _lockTimer = null;
    }
  }

  void _succeed() {
    AppHaptics.success();
    if (widget.onUnlocked != null) {
      widget.onUnlocked!();
    } else {
      context.go(Routes.home);
    }
  }

  Future<void> _tryBiometric() async {
    final ok = await context.read<PinCubit>().authenticateBiometric();
    if (!ok || !mounted) return;
    // A success arriving while another route sits on top (e.g. the auto-relock
    // pushed over a settings gate during the credential prompt) must not fire
    // this gate's callback — it would pop the wrong route, unlocking nothing
    // the user actually authenticated for.
    if (ModalRoute.of(context)?.isCurrent ?? true) _succeed();
  }

  Future<void> _onKey(String digit) async {
    final cubit = context.read<PinCubit>();
    final config = cubit.state;
    if (config.isLockedOut) {
      _showLockoutDialog(config.lockedUntil!);
      return;
    }
    final expected = cubit.expectedLength;
    if (_entry.value.length >= expected) return;
    AppHaptics.selection();
    _entry.value += digit;
    _error.value = null;
    if (_entry.value.length >= expected) await _attempt();
  }

  Future<void> _attempt() async {
    final cubit = context.read<PinCubit>();
    final ok = await cubit.verify(_entry.value);
    if (!mounted) return;
    if (ok) {
      _succeed();
      return;
    }
    _wrongPinFeedback();
    _error.value = 'Incorrect PIN';
    _entry.value = '';
    // verify() has emitted; read the fresh state to catch a new lockout window.
    final config = cubit.state;
    if (config.isLockedOut) _showLockoutDialog(config.lockedUntil!);
  }

  /// A wrong PIN gets a distinct stronger buzz (gated on the haptics setting)
  /// plus the existing shake.
  void _wrongPinFeedback() {
    AppHaptics.error();
    if (!_reduceMotion) _lockController.animate();
  }

  /// Surfaces the cooldown as a glass dialog, once per distinct lockout window —
  /// the inline [_LockoutText] remains the live, ticking countdown.
  void _showLockoutDialog(DateTime until) {
    if (_shownFor == until) return;
    _shownFor = until;
    final diff = until.difference(DateTime.now());
    final remaining = diff.isNegative ? Duration.zero : diff;
    AppDialog.show<void>(
      context: context,
      title: 'Too many attempts',
      message: 'Please wait ${formatCountdown(remaining)} before trying again.',
      icon: Icons.lock_clock,
      accent: AppColors.danger,
      actions: [
        PrimaryButton(
          label: 'OK',
          tint: AppColors.danger,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }

  void _backspace() {
    if (_entry.value.isEmpty) return;
    if (!_reduceMotion) {
      _backspaceController
        ..reset()
        ..animate();
    }
    _entry.value = _entry.value.substring(0, _entry.value.length - 1);
  }

  Future<void> _forgotPin() async {
    await PinHelpSheet.show(context);
  }

  /// Title, supporting line and glyph for the active scope.
  ({String title, String subtitle, AppIcon icon}) get _copy =>
      switch (widget.scope) {
        PinScope.app => (
          title: 'Enter your PIN',
          subtitle: 'Unlock Detoxo to continue',
          icon: AppIcon.pinLock,
        ),
        PinScope.settings => (
          title: 'Enter PIN',
          subtitle: 'Confirm to change protected settings',
          icon: AppIcon.shieldCheck,
        ),
        PinScope.appLocker => (
          title: 'Enter PIN',
          subtitle: 'Confirm to manage locked apps',
          icon: AppIcon.shieldCheck,
        ),
        PinScope.planSwitch || PinScope.detoxoSettings => (
          title: 'Enter your PIN',
          subtitle: 'Confirm to continue',
          icon: AppIcon.pinLock,
        ),
      };

  @override
  Widget build(BuildContext context) {
    final config = context.watch<PinCubit>().state;
    final text = Theme.of(context).textTheme;
    final expected = context.read<PinCubit>().expectedLength;
    final copy = _copy;
    // One clock read per build: isLockedOut re-reads DateTime.now() on every
    // call, and consulting it thrice could disagree within a single frame.
    final locked = config.isLockedOut;
    _syncLockTimer(locked ? config.lockedUntil : null);

    return PopScope(
      canPop: false,
      child: GlassScaffold(
        body: Stack(
          children: [
            // The scroll view fills the body, so anything meant to be tappable
            // must come AFTER it in the stack — a Stack hit-tests top-down and
            // the scrollable swallows pointers for its whole viewport. With the
            // ✕ underneath, Cancel was unreachable by touch.
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.xl,
                  vertical: AppSpacing.xxl,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AppAnimatedIcon(
                      icon: copy.icon,
                      size: 52,
                      controller: _lockController,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Text(
                      copy.title,
                      textAlign: TextAlign.center,
                      style: text.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      copy.subtitle,
                      textAlign: TextAlign.center,
                      style: text.bodyMedium?.copyWith(
                        color: context.glass.onGlassMuted,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    ValueListenableBuilder<String>(
                      valueListenable: _entry,
                      builder: (_, entry, _) =>
                          _Dots(length: expected, filled: entry.length),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    // Min-height, not fixed: the lockout line wraps at large
                    // text scales and must grow instead of painting over the
                    // keypad below.
                    ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 24),
                      child: Center(
                        child: locked
                            ? _LockoutText(until: config.lockedUntil!)
                            : ValueListenableBuilder<String?>(
                                valueListenable: _error,
                                builder: (_, error, _) => Text(
                                  error ?? '',
                                  textAlign: TextAlign.center,
                                  style: text.bodyMedium?.copyWith(
                                    color: Theme.of(context).colorScheme.error,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    _Keypad(
                      enabled: !locked,
                      showBiometric: config.biometricEnabled,
                      onKey: _onKey,
                      onBackspace: _backspace,
                      onBiometric: _tryBiometric,
                      backspaceController: _backspaceController,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    GhostButton(label: 'Forgot PIN?', onPressed: _forgotPin),
                  ],
                ),
              ),
            ),
            if (widget.onCancel != null)
              SafeArea(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: IconButton(
                    tooltip: 'Cancel',
                    icon: const Icon(Icons.close),
                    onPressed: widget.onCancel,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Fixed-length progress dots (one per expected digit), filled as you type.
class _Dots extends StatelessWidget {
  const _Dots({required this.length, required this.filled});
  final int length;
  final int filled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Semantics(
      label: '$filled of $length digits entered',
      child: ExcludeSemantics(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(
            length.clamp(1, 10),
            (i) => AnimatedContainer(
              duration: reduceMotion ? Duration.zero : AppDurations.fast,
              margin: const EdgeInsets.symmetric(horizontal: 6),
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                color: i < filled ? scheme.primary : Colors.transparent,
                border: Border.all(
                  color: i < filled ? scheme.primary : context.glass.border,
                  width: 1.5,
                ),
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Live "try again in…" countdown. Owns its own 1 Hz tick so the rest of the
/// screen isn't rebuilt every second for windows that can last 24 h; the
/// parent's one-shot timer handles re-enabling the keypad at expiry.
class _LockoutText extends StatefulWidget {
  const _LockoutText({required this.until});
  final DateTime until;

  @override
  State<_LockoutText> createState() => _LockoutTextState();
}

class _LockoutTextState extends State<_LockoutText> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final diff = widget.until.difference(DateTime.now());
    final remaining = diff.isNegative ? Duration.zero : diff;
    return Text(
      'Too many attempts. Try again in ${formatCountdown(remaining)}',
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
        color: Theme.of(context).colorScheme.error,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

class _Keypad extends StatelessWidget {
  const _Keypad({
    required this.enabled,
    required this.showBiometric,
    required this.onKey,
    required this.onBackspace,
    required this.onBiometric,
    required this.backspaceController,
  });

  final bool enabled;
  final bool showBiometric;
  final ValueChanged<String> onKey;
  final VoidCallback onBackspace;
  final VoidCallback onBiometric;
  final AnimatedIconController backspaceController;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 300,
      child: GridView.count(
        crossAxisCount: 3,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: AppSpacing.sm,
        crossAxisSpacing: AppSpacing.sm,
        childAspectRatio: 1.3,
        children: [
          for (var i = 1; i <= 9; i++)
            _DigitKey(digit: '$i', enabled: enabled, onKey: onKey),
          // Bottom-left: biometric shortcut when enabled, else empty.
          if (showBiometric)
            _IconKey(
              enabled: enabled,
              onTap: onBiometric,
              semanticLabel: 'Unlock with fingerprint or device credential',
              child: const Icon(Icons.fingerprint, size: 26),
            )
          else
            const SizedBox.shrink(),
          _DigitKey(digit: '0', enabled: enabled, onKey: onKey),
          _IconKey(
            enabled: enabled,
            onTap: onBackspace,
            semanticLabel: 'Delete',
            child: AppAnimatedIcon(
              icon: AppIcon.backspace,
              size: 24,
              controller: backspaceController,
            ),
          ),
        ],
      ),
    );
  }
}

class _DigitKey extends StatelessWidget {
  const _DigitKey({
    required this.digit,
    required this.enabled,
    required this.onKey,
  });

  final String digit;
  final bool enabled;
  final ValueChanged<String> onKey;

  @override
  Widget build(BuildContext context) {
    final key = GlassContainer(
      // No BackdropFilter: ten simultaneous blurs over the drifting ambient
      // background would re-blur every frame (see GlassContainer's own doc);
      // the sibling _IconKey already opts out.
      enableBlur: false,
      borderRadius: AppRadius.pill,
      padding: EdgeInsets.zero,
      child: Center(
        child: Text(
          digit,
          style: Theme.of(
            context,
          ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
    );
    return Semantics(
      button: true,
      enabled: enabled,
      label: digit,
      excludeSemantics: true,
      child: enabled
          ? AppPressable(haptic: false, onTap: () => onKey(digit), child: key)
          : Opacity(opacity: 0.4, child: key),
    );
  }
}

class _IconKey extends StatelessWidget {
  const _IconKey({
    required this.enabled,
    required this.onTap,
    required this.child,
    required this.semanticLabel,
  });

  final bool enabled;
  final VoidCallback onTap;
  final Widget child;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final key = GlassContainer(
      enableBlur: false,
      borderRadius: AppRadius.pill,
      borderColor: Colors.transparent,
      tintTop: Colors.transparent,
      tintBottom: Colors.transparent,
      padding: EdgeInsets.zero,
      child: Center(child: child),
    );
    return Semantics(
      button: true,
      enabled: enabled,
      label: semanticLabel,
      excludeSemantics: true,
      child: enabled
          ? AppPressable(onTap: onTap, child: key)
          : Opacity(opacity: 0.4, child: key),
    );
  }
}
