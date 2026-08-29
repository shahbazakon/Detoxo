import 'package:detoxo/core/constants/channel_constants.dart';
import 'package:detoxo/core/platform_channels/engine_channel.dart';
import 'package:detoxo/core/utils/app_logger.dart';
import 'package:detoxo/features/usage/domain/entities/app_usage.dart';
import 'package:detoxo/features/usage/domain/entities/usage_event.dart';
import 'package:detoxo/features/usage/domain/entities/usage_query_result.dart';
import 'package:detoxo/features/usage/domain/repositories/usage_repository.dart';
import 'package:flutter/services.dart';

/// Maps the two throwing channel arms onto [UsageQueryResult]:
/// `USAGE_ACCESS_DENIED` → [UsageDenied]; `BAD_ARGS` → [ArgumentError] (a
/// caller bug, surfaced loudly); any other failure or no native side →
/// [UsageUnavailable].
class UsageRepositoryImpl implements UsageRepository {
  UsageRepositoryImpl(this._channel);

  final EngineChannel _channel;

  @override
  Future<bool?> hasAccess() =>
      _channel.invokeBoolOrNull(ChannelMethods.hasUsageAccess);

  @override
  Future<UsageQueryResult<List<AppUsage>>> queryAppUsage(
    DateTime start,
    DateTime end,
  ) => _query(
    start,
    end,
    (s, e) => _channel.queryAppUsage(startMillis: s, endMillis: e),
    AppUsage.fromChannel,
  );

  @override
  Future<UsageQueryResult<List<UsageEvent>>> queryUsageEvents(
    DateTime start,
    DateTime end,
  ) => _query(
    start,
    end,
    (s, e) => _channel.queryUsageEvents(startMillis: s, endMillis: e),
    UsageEvent.fromChannel,
  );

  Future<UsageQueryResult<List<R>>> _query<R>(
    DateTime start,
    DateTime end,
    Future<List<Map<String, dynamic>>?> Function(int startMs, int endMs) call,
    R? Function(Map<String, dynamic> row) map,
  ) async {
    if (!end.isAfter(start)) {
      throw ArgumentError(
        'usage query: end ($end) must be after start ($start)',
      );
    }
    final List<Map<String, dynamic>>? rows;
    try {
      rows = await call(
        start.millisecondsSinceEpoch,
        end.millisecondsSinceEpoch,
      );
    } on PlatformException catch (e) {
      switch (e.code) {
        case 'USAGE_ACCESS_DENIED':
          return UsageDenied<List<R>>();
        case 'BAD_ARGS':
          throw ArgumentError(e.message ?? 'usage query: bad bounds');
        default:
          AppLogger.e('usage query failed', e);
          return UsageUnavailable<List<R>>();
      }
    }
    if (rows == null) return UsageUnavailable<List<R>>();
    return UsageGranted<List<R>>(rows.map(map).whereType<R>().toList());
  }
}
