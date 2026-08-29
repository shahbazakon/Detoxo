import 'dart:async';

import 'package:detoxo/app/engine_sync.dart';
import 'package:detoxo/features/blocking/blocklist/presentation/targets_cubit.dart';
import 'package:detoxo/features/blocking/engine/presentation/service_cubit.dart';
import 'package:detoxo/features/blocking/shared/presentation/settings_cubit.dart';
import 'package:detoxo/features/content_counter/content_counter_core/presentation/content_counter_cubit.dart';
import 'package:detoxo/features/limits/limits.dart';
import 'package:detoxo/features/permissions/presentation/permissions_cubit.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Re-syncs Dart ↔ native on every app resume. Before this, every sync ran
/// only on a cold start through the bootstrap — an app kept in recents for days
/// never repaired drift, never re-checked permissions, and showed yesterday's
/// counts after midnight.
///
/// Cheap legs run on every resume (status/permission/counter refresh + a
/// settings re-push); the heavy leg (config push + blocklist syncs, which run
/// a native installed-apps scan) is throttled to once per [heavyLegInterval].
/// Everything is fire-and-forget — a resume must never block the UI.
class AppResumeSync extends StatefulWidget {
  const AppResumeSync({
    required this.child,
    this.heavyLegInterval = const Duration(minutes: 15),
    super.key,
  });

  final Widget child;

  /// Minimum gap between heavy re-syncs (config + blocklists). A parameter
  /// (not a const) so tests can pin the positive path with `Duration.zero`.
  final Duration heavyLegInterval;

  @override
  State<AppResumeSync> createState() => _AppResumeSyncState();
}

class _AppResumeSyncState extends State<AppResumeSync>
    with WidgetsBindingObserver {
  /// Wall-clock of the last heavy leg; seeded at construction because the
  /// bootstrap just ran the same syncs on this cold start.
  DateTime _lastHeavySync = DateTime.now();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // Cheap, idempotent, every resume. Permission refresh keeps the persisted
    // granted-set fresh; the counter refresh is also the day-rollover repair
    // (a dashboard mounted across midnight shows stale numbers otherwise);
    // the status refresh un-sticks the "Protection off" card after a rebind.
    // Every leg is guarded: a flaky resume sync must log, not surface as an
    // uncaught-zone error.
    unawaited(
      guardedSync('permissions', context.read<PermissionsCubit>().refresh()),
    );
    unawaited(guardedSync('service', context.read<ServiceCubit>().refresh()));
    unawaited(
      guardedSync('counter', context.read<ContentCounterCubit>().refresh()),
    );
    unawaited(guardedSync('settings', context.read<SettingsCubit>().resync()));
    // Rules re-resolve on every resume: the 7-day window horizon rolls
    // forward and spent limits reconcile against today's UsageStats.
    unawaited(guardedSync('rules', context.read<RulesCubit>().resync()));
    // M8: re-derive the live grants (a countdown that slept through a doze is
    // stale) and drain any "Allow for a while" tap from the native wall —
    // that tap foregrounds Detoxo, so this resume IS the delivery path when the
    // process was already alive.
    unawaited(
      guardedSync('unblocks', () async {
        final unblock = context.read<UnblockCubit>();
        await unblock.absorbNativeGrants();
        await unblock.resync();
        await unblock.takePending();
      }()),
    );

    final now = DateTime.now();
    if (now.difference(_lastHeavySync) < widget.heavyLegInterval) return;
    _lastHeavySync = now;
    // Heavy leg: re-pushes the detection config (targets.load) and repairs
    // blocklist drift. All fail-safe: a failed load aborts its push.
    unawaited(guardedSync('targets', context.read<TargetsCubit>().load()));
    unawaited(syncEngineBlocklists());
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
