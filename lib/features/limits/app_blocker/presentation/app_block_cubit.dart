import 'dart:async';

import 'package:detoxo/core/utils/app_logger.dart';
import 'package:detoxo/core/utils/package_name.dart';
import 'package:detoxo/features/limits/app_blocker/domain/entities/app_block_entry.dart';
import 'package:detoxo/features/limits/app_blocker/domain/repositories/app_block_repository.dart';
import 'package:detoxo/features/protected_apps/protected_apps.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Manages the full-app blocklist (CRUD + persistence).
class AppBlockCubit extends Cubit<List<AppBlockEntry>> {
  AppBlockCubit(this._repo, {this.onChanged}) : super(const []);

  final AppBlockRepository _repo;

  /// Fired after every persisted mutation, fire-and-forget. The screen wires
  /// this to `syncWebBlocklist` so app-derived web rules never go stale; a
  /// failure there must never block the app-blocker UI.
  final Future<void> Function()? onChanged;

  /// Hydrates from storage. A corrupt blob is logged, not thrown: the screen
  /// fires this as `..load()`, so a throw would surface as an uncaught-zone
  /// error, and `syncAppBlocklist` already aborts its push on the same
  /// failure (native keeps its last-good set). The next add overwrites it.
  Future<void> load() async {
    try {
      emit(await _repo.load());
    } on Object catch (e, s) {
      AppLogger.e('app blocklist unreadable', e, s);
    }
  }

  /// Adds a whole-app lock, or says why it can't — the caller's toast must
  /// tell the truth, so a refusal is never silent.
  Future<AppBlockAddResult> add(String packageName, String appName) async {
    final pkg = packageName.trim();
    if (!isValidPackageName(pkg)) return AppBlockAddResult.invalid;
    // Sensitive catalog apps may never be blocked, whatever the entry path.
    // (User-protected apps are only screened in the UI: this cubit has no
    // ProtectedAppsRepository, and the engine lets protection win regardless.)
    if (ProtectedAppCatalog.byPackage(pkg) != null) {
      return AppBlockAddResult.sensitive;
    }
    if (state.any((e) => e.packageName == pkg)) {
      return AppBlockAddResult.duplicate;
    }
    final next = [
      ...state,
      AppBlockEntry(
        packageName: pkg,
        appName: appName.trim().isEmpty ? pkg : appName.trim(),
      ),
    ];
    return await _commit(next)
        ? AppBlockAddResult.added
        : AppBlockAddResult.failed;
  }

  Future<void> toggle(int index, {required bool enabled}) async {
    final next = [...state];
    next[index] = next[index].copyWith(enabled: enabled);
    await _commit(next);
  }

  Future<void> removeAt(int index) async {
    final next = [...state]..removeAt(index);
    await _commit(next);
  }

  /// Persists + fires [onChanged]. A failed save reverts the optimistic emit
  /// and returns false (the web sibling's contract): a green "Added X" over a
  /// lock that never persisted — and was never pushed — is worse than an error.
  Future<bool> _commit(List<AppBlockEntry> entries) async {
    final previous = state;
    emit(entries);
    try {
      await _repo.save(entries);
    } on Object catch (e, s) {
      AppLogger.e('app blocklist save failed', e, s);
      emit(previous);
      return false;
    }
    if (onChanged != null) unawaited(onChanged!());
    return true;
  }
}
