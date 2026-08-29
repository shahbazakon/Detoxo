import 'package:detoxo/features/analytics/insights/domain/entities/daily_stats.dart';
import 'package:detoxo/features/usage/usage.dart';

/// Day rollups over the device's own screen-time records.
///
/// Pull-only, like the usage layer beneath it: nothing here ticks, streams or
/// runs in the background. Callers recompute on screen open, on pull-to-refresh
/// and on resume when the cached day has rolled over.
abstract interface class InsightsRepository {
  /// Recomputes today from `UsageStatsManager`, caches it, backfills yesterday
  /// when that record is missing or incomplete, and prunes to 90 days.
  ///
  /// Returns [UsageDenied] / [UsageUnavailable] **unchanged** when the grant is
  /// missing or the query failed — a screen must be able to tell "we were not
  /// allowed to look" from a genuinely quiet day (EVO-014).
  Future<UsageQueryResult<DailyStats>> today();

  /// The stored record for [dayKey] (`dd-MM-yyyy`), or null. Synchronous
  /// because `LocalStore.read` is; used for the previous-day comparison.
  DailyStats? cached(String dayKey);
}
