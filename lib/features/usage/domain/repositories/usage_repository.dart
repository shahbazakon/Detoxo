import 'package:detoxo/features/usage/domain/entities/app_usage.dart';
import 'package:detoxo/features/usage/domain/entities/usage_event.dart';
import 'package:detoxo/features/usage/domain/entities/usage_query_result.dart';

/// Pull-only access to the device's own screen-time records
/// (`UsageStatsManager`). Nothing here persists or ticks; the insights layer
/// (M4) owns rollups. Callers batch by day — a month in one call is the kind
/// of payload that hurts.
abstract interface class UsageRepository {
  /// Tri-state Usage Access grant: null means "the read didn't answer", never
  /// "denied".
  Future<bool?> hasAccess();

  /// Per-app foreground time in `[start, end)`. Throws [ArgumentError] when
  /// [end] is not after [start].
  Future<UsageQueryResult<List<AppUsage>>> queryAppUsage(
    DateTime start,
    DateTime end,
  );

  /// Foreground / pickup events in `[start, end)`, ascending. Throws
  /// [ArgumentError] when [end] is not after [start].
  Future<UsageQueryResult<List<UsageEvent>>> queryUsageEvents(
    DateTime start,
    DateTime end,
  );
}
