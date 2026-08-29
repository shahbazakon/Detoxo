import 'dart:convert';

import 'package:detoxo/core/storage/local_store.dart';
import 'package:detoxo/core/utils/app_logger.dart';
import 'package:detoxo/core/utils/day_signature.dart';
import 'package:detoxo/features/analytics/insights/domain/entities/daily_stats.dart';
import 'package:detoxo/features/analytics/insights/domain/repositories/insights_repository.dart';
import 'package:detoxo/features/analytics/insights/domain/usecases/compute_daily_stats.dart';
import 'package:detoxo/features/catalog/catalog.dart';
import 'package:detoxo/features/content_counter/content_counter.dart';
import 'package:detoxo/features/limits/limits.dart' show todayInterval;
import 'package:detoxo/features/protected_apps/protected_apps.dart';
import 'package:detoxo/features/usage/usage.dart';

/// Rollups over M0.2's usage layer, cached in one day-keyed Hive document.
///
/// The cache exists for history and offline reads, not for speed: a day is one
/// `queryAppUsage` + one `queryUsageEvents` + an O(n) fold over a few hundred
/// events. Nothing here ticks.
class InsightsRepositoryImpl implements InsightsRepository {
  InsightsRepositoryImpl(
    this._usage,
    this._counter,
    this._protected,
    this._store, {
    this._clock = DateTime.now,
    Catalog? catalog,
  }) : _catalog = catalog ?? Catalog.bundled;

  final UsageRepository _usage;
  final ContentCounterRepository _counter;

  /// Read on every recompute so the apps the user hides never reach `topApps`
  /// — neither the screen nor the stored document.
  final ProtectedAppsRepository _protected;
  final LocalStore _store;

  /// Injected so day-rollover and backfill can be pinned by a test without
  /// waiting for midnight (the `DailyLimitCubit` precedent).
  final DateTime Function() _clock;
  final Catalog _catalog;

  /// Retention. 90 small records is a few tens of KB in one JSON document,
  /// which is fine; unbounded growth would not be.
  static const int maxDays = 90;

  @override
  DailyStats? cached(String dayKey) => _dayFrom(_readDays(), dayKey);

  /// One record out of an already-decoded document.
  static DailyStats? _dayFrom(Map<String, dynamic> days, String dayKey) {
    final day = days[dayKey];
    return day is Map
        ? DailyStats.fromJson(dayKey, Map<String, dynamic>.from(day))
        : null;
  }

  @override
  Future<UsageQueryResult<DailyStats>> today() async {
    final now = _clock();
    final (start, _) = todayInterval(now);
    final key = daySignature(start);
    // Decoded once and threaded through: every `cached()` call re-parses the
    // whole 90-day document, and this method used to make four of them.
    final days = _readDays();

    // Exactly midnight: the window is empty, so the query would be a wasted
    // round trip. The grant is still checked — answering a confident `0 m` to
    // someone who never granted Usage Access is the one thing this screen
    // exists to avoid (EVO-014).
    if (!now.isAfter(start)) {
      if (await _usage.hasAccess() == false) return const UsageDenied();
      return UsageGranted(DailyStats(dayKey: key, computedAtMs: _ms(now)));
    }

    final protectedPackages = await _protectedPackages();
    final computed = await _computeWindow(
      start: start,
      end: now,
      reelCount: await _reelCount(),
      complete: false,
      now: now,
      protectedPackages: protectedPackages,
    );

    switch (computed) {
      case UsageGranted<DailyStats>(:final data):
        await _persist({
          if (!_wouldDowngrade(days, key, data)) key: data,
          ...await _backfillYesterday(start, days),
        }, days);
        return UsageGranted(data);
      case UsageDenied<DailyStats>():
        // Denied is denied: never fall back to a stale figure the user would
        // read as live, and never synthesise an empty day.
        return const UsageDenied();
      case UsageUnavailable<DailyStats>():
        // The engine did not answer (iOS, a dead service, a query throw). A
        // record already computed for *this* day is still the truth we had.
        final fallback = _dayFrom(days, key);
        return fallback == null
            ? const UsageUnavailable()
            : UsageGranted(fallback);
    }
  }

  /// True when writing [fresh] would replace a finished day with a partial one.
  ///
  /// Reachable by moving the device clock backwards: `today()` then recomputes
  /// an earlier day over `[midnight, now)` and would clobber its real totals.
  bool _wouldDowngrade(
    Map<String, dynamic> days,
    String key,
    DailyStats fresh,
  ) {
    if (fresh.complete) return false;
    return _dayFrom(days, key)?.complete ?? false;
  }

  /// Yesterday as a finished day, computed once. Returns an empty map when the
  /// record is already complete or the query cannot answer.
  ///
  /// ponytail: backfills one day, not seven. UsageStats retains ~7 days on most
  /// devices; deeper backfill lands with the history UI.
  Future<Map<String, DailyStats>> _backfillYesterday(
    DateTime todayStart,
    Map<String, dynamic> days,
  ) async {
    final start = DateTime(
      todayStart.year,
      todayStart.month,
      todayStart.day - 1,
    );
    final key = daySignature(start);
    final stored = _dayFrom(days, key);
    if (stored?.complete ?? false) return const {};

    final result = await _computeWindow(
      start: start,
      end: todayStart,
      // Yesterday's reel count is not recoverable from the counter (it only
      // reports today), so it stays at whatever a live record already stored.
      reelCount: stored?.reelCount ?? 0,
      complete: true,
      now: _clock(),
      protectedPackages: await _protectedPackages(),
    );
    return switch (result) {
      UsageGranted<DailyStats>(:final data) => {key: data},
      _ => const {},
    };
  }

  /// One `[start, end)` window through the usage layer and the pure fold. Grant
  /// and engine failures propagate as themselves.
  Future<UsageQueryResult<DailyStats>> _computeWindow({
    required DateTime start,
    required DateTime end,
    required int reelCount,
    required bool complete,
    required DateTime now,
    Set<String> protectedPackages = const {},
  }) async {
    final usage = await _usage.queryAppUsage(start, end);
    if (usage is! UsageGranted<List<AppUsage>>) return _carry(usage);
    final events = await _usage.queryUsageEvents(start, end);
    if (events is! UsageGranted<List<UsageEvent>>) return _carry(events);

    return UsageGranted(
      computeDailyStats(
        usage: usage.data,
        events: events.data,
        catalog: _catalog,
        start: start,
        end: end,
        protectedPackages: protectedPackages,
        reelCount: reelCount,
        complete: complete,
        computedAtMs: _ms(now),
      ),
    );
  }

  /// Catalog protections plus the user's own additions — the same set the
  /// engine is told to ignore (`protectedPackagesFor`).
  ///
  /// A failed read degrades to the **bundled catalog** rather than to an empty
  /// set, so the seeded banking / UPI / password-manager packages stay hidden
  /// even when the user's own additions can't be loaded. (`load()` already
  /// salvages a corrupt document rather than throwing, so this is the
  /// belt-and-braces path.)
  Future<Set<String>> _protectedPackages() async {
    try {
      return protectedPackagesFor(await _protected.load()).toSet();
    } on Object catch (e, s) {
      AppLogger.e('insights: protected-app read failed, using catalog', e, s);
      return protectedPackagesFor(const []).toSet();
    }
  }

  /// The reel counter's figure for today. A counter failure must not cost the
  /// user the rest of the screen, so it degrades to 0 rather than throwing.
  Future<int> _reelCount() async {
    try {
      return (await _counter.current()).today;
    } on Object catch (e, s) {
      AppLogger.e('insights: reel count read failed', e, s);
      return 0;
    }
  }

  /// Merges [records] into the stored document and prunes to [maxDays].
  Future<void> _persist(
    Map<String, DailyStats> records,
    Map<String, dynamic> days,
  ) async {
    if (records.isEmpty) return;
    for (final entry in records.entries) {
      days[entry.key] = entry.value.toJson();
    }
    await _store.write(
      StoreKeys.usageDaily,
      jsonEncode({'days': _prune(days)}),
    );
  }

  /// Keeps the newest [maxDays] keys. Ordered by the day the key *names*, not
  /// by insertion: a backfilled record must not evict a newer one.
  Map<String, dynamic> _prune(Map<String, dynamic> days) {
    if (days.length <= maxDays) return days;
    final keys = days.keys.toList()
      ..sort((a, b) => _sortableKey(a).compareTo(_sortableKey(b)));
    return {for (final k in keys.skip(days.length - maxDays)) k: days[k]};
  }

  /// `dd-MM-yyyy` → `yyyyMMdd`, so day keys sort chronologically as strings.
  /// An unparseable key sorts oldest and is pruned away first.
  static String _sortableKey(String dayKey) {
    final p = dayKey.split('-');
    return p.length == 3 ? '${p[2]}${p[1]}${p[0]}' : '';
  }

  /// The stored `days` map, or an empty one. A corrupt blob is logged and
  /// treated as absent — it must never take the screen down with it.
  Map<String, dynamic> _readDays() {
    final raw = _store.read(StoreKeys.usageDaily);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final days = decoded['days'];
      return days is Map ? Map<String, dynamic>.from(days) : {};
    } on Object catch (e, s) {
      AppLogger.e('insights: corrupt usage_daily blob, starting fresh', e, s);
      return {};
    }
  }

  /// Re-types a non-granted result for a different payload type.
  static UsageQueryResult<DailyStats> _carry(UsageQueryResult<Object> r) =>
      r is UsageDenied ? const UsageDenied() : const UsageUnavailable();

  static int _ms(DateTime t) => t.millisecondsSinceEpoch;
}
