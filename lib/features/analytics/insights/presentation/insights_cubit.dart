import 'package:detoxo/core/utils/app_logger.dart';
import 'package:detoxo/core/utils/day_signature.dart';
import 'package:detoxo/features/analytics/insights/domain/entities/daily_stats.dart';
import 'package:detoxo/features/analytics/insights/domain/repositories/insights_repository.dart';
import 'package:detoxo/features/analytics/insights/presentation/insights_state.dart';
import 'package:detoxo/features/blocking/shared/domain/repositories/blocking_repositories.dart';
import 'package:detoxo/features/usage/usage.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Drives the Insights view.
///
/// Pull-only: it recomputes on [load], on [refresh] (pull-to-refresh) and on
/// [refreshIfStale] (app resume). **No ticker, no stream, no background job** —
/// a day is two channel queries and an O(n) fold, so there is nothing to keep
/// warm.
class InsightsCubit extends Cubit<InsightsState> {
  InsightsCubit(this._repo, this._engine, {this.clock = DateTime.now})
    : super(const InsightsState());

  final InsightsRepository _repo;
  final EngineRepository _engine;

  /// Injected so day-rollover can be pinned by a test (the `DailyLimitCubit`
  /// precedent).
  final DateTime Function() clock;

  /// Guards against a pull-to-refresh and a resume racing into two identical
  /// pairs of channel queries.
  bool _inFlight = false;

  Future<void> load() => _compute();

  Future<void> refresh() => _compute();

  /// Recomputes only when the day has rolled over since the last successful
  /// compute — the cheap resume path for a session held across midnight.
  Future<void> refreshIfStale() async {
    if (state.stats?.dayKey == daySignature(clock())) return;
    await _compute();
  }

  /// Never throws: every failure path ends in an emitted state, because the
  /// alternative is an uncaught zone error and a spinner that never resolves.
  Future<void> _compute() async {
    if (_inFlight) return;
    _inFlight = true;
    // Only the very first read shows a spinner; a refresh keeps the numbers on
    // screen rather than blanking them for two channel round trips.
    if (state.stats == null) {
      emit(state.copyWith(status: InsightsStatus.loading));
    }
    try {
      final result = await _repo.today();
      if (isClosed) return;

      switch (result) {
        case UsageGranted<DailyStats>(:final data):
          // Built, not `copyWith`-ed: `yesterday` must be set to exactly what
          // `_completeYesterday()` returned — including null. `copyWith`'s
          // `?? this.yesterday` would keep the *previous* day's record after a
          // rollover and label it "yesterday", which is a wrong number stated
          // as a fact on the screen whose whole point is honest ones.
          emit(
            InsightsState(
              status: InsightsStatus.granted,
              stats: data,
              yesterday: _completeYesterday(),
              // Last known labels stay until the new ones resolve; the list
              // falls back to package names, never to a blank row.
              apps: state.apps,
            ),
          );
          // Second emit on purpose: the numbers are already in hand, and
          // `installedApps()` is an uncached native scan that reads a label and
          // an icon per package. Gating the first paint on it would withhold
          // the whole screen for cosmetics.
          final apps = await _appLabels(data);
          if (isClosed) return;
          emit(state.copyWith(apps: apps));
        case UsageDenied<DailyStats>():
          emit(state.copyWith(status: InsightsStatus.denied, clearStats: true));
        case UsageUnavailable<DailyStats>():
          emit(
            state.copyWith(
              status: InsightsStatus.unavailable,
              clearStats: true,
            ),
          );
      }
    } on Object catch (e, s) {
      // A throw from the repository (a bad window, a Hive write failure) must
      // land the user on the retryable "we couldn't read this" card, not on a
      // permanent spinner.
      AppLogger.e('insights: compute failed', e, s);
      if (!isClosed) {
        emit(
          state.copyWith(status: InsightsStatus.unavailable, clearStats: true),
        );
      }
    } finally {
      _inFlight = false;
    }
  }

  /// Yesterday, but only if it is a finished day — comparing today against a
  /// partial yesterday would flatter every number until bedtime.
  DailyStats? _completeYesterday() {
    final today = clock();
    final before = DateTime(today.year, today.month, today.day - 1);
    final stats = _repo.cached(daySignature(before));
    return (stats?.complete ?? false) ? stats : null;
  }

  /// Labels + icons for the top apps, from the engine's process-cached
  /// installed-app list. A failure costs the labels, never the numbers — the
  /// list falls back to package names.
  Future<Map<String, InstalledApp>> _appLabels(DailyStats stats) async {
    if (stats.topApps.isEmpty) return state.apps;
    try {
      final apps = await _engine.installedApps();
      if (apps == null) return state.apps;
      final wanted = stats.topApps.map((a) => a.package).toSet();
      return {
        for (final a in apps)
          if (wanted.contains(a.packageName)) a.packageName: a,
      };
    } on Object catch (e, s) {
      AppLogger.e('insights: app label lookup failed', e, s);
      return state.apps;
    }
  }
}
