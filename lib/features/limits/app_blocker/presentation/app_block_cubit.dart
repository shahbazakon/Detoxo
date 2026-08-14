import 'package:detoxo/core/utils/package_name.dart';
import 'package:detoxo/features/limits/app_blocker/domain/entities/app_block_entry.dart';
import 'package:detoxo/features/limits/app_blocker/domain/repositories/app_block_repository.dart';
import 'package:detoxo/features/protected_apps/protected_apps.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Manages the full-app blocklist (CRUD + persistence).
class AppBlockCubit extends Cubit<List<AppBlockEntry>> {
  AppBlockCubit(this._repo) : super(const []);

  final AppBlockRepository _repo;

  Future<void> load() async => emit(await _repo.load());

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
    await _commit(next);
    return AppBlockAddResult.added;
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

  Future<void> _commit(List<AppBlockEntry> entries) async {
    emit(entries);
    await _repo.save(entries);
  }
}
