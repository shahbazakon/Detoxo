import 'package:detoxo/core/utils/app_logger.dart';
import 'package:detoxo/features/blocking/shared/domain/repositories/blocking_repositories.dart';
import 'package:detoxo/features/limits/app_blocker/domain/repositories/app_block_repository.dart';

/// Ships the enabled custom whole-app blocks to the native engine, which
/// bounces those apps HOME on open.
///
/// The single push path, called from App Blocker mutations, the splash
/// bootstrap (repairs Dart→native drift, e.g. after "Reset app data"), and the
/// resume re-sync. Same fail-safe contract as `syncWebBlocklist`: a failed
/// load ABORTS the push — native keeps enforcing its last-good persisted set,
/// and a corrupt Dart store can never push `[]` and wipe it.
Future<void> syncAppBlocklist(
  AppBlockRepository repo,
  EngineRepository engine,
) async {
  try {
    final entries = await repo.load();
    await engine.pushAppBlocklist([
      for (final e in entries)
        if (e.enabled) e.packageName,
    ]);
  } on Object catch (e, s) {
    AppLogger.e('app blocklist sync failed', e, s);
  }
}
