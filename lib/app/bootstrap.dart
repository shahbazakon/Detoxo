import 'dart:async';

import 'package:detoxo/app/engine_sync.dart';
import 'package:detoxo/core/di/injector.dart';
import 'package:detoxo/core/navigation/app_gate.dart';
import 'package:detoxo/core/platform/platform_capabilities.dart';
import 'package:detoxo/core/storage/local_store.dart';
import 'package:detoxo/core/utils/app_logger.dart';
import 'package:detoxo/features/access_protection/presentation/pin_cubit.dart';
import 'package:detoxo/features/blocking/blocking.dart';
import 'package:detoxo/features/content_counter/content_counter.dart';
import 'package:detoxo/features/limits/limits.dart';
import 'package:detoxo/features/permissions/presentation/permissions_cubit.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// One named unit of app-start work.
///
/// ponytail: a record and a list, not an `AppInitializer` interface with an
/// `order` int and a file each. The order IS the list order, adding a step is
/// still a one-line edit, and `guardedSync` already provides the "log it and
/// carry on" contract an interface would have had to redeclare.
typedef BootStep = (String name, Future<void> Function() run);

/// Hydrates the app's state, repairs native drift, then opens the router's gate.
///
/// Split into three phases on purpose:
///
/// * **Blocking** — only what the gate decision reads. Everything else would be
///   latency the user watches on the splash for no reason.
/// * **First run** — ordered, and genuinely sequential: the platform seed needs
///   the installed-package scan to have finished.
/// * **Background** — fired and forgotten, because nothing routes on it.
///
/// Every step is individually guarded: one failing leg must never stop app
/// start. Before this existed, a throw anywhere in the splash's inline sequence
/// left the user on a spinner forever.
Future<void> runBootstrap(BuildContext context) async {
  final settings = context.read<SettingsCubit>();
  final targets = context.read<TargetsCubit>();
  final permissions = context.read<PermissionsCubit>();
  final pin = context.read<PinCubit>();
  // The app-wide cubits that only `..load()` once in main.dart. Every path that
  // wipes the store (Settings → Reset app data) comes back through here WITHOUT
  // restarting the process, so their state would otherwise survive the wipe and
  // the next save would write it back.
  final rules = context.read<RulesCubit>();
  final dailyLimit = context.read<DailyLimitCubit>();
  final streak = context.read<StreakCubit>();
  final unblock = context.read<UnblockCubit>();
  final gate = sl<AppGate>();

  try {
    // Phase 1 — the gate decision's inputs. Parallel: they share nothing.
    await Future.wait([
      guardedSync('settings', settings.bootstrap()),
      guardedSync('permissions', permissions.refresh()),
      guardedSync('pin', pin.load()),
    ]);

    // Captured BEFORE the seed. `SettingsCubit._commit` emits synchronously, so
    // reading this predicate again after `_seedPlatforms` would report a
    // non-empty set and run the slow leg a second time on the one launch that
    // can least afford it. The two phases are mutually exclusive by definition.
    final firstRun = settings.state.enabledPlatformIds.isEmpty;

    // Phase 2 — first run only, and strictly ordered. Seed the enabled set from
    // each installed target's default status: don't pre-enable apps the user
    // does not have. `targets.load()` is the slow leg (native config push +
    // installed-package scan), so on every later launch it moves to phase 3.
    if (firstRun) {
      await guardedSync('seedPlatforms', _seedPlatforms(targets, settings));
    }

    // Open the gate BEFORE the background work: the router only reads phases
    // 1–2, and making the user wait on drift repair they cannot see is the
    // latency the old splash had.
    gate.update(
      ready: true,
      supported: !PlatformCapabilities.isBlockingPreviewOnly,
      onboarded: settings.state.onboarded,
      pinLocked: pin.state.isConfigured && pin.state.guards(PinScope.app),
      permissionsOk: permissions.allRequiredGranted,
    );

    // Phase 3 — drift repair and rehydration. Nothing routes on any of it.
    for (final (name, run) in <BootStep>[
      // Re-render a pinned home-screen widget from the native store
      // (day-rollover repair for a widget that saw no count since midnight).
      ('contentWidget', sl<HomeWidgetRepository>().refresh),
      // Protected apps, web blocklist and whole-app blocks, pushed so native
      // matches Dart without any screen ever being opened.
      ('engineBlocklists', syncEngineBlocklists),
      // These three are loaded HERE and nowhere else. `main.dart` used to also
      // `..load()` them at provider construction, which ran every one of them
      // twice on every cold start — and `RulesCubit.load()` ends in a resync,
      // so that was two UsageStats reads and two native snapshot pushes.
      // M8, and ORDERED relative to `rules` only by accident of this list: the
      // migration must land before the unblock cubit's first push, so it runs
      // inside the same step. A pause that was running when the user upgraded
      // becomes a WEBSITE grant; everyone else pays one string read.
      (
        'unblocks',
        () async {
          await migrateWebPauses(
            sl<LocalStore>(),
            sl<TemporaryUnblockRepository>(),
          );
          // The Dart block-event buffer is gone (doc 12 §1.1) and nothing reads
          // its document, but an upgraded install still decodes it into RAM on
          // every cold start (the box is not lazy). Deleting a missing key is a
          // no-op, so this costs a fresh install nothing.
          await sl<LocalStore>().delete('analytics_events');
          await unblock.load();
          // The wall's "Allow for a while" foregrounds Detoxo, and on a cold
          // start the EventChannel sink does not exist when the action fires —
          // so this read, not the event, is what delivers the target.
          // EVO-050 first: a grant taken on the wall is already enforced
          // natively, and the push `load()` just made would delete it.
          await unblock.absorbNativeGrants();
          await unblock.takePending();
        },
      ),
      ('rules', rules.load),
      ('dailyLimit', dailyLimit.load),
      ('streak', streak.load),
      if (!firstRun) ('targets', targets.load),
    ]) {
      unawaited(guardedSync(name, run()));
    }
  } on Object catch (e, s) {
    // The per-step guards cover phases 1–3; this covers the prologue and the
    // `gate.update` argument list, which are NOT inside them.
    AppLogger.e('bootstrap failed', e, s);
  } finally {
    // Never strand the user on the splash. Whatever failed, the gate opens —
    // `ready: false` pins every location to `/`, and the splash does not
    // re-run its post-frame callback, so the spinner would be forever.
    //
    // `onboarded` comes from the repository rather than the cubit, because the
    // cubit is what may have failed: opening the gate with a default `false`
    // would walk an already-onboarded user back through the whole first run,
    // which is a worse outcome than the failure it is recovering from.
    if (!gate.ready) {
      gate.update(ready: true, onboarded: await _onboardedFallback());
    }
  }
}

/// Best-effort read of the completion flag for the failure path above.
/// `SettingsRepositoryImpl.load` already falls back to defaults on a corrupt
/// blob, so this only has to survive the repository being unreachable at all.
Future<bool> _onboardedFallback() async {
  try {
    return (await sl<SettingsRepository>().load()).onboarded;
  } on Object catch (e) {
    AppLogger.e('bootstrap could not read the onboarded flag', e);
    return false;
  }
}

Future<void> _seedPlatforms(
  TargetsCubit targets,
  SettingsCubit settings,
) async {
  await targets.load();
  final defaults = targets.state.targets
      .where((t) => t.defaultEnabled && t.isInstalled)
      .map((t) => t.platformId)
      .toSet();
  if (defaults.isNotEmpty) await settings.setEnabledPlatforms(defaults);
}
