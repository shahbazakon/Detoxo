// analytics feature — public surface.
//
// Other features may import ONLY this barrel; never reach into data/ or
// presentation/ internals. Exposes the insights domain (entities + repository
// contracts) and `InsightsCubit`, which is provided app-wide and lazily in
// `main.dart` (the content_counter precedent); screens read it from context.

export 'package:detoxo/features/analytics/insights/domain/entities/daily_stats.dart';
export 'package:detoxo/features/analytics/insights/domain/repositories/insights_repository.dart';
export 'package:detoxo/features/analytics/insights/domain/usecases/compute_daily_stats.dart';
export 'package:detoxo/features/analytics/insights/presentation/insights_cubit.dart';
export 'package:detoxo/features/analytics/insights/presentation/insights_state.dart';
