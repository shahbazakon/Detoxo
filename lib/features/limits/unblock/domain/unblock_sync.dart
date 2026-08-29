import 'dart:convert';

import 'package:detoxo/core/utils/app_logger.dart';
import 'package:detoxo/features/blocking/shared/domain/repositories/blocking_repositories.dart';
import 'package:detoxo/features/limits/unblock/domain/entities/temporary_unblock.dart';
import 'package:detoxo/features/limits/unblock/domain/repositories/unblock_repositories.dart';
import 'package:detoxo/features/limits/unblock/domain/usecases/unblock_quota.dart';

/// Ships the ACTIVE per-target grants to the native engine and hands back the
/// full stored list, so the caller can derive its state from the same read.
///
/// The single push path — called from the unblock cubit on every mutation, on
/// resume and from the splash bootstrap (which repairs Dart→native drift, e.g.
/// after "Reset app data"). The `syncWebBlocklist` shape throughout.
///
/// Returns null when the push was ABORTED: a failed load must never let a
/// corrupt Dart store push `[]`, which native honours as an intentional clear
/// and would yank a live grant out from under the user.
Future<List<TemporaryUnblock>?> syncTemporaryUnblocks(
  TemporaryUnblockRepository repo,
  EngineRepository engine, {
  DateTime Function()? now,
}) async {
  try {
    final nowMs = (now?.call() ?? DateTime.now()).millisecondsSinceEpoch;
    final grants = await repo.load();
    // Only the live ones cross the wire: native re-derives nothing, and a
    // cancelled or finished row would just be parsed and dropped there.
    await engine.pushTemporaryUnblocks(
      jsonEncode([
        for (final g in UnblockQuota.activeAt(grants, nowMs)) g.toWire(),
      ]),
    );
    return grants;
  } on Object catch (e, s) {
    // Best-effort by contract, reported non-fatally: a background sync must
    // never book a fatal into Crashlytics, and native keeps enforcing its
    // last-good persisted list, which is the fail-SAFE direction.
    AppLogger.e('temporary unblock sync failed', e, s);
    return null;
  }
}
