import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/core/widgets/common_widgets.dart';
import 'package:detoxo/features/access_protection/domain/entities/pin_config.dart';
import 'package:detoxo/features/access_protection/presentation/pin_cubit.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/enums.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Configure (or turn off) the PIN lock, which sections it guards, and
/// biometric unlock. Custom PINs require a matching confirmation. There is no
/// recovery channel — see `PinHelpSheet`.
class PinSetupScreen extends StatefulWidget {
  const PinSetupScreen({super.key});

  @override
  State<PinSetupScreen> createState() => _PinSetupScreenState();
}

class _PinSetupScreenState extends State<PinSetupScreen> {
  /// The scopes this screen can toggle; any others persisted by an older build
  /// (e.g. the retired `planSwitch` or `appLocker`) are pruned on load so they
  /// aren't re-saved.
  static const _supportedScopes = {PinScope.app, PinScope.settings};

  PinType _type = PinType.custom;
  final _pinController = TextEditingController();
  final _confirmController = TextEditingController();
  final Set<PinScope> _scopes = {..._supportedScopes};
  bool _biometric = false;
  bool _biometricAvailable = false;
  AutoLockTimeout _autoLock = AutoLockTimeout.m1;
  bool _secureScreen = false;

  @override
  void initState() {
    super.initState();
    final config = context.read<PinCubit>().state;
    if (config.isConfigured) {
      _type = config.type;
      _scopes
        ..clear()
        ..addAll(config.scopes.where(_supportedScopes.contains));
      _biometric = config.biometricEnabled;
      _autoLock = config.autoLock;
      _secureScreen = config.secureScreen;
    }
    _loadBiometricAvailability();
  }

  Future<void> _loadBiometricAvailability() async {
    final available = await context.read<PinCubit>().canUseBiometrics();
    if (mounted) setState(() => _biometricAvailable = available);
  }

  @override
  void dispose() {
    _pinController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    // "None" removes the lock entirely (the default state).
    if (_type == PinType.none) {
      await _turnOff();
      return;
    }

    if (_type == PinType.custom) {
      final pin = _pinController.text.trim();
      if (pin.length < 4) {
        GlassToast.show(
          context,
          'Enter a PIN of at least 4 digits.',
          tone: AppTone.danger,
        );
        return;
      }
      if (pin != _confirmController.text.trim()) {
        GlassToast.show(context, "PINs don't match.", tone: AppTone.danger);
        return;
      }
    }
    if (_scopes.isEmpty) {
      GlassToast.show(
        context,
        'Pick at least one thing to protect.',
        tone: AppTone.danger,
      );
      return;
    }

    await context.read<PinCubit>().setup(
      type: _type,
      secret: _pinController.text.trim(),
      scopes: _scopes,
      biometricEnabled: _biometric && _biometricAvailable,
      autoLock: _autoLock,
      secureScreen: _secureScreen,
    );
    if (!mounted) return;
    GlassToast.show(context, 'PIN saved.', tone: AppTone.success);
    Navigator.of(context).pop();
  }

  /// Applies the "None" choice. If a PIN is currently set this confirms before
  /// disabling; if nothing is configured it just closes (no-op).
  Future<void> _turnOff() async {
    final configured = context.read<PinCubit>().state.isConfigured;
    if (!configured) {
      Navigator.of(context).pop();
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
    if (ok && mounted) {
      await context.read<PinCubit>().disable();
      if (!mounted) return;
      GlassToast.show(context, 'PIN lock turned off.');
      Navigator.of(context).pop();
    }
  }

  /// Live preview of a clock-derived PIN — same source of truth as the
  /// matcher, so what we show is always what unlocks.
  String _derivedPreview() => PinCubit.derivedPin(_type, DateTime.now()) ?? '';

  /// Picks the PIN type in a glass bottom sheet (consistent with the Settings
  /// pickers), then applies the choice.
  Future<void> _openPinTypeSheet() async {
    final picked = await GlassBottomSheet.show<PinType>(
      context: context,
      title: 'PIN type',
      child: _PinTypePicker(selected: _type),
    );
    if (picked != null && mounted) setState(() => _type = picked);
  }

  Future<void> _openAutoLockSheet() async {
    final picked = await GlassBottomSheet.show<AutoLockTimeout>(
      context: context,
      title: 'Auto-lock',
      child: _AutoLockPicker(selected: _autoLock),
    );
    if (picked != null && mounted) setState(() => _autoLock = picked);
  }

  @override
  Widget build(BuildContext context) {
    final configured = context.watch<PinCubit>().state.isConfigured;
    final text = Theme.of(context).textTheme;
    final accent = Theme.of(context).colorScheme.secondary;

    return GlassScaffold(
      appBar: const GlassAppBar(title: Text('PIN lock')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          0,
          AppSpacing.md,
          AppSpacing.xxl,
        ),
        children: [
          const SectionHeader('PIN type'),
          FeatureTile(
            icon: Icons.pin_outlined,
            title: 'PIN type',
            subtitle: _pinTypeLabel(_type),
            onTap: _openPinTypeSheet,
          ),
          Text(
            _pinTypeHint(_type),
            style: text.bodySmall?.copyWith(color: context.glass.onGlassMuted),
          ),
          if (_type == PinType.date || _type == PinType.time) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Right now that is "${_derivedPreview()}".',
              style: text.bodySmall?.copyWith(color: accent),
            ),
          ],
          // None removes the lock, so the PIN, scope and biometric
          // sections are hidden — only the type picker and Save remain.
          if (_type != PinType.none) ...[
            if (_type == PinType.custom) ...[
              const SectionHeader('Your PIN'),
              TextField(
                controller: _pinController,
                keyboardType: TextInputType.number,
                obscureText: true,
                maxLength: 10,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'PIN',
                  hintText: 'Enter 4–10 digits',
                ),
              ),
              TextField(
                controller: _confirmController,
                keyboardType: TextInputType.number,
                obscureText: true,
                maxLength: 10,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(labelText: 'Confirm PIN'),
              ),
            ],
            const SectionHeader('Protect'),
            _scopeTile(
              PinScope.app,
              'Opening Detoxo',
              'Ask for the PIN at launch',
            ),
            _scopeTile(
              PinScope.settings,
              'Changing protected settings',
              'Ask before disabling blocking, resetting data or changing the PIN',
            ),
            if (_scopes.contains(PinScope.app)) ...[
              const SectionHeader('Smart auto-lock'),
              FeatureTile(
                icon: Icons.lock_clock_outlined,
                title: 'Re-lock after leaving Detoxo',
                subtitle: _autoLockLabel(_autoLock),
                onTap: _openAutoLockSheet,
              ),
              const SizedBox(height: AppSpacing.xs),
              AppToggleTile(
                leading: Icon(Icons.visibility_off_outlined, color: accent),
                title: 'Hide screen in Recents',
                subtitle: 'Blanks the app preview and blocks screenshots',
                value: _secureScreen,
                onChanged: (v) => setState(() => _secureScreen = v),
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            Text(
              'There is no reset. Your PIN stays on this phone and Detoxo '
              'cannot unlock it for you — if you forget it, the only way back '
              'is to reinstall the app, which clears everything. Pick '
              'something you will remember.',
              style: text.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            if (_biometricAvailable) ...[
              const SectionHeader('Convenience'),
              AppToggleTile(
                leading: Icon(Icons.fingerprint, color: accent),
                title: 'Unlock with fingerprint or device credential',
                subtitle:
                    'Use fingerprint / face, or your device PIN, pattern or '
                    'password',
                value: _biometric,
                onChanged: (v) => setState(() => _biometric = v),
              ),
            ],
          ],
          const SizedBox(height: AppSpacing.xl),
          AnimatedIconButton(
            label: _saveLabel(configured),
            icon: AppIcon.check,
            expand: true,
            onPressed: _save,
          ),
        ],
      ),
    );
  }

  String _saveLabel(bool configured) {
    if (_type == PinType.none) return configured ? 'Turn off PIN lock' : 'Done';
    return 'Save PIN';
  }

  Widget _scopeTile(PinScope scope, String label, String subtitle) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.xs),
    child: AppToggleTile(
      title: label,
      subtitle: subtitle,
      value: _scopes.contains(scope),
      onChanged: (v) => setState(() {
        if (v) {
          _scopes.add(scope);
        } else {
          _scopes.remove(scope);
        }
      }),
    ),
  );
}

/// Human labels & hints for the PIN types, shared by the setup row and the
/// bottom-sheet picker.
String _pinTypeLabel(PinType t) => switch (t) {
  PinType.none => 'None — no lock',
  PinType.custom => 'Custom PIN',
  PinType.date => "Today's date",
  PinType.time => 'Current time',
  _ => 'Unsupported', // wire-compat types; never leak an enum identifier
};

String _pinTypeHint(PinType t) => switch (t) {
  PinType.none => "Detoxo won't ask for a PIN — this is the default.",
  PinType.custom => 'A PIN you choose (4–10 digits).',
  PinType.date => 'Derived from the date (ddMMyyyy) — changes daily.',
  PinType.time => 'Derived from the clock (HHmm) — changes each minute.',
  _ => '',
};

/// Human labels & hints for the auto-lock timeouts, shared by the setup row
/// and the bottom-sheet picker.
String _autoLockLabel(AutoLockTimeout t) => switch (t) {
  AutoLockTimeout.never => 'Never — only on relaunch',
  AutoLockTimeout.immediately => 'Immediately',
  AutoLockTimeout.s15 => 'After 15 seconds',
  AutoLockTimeout.s30 => 'After 30 seconds',
  AutoLockTimeout.m1 => 'After 1 minute',
  AutoLockTimeout.m5 => 'After 5 minutes',
  AutoLockTimeout.screenOff => 'When screen turns off',
};

String _autoLockHint(AutoLockTimeout t) => switch (t) {
  AutoLockTimeout.never => 'Ask again only when Detoxo restarts',
  AutoLockTimeout.immediately => 'Ask every time you leave and come back',
  AutoLockTimeout.screenOff => 'Stay unlocked while the screen stays on',
  _ => 'Ask after this long away from Detoxo',
};

/// Bottom-sheet body: the auto-lock timeouts as radio rows. Pops the chosen
/// [AutoLockTimeout] (or nothing if dismissed).
class _AutoLockPicker extends StatelessWidget {
  const _AutoLockPicker({required this.selected});

  final AutoLockTimeout selected;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final timeout in AutoLockTimeout.values)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.xs),
            child: GlassListTile(
              leading: Icon(
                timeout == selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                color: timeout == selected
                    ? Theme.of(context).colorScheme.secondary
                    : context.glass.onGlassMuted,
              ),
              title: _autoLockLabel(timeout),
              subtitle: _autoLockHint(timeout),
              onTap: () => Navigator.of(context).pop(timeout),
            ),
          ),
      ],
    );
  }
}

/// Bottom-sheet body: the three PIN types as radio rows. Pops the chosen
/// [PinType] (or nothing if dismissed).
class _PinTypePicker extends StatelessWidget {
  const _PinTypePicker({required this.selected});

  final PinType selected;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final type in const [
          PinType.none,
          PinType.custom,
          PinType.date,
          PinType.time,
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.xs),
            child: GlassListTile(
              leading: Icon(
                type == selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                color: type == selected
                    ? Theme.of(context).colorScheme.secondary
                    : context.glass.onGlassMuted,
              ),
              title: _pinTypeLabel(type),
              subtitle: _pinTypeHint(type),
              onTap: () => Navigator.of(context).pop(type),
            ),
          ),
      ],
    );
  }
}
