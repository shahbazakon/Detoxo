import 'dart:async';

import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/core/di/injector.dart';
import 'package:detoxo/core/navigation/app_gate.dart';
import 'package:detoxo/core/navigation/app_router.dart';
import 'package:detoxo/features/limits/unblock/domain/entities/temporary_unblock.dart';
import 'package:detoxo/features/limits/unblock/presentation/unblock_cubit.dart';
import 'package:detoxo/features/limits/unblock/presentation/widgets/unblock_duration_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Opens the duration sheet for a target the user tapped "Allow for a while"
/// on, on the native block screen (M8).
///
/// Mounted in `MaterialApp.router`'s `builder`, so it is inside the router (it
/// can read the gate, and it survives every route change) but **above the
/// `Navigator`** — which is why the sheet is pushed through
/// [appNavigatorKey] rather than this widget's own context: a `showModalBottomSheet`
/// on a builder context finds no `Navigator` and throws.
///
/// The tap itself foregrounds Detoxo; the target arrives through
/// `takePendingUnblock`, drained by the bootstrap on a cold start and by
/// `AppResumeSync` when the process was already alive.
class PendingUnblockListener extends StatefulWidget {
  const PendingUnblockListener({required this.child, super.key});

  final Widget child;

  @override
  State<PendingUnblockListener> createState() => _PendingUnblockListenerState();
}

class _PendingUnblockListenerState extends State<PendingUnblockListener> {
  final AppGate _gate = sl<AppGate>();

  @override
  void initState() {
    super.initState();
    // The tap usually lands on a PIN-locked or still-booting launch, because
    // launching Detoxo IS what the tap does. Waiting for the gate rather than
    // dropping the target is the difference between the button working and the
    // button doing nothing at all.
    _gate.addListener(_onGate);
  }

  @override
  void dispose() {
    _gate.removeListener(_onGate);
    super.dispose();
  }

  bool get _ready => _gate.ready && !_gate.pinLocked && _gate.onboarded;

  void _onGate() {
    if (!_ready || !mounted) return;
    final pending = context.read<UnblockCubit>().state.pending;
    if (pending != null) unawaited(_show(pending));
  }

  /// Consumes the target and opens the sheet. Called only once the gate is
  /// open, so backing out of the PIN screen never silently eats a tap.
  Future<void> _show(PendingUnblock pending) async {
    final unblock = context.read<UnblockCubit>()
      // Consume first: backing out of the sheet must not re-open it on the next
      // rebuild, and a second delivery of the same target is a no-op.
      ..clearPending();
    final nav = appNavigatorKey.currentContext;
    if (nav == null) return;
    final label = _label(pending);
    final window = await showUnblockDurationSheet(nav, label: label);
    if (window == null) return;
    final ok = await unblock.grant(
      pending.targetType,
      pending.targetId,
      window,
    );
    // A failure emits `error`, which the listener below turns into its own
    // toast — so this path stays silent rather than claiming success. Before
    // this the bare `return` left the user with nothing at all after they had
    // picked a duration.
    if (!ok) return;
    _toast('$label allowed for ${window.inMinutes} min', AppTone.success);
  }

  /// Toasts through the routed Navigator's context, re-read rather than
  /// captured: the sheet is a real async gap and that Navigator may be gone by
  /// the time it closes. The null check IS the liveness check — this State's
  /// own `mounted` says nothing about whether the Navigator below it exists.
  void _toast(String message, AppTone tone) {
    final at = appNavigatorKey.currentContext;
    if (at == null || !at.mounted) return;
    GlassToast.show(at, message, tone: tone);
  }

  /// The wall names a `platformId`, a package or a host. None of them is a
  /// friendly label, and resolving one would need the installed-apps scan on a
  /// path the user is waiting on — so the copy reads correctly with the raw id.
  static String _label(PendingUnblock p) => switch (p.targetType) {
    UnblockTargetType.reel => 'this feed',
    UnblockTargetType.app => 'this app',
    UnblockTargetType.website => p.targetId,
  };

  @override
  Widget build(BuildContext context) {
    return BlocListener<UnblockCubit, UnblockState>(
      listenWhen: (p, c) =>
          (p.pending != c.pending && c.pending != null) ||
          (p.error != c.error && c.error != null),
      listener: (context, state) {
        // The cubit is app-wide, so its failures are surfaced app-wide from
        // here. Every screen that grants — an App Blocker row, a website row,
        // this sheet — would otherwise need its own listener, and none of them
        // had one: `saveFailed` was emitted and rendered nowhere while the
        // caller cheerfully toasted success.
        final error = state.error;
        if (error != null) _toast(error, AppTone.danger);
        final pending = state.pending;
        // Otherwise it stays in state, and `_onGate` picks it up the moment the
        // gate opens.
        if (pending != null && _ready) unawaited(_show(pending));
      },
      child: widget.child,
    );
  }
}
