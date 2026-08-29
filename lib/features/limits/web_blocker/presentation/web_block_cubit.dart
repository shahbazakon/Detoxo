import 'dart:async';

import 'package:detoxo/core/utils/app_logger.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/app_settings.dart';
import 'package:detoxo/features/blocking/shared/domain/repositories/blocking_repositories.dart';
import 'package:detoxo/features/limits/app_blocker/domain/repositories/app_block_repository.dart';
import 'package:detoxo/features/limits/web_blocker/domain/entities/popular_site.dart';
import 'package:detoxo/features/limits/web_blocker/domain/entities/web_block_entry.dart';
import 'package:detoxo/features/limits/web_blocker/domain/entities/web_block_source.dart';
import 'package:detoxo/features/limits/web_blocker/domain/entities/web_block_stats.dart';
import 'package:detoxo/features/limits/web_blocker/domain/repositories/web_block_repository.dart';
import 'package:detoxo/features/limits/web_blocker/domain/repositories/web_block_stats_repository.dart';
import 'package:detoxo/features/limits/web_blocker/domain/utils/domain_validator.dart';
import 'package:detoxo/features/limits/web_blocker/domain/web_block_sync.dart';
import 'package:detoxo/features/limits/web_blocker/presentation/web_block_state.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Owns the website blocklist: CRUD + persistence, the two protection toggles,
/// live stats, and pushing the merged active blocklist to the native engine.
class WebBlockCubit extends Cubit<WebBlockState> {
  WebBlockCubit(
    this._repo,
    this._settings,
    this._appBlocks,
    this._statsRepo,
    this._engine,
  ) : super(const WebBlockState());

  final WebBlockRepository _repo;
  final SettingsRepository _settings;
  final AppBlockRepository _appBlocks;
  final WebBlockStatsRepository _statsRepo;
  final EngineRepository _engine;

  StreamSubscription<WebBlockStats>? _statsSub;

  Future<void> load() async {
    try {
      final entries = await _repo.load();
      final settings = await _settings.load();
      final stats = await _statsRepo.load();
      // Built fresh rather than copyWith'd, so a retry after a failed load
      // returns `loadFailed` to false along with everything else.
      emit(
        WebBlockState(
          isLoading: false,
          entries: entries,
          stats: stats,
          blockAdult: settings.blockAdultWebsites,
          blockForApps: settings.blockWebsitesForBlockedApps,
        ),
      );
      _statsSub ??= _statsRepo.watch().listen((s) {
        if (!isClosed) emit(state.copyWith(stats: s));
      });
      // Re-sync native with the persisted blocklist on (re)entry.
      await _pushAll();
      // EVO-047, deliberately AFTER the push and outside the load try: this is
      // a nice-to-have notice, and it must never be the reason the blocklist
      // fails to render.
      unawaited(_loadUnsupportedBrowsers());
    } on Object catch (e, s) {
      // `entries` stays at its default here, so the screen MUST be told the
      // difference between "nothing blocked" and "unreadable" — otherwise a
      // corrupt blob renders the "add your first site" call to action over a
      // blocklist that is still being enforced natively.
      AppLogger.e('web blocklist load failed', e, s);
      emit(
        state.copyWith(isLoading: false, error: _loadFailed, loadFailed: true),
      );
    }
  }

  /// Adds a user-typed domain after validation + dedupe. Returns false when
  /// rejected or the commit failed (the error is in [WebBlockState.error]).
  Future<bool> addCustom(String domain) async {
    final checked = DomainValidator.check(
      domain,
      state.entries.map((e) => e.pattern),
    );
    if (checked.host == null) {
      emit(state.copyWith(error: checked.error));
      return false;
    }
    return _commit([
      ...state.entries,
      // source defaults to WebBlockSource.custom.
      WebBlockEntry(pattern: checked.host!, createdAt: DateTime.now()),
    ]);
  }

  /// Enables/disables a popular site with a single tap. A custom entry that
  /// already covers the primary domain is converted to the popular entry
  /// instead of being silently deleted (and vice versa on removal, only
  /// popular-sourced entries are removed).
  Future<void> togglePopular(PopularSite site) async {
    final existing = state.entries
        .where((e) => e.pattern == site.primaryDomain)
        .firstOrNull;
    if (existing != null && existing.source == WebBlockSource.popular) {
      await _commit(
        state.entries.where((e) => e.pattern != site.primaryDomain).toList(),
      );
    } else if (existing != null) {
      // Custom entry with the same pattern: upgrade it in place.
      await _commit([
        for (final e in state.entries)
          if (e.pattern == site.primaryDomain)
            e.copyWith(
              displayName: site.name,
              source: WebBlockSource.popular,
              brandColor: site.brandColor,
            )
          else
            e,
      ]);
    } else {
      await _commit([
        ...state.entries,
        WebBlockEntry(
          pattern: site.primaryDomain,
          displayName: site.name,
          source: WebBlockSource.popular,
          brandColor: site.brandColor,
          createdAt: DateTime.now(),
        ),
      ]);
    }
  }

  Future<void> toggleEntry(WebBlockEntry entry, {required bool enabled}) async {
    await _commit([
      for (final e in state.entries)
        if (e.pattern == entry.pattern) e.copyWith(enabled: enabled) else e,
    ]);
  }

  Future<void> removeEntry(WebBlockEntry entry) async {
    await _commit(
      state.entries.where((e) => e.pattern != entry.pattern).toList(),
    );
  }

  // M8: `pauseEntry` / `resumeEntry` are gone. A paused site is a WEBSITE grant
  // in `UnblockCubit` — the same mechanism that frees an app or a reel feed —
  // so the screen calls `grant(...)` / `endEarly(...)` with the entry's pattern
  // and its aliases. Two mechanisms for "dormant until T" collapsed into one.

  /// Edits a custom entry's domain (re-validates + dedupes). Only custom
  /// entries are editable — enforced here, not just by the screen's affordance.
  Future<bool> editEntry(WebBlockEntry entry, String newDomain) async {
    if (entry.source != WebBlockSource.custom) return false;
    final checked = DomainValidator.check(
      newDomain,
      state.entries.map((e) => e.pattern),
      ignoring: entry.pattern,
    );
    if (checked.host == null) {
      emit(state.copyWith(error: checked.error));
      return false;
    }
    return _commit([
      for (final e in state.entries)
        if (e.pattern == entry.pattern)
          e.copyWith(pattern: checked.host)
        else
          e,
    ]);
  }

  Future<void> setBlockAdult({required bool value}) async {
    final previous = state.blockAdult;
    emit(state.copyWith(blockAdult: value, clearError: true));
    final ok = await _saveSettings(
      (s) => s.copyWith(blockAdultWebsites: value),
    );
    if (!ok) emit(state.copyWith(blockAdult: previous, error: _saveFailed));
  }

  Future<void> setBlockForApps({required bool value}) async {
    final previous = state.blockForApps;
    emit(state.copyWith(blockForApps: value, clearError: true));
    final ok = await _saveSettings(
      (s) => s.copyWith(blockWebsitesForBlockedApps: value),
    );
    if (!ok) {
      emit(state.copyWith(blockForApps: previous, error: _saveFailed));
      return;
    }
    // The derived app→domain rules changed, so re-push the blocklist too.
    await _pushAll();
  }

  /// Load-modify-write of the shared settings + a best-effort native push.
  /// False when persisting failed (callers revert their optimistic emit — the
  /// same contract as [_commit]). A failed push is only logged: the value IS
  /// saved, and `SettingsCubit.resync` re-pushes the repository on resume.
  Future<bool> _saveSettings(AppSettings Function(AppSettings) update) async {
    final AppSettings next;
    try {
      next = update(await _settings.load());
      await _settings.save(next);
    } on Object {
      return false;
    }
    try {
      await _engine.pushSettings(next);
    } on Object catch (e) {
      AppLogger.e('web blocker settings push failed', e);
    }
    return true;
  }

  /// Asks native which installed browsers the engine cannot read. A null answer
  /// (off-Android, channel error) leaves the list empty, so the screen stays
  /// silent rather than claiming coverage it has not verified either way.
  Future<void> _loadUnsupportedBrowsers() async {
    try {
      final browsers = await _engine.unsupportedBrowsers();
      if (browsers == null || isClosed) return;
      emit(state.copyWith(unsupportedBrowsers: browsers));
    } on Object catch (e) {
      AppLogger.e('unsupported-browser query failed', e);
    }
  }

  void search(String query) => emit(state.copyWith(query: query));

  void clearError() => emit(state.copyWith(clearError: true));

  static const _saveFailed = "Couldn't save — try again";

  /// Never the raw exception: `e.toString()` here reaches a user-facing toast
  /// as `FormatException: Unexpected character…`.
  static const _loadFailed = "Couldn't open your blocklist";

  /// Persists + pushes; on failure reverts the optimistic emit and surfaces the
  /// error (a green "Blocked X" over a failed save is worse than an error).
  Future<bool> _commit(List<WebBlockEntry> entries) async {
    final previous = state.entries;
    emit(state.copyWith(entries: entries, clearError: true));
    try {
      await _repo.save(entries);
    } on Object {
      emit(state.copyWith(entries: previous, error: _saveFailed));
      return false;
    }
    await _pushAll(); // best-effort by contract; never throws
    return true;
  }

  /// Ships the merged active blocklist to native. Every caller persists before
  /// pushing, so repo state always matches cubit state here.
  Future<void> _pushAll() =>
      syncWebBlocklist(_repo, _settings, _appBlocks, _engine);

  @override
  Future<void> close() {
    _statsSub?.cancel();
    return super.close();
  }
}
