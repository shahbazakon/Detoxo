// analytics feature — public domain (entities + repository contracts).
// Other features may import ONLY this barrel; never reach into data/ or presentation/ internals.

export 'package:detoxo/features/analytics/domain/repositories/analytics_repository.dart';
export 'package:detoxo/features/analytics/insights/domain/entities/daily_stats.dart';
export 'package:detoxo/features/analytics/insights/domain/repositories/insights_repository.dart';
export 'package:detoxo/features/analytics/insights/domain/usecases/compute_daily_stats.dart';
