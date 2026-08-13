import 'package:detoxo/features/access_protection/presentation/pin_cubit.dart';
import 'package:detoxo/features/access_protection/presentation/pin_lock_screen.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/enums.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Demands the PIN for [scope] before continuing. Returns `true` immediately
/// when no PIN guards the scope; otherwise pushes a full-screen [PinLockScreen]
/// and resolves to whether the user unlocked (vs. cancelled).
///
/// Use at the trigger of a protected action:
/// ```dart
/// if (await requirePin(context, PinScope.settings)) {
///   // proceed
/// }
/// ```
Future<bool> requirePin(BuildContext context, PinScope scope) async {
  final config = context.read<PinCubit>().state;
  if (!config.isConfigured || !config.guards(scope)) return true;

  final ok = await Navigator.of(context, rootNavigator: true).push<bool>(
    MaterialPageRoute<bool>(
      fullscreenDialog: true,
      builder: (ctx) => PinLockScreen(
        scope: scope,
        onUnlocked: () => Navigator.of(ctx).pop(true),
        onCancel: () => Navigator.of(ctx).pop(false),
      ),
    ),
  );
  return ok ?? false;
}

/// Wraps a screen so it is revealed only after the PIN for [scope] is entered.
/// When the scope isn't guarded the [child] shows immediately; otherwise the
/// lock screen is shown inline and cancelling pops back out of the route.
class PinGuard extends StatefulWidget {
  const PinGuard({required this.scope, required this.child, super.key});

  final PinScope scope;
  final Widget child;

  @override
  State<PinGuard> createState() => _PinGuardState();
}

class _PinGuardState extends State<PinGuard> {
  late bool _unlocked;

  @override
  void initState() {
    super.initState();
    final config = context.read<PinCubit>().state;
    _unlocked = !config.isConfigured || !config.guards(widget.scope);
  }

  @override
  Widget build(BuildContext context) {
    if (_unlocked) return widget.child;
    return PinLockScreen(
      scope: widget.scope,
      onUnlocked: () => setState(() => _unlocked = true),
      onCancel: () => Navigator.of(context).maybePop(),
    );
  }
}
