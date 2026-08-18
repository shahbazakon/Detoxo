import 'dart:async';

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
    } on Object catch (e) {
      emit(state.copyWith(isLoading: false, error: e.toString()));
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
        if (e.pattern == entry.pattern)
          // Re-enabling or disabling also drops any pause window.
          e.copyWith(enabled: enabled, clearPause: true)
        else
          e,
    ]);
  }

  Future<void> removeEntry(WebBlockEntry entry) async {
    await _commit(
      state.entries.where((e) => e.pattern != entry.pattern).toList(),
    );
  }

  /// EVO-012: allow [entry]'s site for [window] — native re-arms it at expiry
  /// even if this app never runs again.
  Future<void> pauseEntry(WebBlockEntry entry, Duration window) async {
    await _commit([
      for (final e in state.entries)
        if (e.pattern == entry.pattern)
          e.copyWith(pausedUntil: DateTime.now().add(window))
        else
          e,
    ]);
  }

  /// Ends a per-site pause immediately.
  Future<void> resumeEntry(WebBlockEntry entry) async {
    await _commit([
      for (final e in state.entries)
        if (e.pattern == entry.pattern) e.copyWith(clearPause: true) else e,
    ]);
  }

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
    emit(state.copyWith(blockAdult: value, clearError: true));
    final next = (await _settings.load()).copyWith(blockAdultWebsites: value);
    await _settings.save(next);
    await _engine.pushSettings(next);
  }

  Future<void> setBlockForApps({required bool value}) async {
    emit(state.copyWith(blockForApps: value, clearError: true));
    final next = (await _settings.load()).copyWith(
      blockWebsitesForBlockedApps: value,
    );
    await _settings.save(next);
    await _engine.pushSettings(next);
    // The derived app→domain rules changed, so re-push the blocklist too.
    await _pushAll();
  }

  void search(String query) => emit(state.copyWith(query: query));

  void clearError() => emit(state.copyWith(clearError: true));

  /// Persists + pushes; on failure reverts the optimistic emit and surfaces the
  /// error (a green "Blocked X" over a failed save is worse than an error).
  Future<bool> _commit(List<WebBlockEntry> entries) async {
    final previous = state.entries;
    emit(state.copyWith(entries: entries, clearError: true));
    try {
      await _repo.save(entries);
    } on Object {
      emit(
        state.copyWith(entries: previous, error: "Couldn't save — try again"),
      );
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
