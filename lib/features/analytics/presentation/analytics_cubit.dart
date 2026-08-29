import 'dart:async';

import 'package:detoxo/features/analytics/domain/repositories/analytics_repository.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/engine_event.dart';
import 'package:detoxo/features/blocking/shared/domain/repositories/blocking_repositories.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Loads the local block-event history and persists incoming block events.
class AnalyticsCubit extends Cubit<List<BlockEvent>> {
  AnalyticsCubit(this._repo, this._engine) : super(const []) {
    _blocks = _engine.blockStream().listen(_repo.logBlock);
  }

  final AnalyticsRepository _repo;
  final EngineRepository _engine;

  /// Held so it can be cancelled. Without this every mount left a permanent
  /// listener on the broadcast block stream — and this cubit is rebuilt per
  /// `_ActivityBody`, including the pushed drawer route — so N visits meant N
  /// concurrent writers appending the same event to one Hive key.
  late final StreamSubscription<BlockEvent> _blocks;

  Future<void> load() async => emit(await _repo.recent(limit: 100));

  @override
  Future<void> close() async {
    await _blocks.cancel();
    return super.close();
  }
}
