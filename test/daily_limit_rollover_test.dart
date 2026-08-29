import 'package:detoxo/features/limits/daily_limit/domain/entities/daily_limit.dart';
import 'package:detoxo/features/limits/daily_limit/domain/repositories/daily_limit_repository.dart';
import 'package:detoxo/features/limits/daily_limit/presentation/daily_limit_cubit.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pins the midnight-reset boundary through the injectable clock — the reset
/// used to be untestable because `todaySignature()` hard-wired
/// `DateTime.now()` (the repo idiom is `StreakCubit.advance`'s injected days).
void main() {
  test('load() resets consumed time when the stored day is over', () async {
    final repo = _MemDailyLimitRepo(
      const DailyLimit(
        limit: Duration(minutes: 30),
        consumed: Duration(minutes: 25),
        dateSignature: '08-03-2026',
      ),
    );
    final cubit = DailyLimitCubit(
      repo,
      clock: () => DateTime(2026, 3, 9, 0, 5),
    );

    await cubit.load();

    expect(cubit.state.dateSignature, '09-03-2026');
    expect(cubit.state.consumed, Duration.zero, reason: 'new day starts fresh');
    expect(
      cubit.state.limit,
      const Duration(minutes: 30),
      reason: 'the configured limit survives the rollover',
    );
    await cubit.close();
  });

  test('load() keeps same-day consumption', () async {
    final repo = _MemDailyLimitRepo(
      const DailyLimit(
        limit: Duration(minutes: 30),
        consumed: Duration(minutes: 10),
        dateSignature: '09-03-2026',
      ),
    );
    final cubit = DailyLimitCubit(repo, clock: () => DateTime(2026, 3, 9, 18));

    await cubit.load();

    expect(cubit.state.consumed, const Duration(minutes: 10));
    await cubit.close();
  });
}

class _MemDailyLimitRepo implements DailyLimitRepository {
  _MemDailyLimitRepo(this._stored);
  DailyLimit _stored;

  @override
  Future<DailyLimit> load() async => _stored;

  @override
  Future<void> save(DailyLimit limit) async => _stored = limit;
}
