import 'package:detoxo/core/utils/day_signature.dart';
import 'package:detoxo/features/limits/streak/domain/entities/streak.dart';
import 'package:detoxo/features/limits/streak/domain/repositories/streak_repository.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Tracks the "days under your daily limit" streak with a device-local midnight
/// rollover. [observe] is fed today's under-limit status by the dashboard hero
/// (which already computes usage vs. limit); the streak advances once per day
/// and resets when a day is skipped or the limit is exceeded.
class StreakCubit extends Cubit<Streak> {
  StreakCubit(this._repo) : super(const Streak());

  final StreakRepository _repo;

  // An observe() that lands before load() has emitted would advance — and
  // PERSIST — the empty default over the real streak (the dashboard hero
  // observes post-frame on its first build, ahead of load()'s continuation),
  // wiping it on the next cold start. Nothing is reconciled until loaded.
  bool _loaded = false;

  static String _sig(DateTime d) => daySignature(d);

  Future<void> load() async {
    emit(await _repo.load());
    _loaded = true;
  }

  /// Reconciles the streak for [now] given whether today is under the limit.
  /// A cheap no-op when nothing changes (bloc skips equal states) and before
  /// [load] has completed.
  Future<void> observe({
    required DateTime now,
    required bool underLimit,
  }) async {
    if (!_loaded) return;
    final today = DateTime(now.year, now.month, now.day);
    // Calendar arithmetic, NOT subtract(Duration(days: 1)): that subtracts 24h
    // of absolute time, which on the day after a DST spring-forward (a 23h
    // day) lands two calendar days back and silently resets the streak.
    final yesterday = DateTime(now.year, now.month, now.day - 1);
    final next = advance(
      state,
      today: _sig(today),
      yesterday: _sig(yesterday),
      underLimit: underLimit,
    );
    if (next == state) return;
    await _repo.save(next);
    emit(next);
  }

  /// Pure streak transition (extracted for tests): same-day makes a failure
  /// sticky; a consecutive under-limit day carries yesterday's committed streak
  /// forward; any gap — or a day where yesterday failed — starts fresh.
  @visibleForTesting
  static Streak advance(
    Streak s, {
    required String today,
    required String yesterday,
    required bool underLimit,
  }) {
    if (s.lastDay == today) {
      return s.copyWith(todayFailed: s.todayFailed || !underLimit);
    }
    final base = s.lastDay == yesterday && !s.todayFailed ? s.count : 0;
    return Streak(base: base, lastDay: today, todayFailed: !underLimit);
  }
}
