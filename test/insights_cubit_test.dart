import 'dart:async';

import 'package:detoxo/features/analytics/analytics.dart';
import 'package:detoxo/features/blocking/shared/domain/repositories/blocking_repositories.dart';
import 'package:detoxo/features/usage/usage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockEngine extends Mock implements EngineRepository {}

/// A repository whose answers and cached days are set per test.
class _FakeRepo implements InsightsRepository {
  UsageQueryResult<DailyStats> result = const UsageUnavailable();

  /// Thrown from `today()` when set — the path that used to strand the spinner.
  Object? throws;

  /// dayKey → record, standing in for the rollup store.
  final Map<String, DailyStats> days = {};

  /// The live grant, as the resume path re-reads it (`null` = could not read).
  bool? access = true;
  int accessReads = 0;

  @override
  Future<UsageQueryResult<DailyStats>> today() async {
    final t = throws;
    // ignore: only_throw_errors — the point is that ANY throw is contained.
    if (t != null) throw t;
    return result;
  }

  @override
  DailyStats? cached(String dayKey) => days[dayKey];

  @override
  Future<bool?> hasAccess() async {
    accessReads++;
    return access;
  }
}

DailyStats _day(String key, {int ms = 0, bool complete = false}) =>
    DailyStats(dayKey: key, screenTimeMs: ms, complete: complete);

const String _today = '02-09-2026';
const String _yesterday = '01-09-2026';

void main() {
  late _MockEngine engine;
  late _FakeRepo repo;
  var now = DateTime(2026, 9, 2, 12);

  InsightsCubit build() => InsightsCubit(repo, engine, clock: () => now);

  setUp(() {
    engine = _MockEngine();
    repo = _FakeRepo();
    now = DateTime(2026, 9, 2, 12);
    when(() => engine.installedApps()).thenAnswer((_) async => const []);
  });

  group('failure handling', () {
    test(
      'a throwing repository lands on unavailable, not a stuck spinner',
      () async {
        repo.throws = StateError('disk on fire');
        final cubit = build();

        await cubit.load();

        expect(cubit.state.status, InsightsStatus.unavailable);
        expect(cubit.state.stats, isNull);
      },
    );

    test('load() never throws, so an unawaited resume leg is safe', () async {
      repo.throws = ArgumentError('end must be after start');

      await expectLater(build().load(), completes);
    });

    test(
      'labels resolve even without the grant, for the reel and block rows',
      () async {
        // The Activity screen's one installed-app lookup: reels and blocks
        // need no permission, so a denied screen-time read must still label.
        when(() => engine.installedApps()).thenAnswer(
          (_) async => const [
            InstalledApp(
              packageName: 'com.instagram.android',
              appName: 'Instagram',
            ),
          ],
        );
        repo.result = const UsageDenied();
        final cubit = build();

        await cubit.load();

        expect(cubit.state.status, InsightsStatus.denied);
        expect(cubit.state.apps['com.instagram.android']?.appName, 'Instagram');
      },
    );

    test('closing during the installed-apps scan does not throw', () async {
      // The scan resolves after the cubit is gone — the second emit must not
      // run on a closed cubit.
      final gate = Completer<List<InstalledApp>>();
      when(() => engine.installedApps()).thenAnswer((_) => gate.future);
      repo.result = UsageGranted(_day(_today, ms: 1000));
      final cubit = build();

      final pending = cubit.load();
      await Future<void>.delayed(Duration.zero);
      await cubit.close();
      gate.complete(const []);

      await expectLater(pending, completes);
    });
  });

  group('yesterday comparison', () {
    test('a complete yesterday is adopted', () async {
      repo
        ..result = UsageGranted(_day(_today, ms: 7200000))
        ..days[_yesterday] = _day(_yesterday, ms: 14400000, complete: true);
      final cubit = build();

      await cubit.load();

      expect(cubit.state.yesterday?.dayKey, _yesterday);
      expect(cubit.state.yesterdayScreenTime, const Duration(hours: 4));
      // Today is still running, so no percentage is asserted.
      expect(cubit.state.screenTimeDeltaPercent, isNull);
    });

    test('an incomplete yesterday is ignored', () async {
      repo
        ..result = UsageGranted(_day(_today, ms: 7200000))
        ..days[_yesterday] = _day(_yesterday, ms: 14400000);
      final cubit = build();

      await cubit.load();

      expect(cubit.state.yesterday, isNull);
      expect(cubit.state.screenTimeDeltaPercent, isNull);
    });

    test(
      'a stale yesterday is dropped on a day rollover, never relabelled',
      () async {
        // Day one: a complete yesterday is on screen.
        repo
          ..result = UsageGranted(_day(_today, ms: 7200000))
          ..days[_yesterday] = _day(_yesterday, ms: 14400000, complete: true);
        final cubit = build();
        await cubit.load();
        expect(cubit.state.yesterday, isNotNull);

        // Midnight passes. The new "yesterday" (02-09) is not complete yet, so
        // there is nothing honest to compare against.
        now = DateTime(2026, 9, 3, 0, 20);
        repo.result = UsageGranted(_day('03-09-2026', ms: 60000));

        await cubit.refreshIfStale();

        expect(
          cubit.state.yesterday,
          isNull,
          reason: 'the 01-09 record must not be relabelled as yesterday',
        );
        expect(cubit.state.yesterdayScreenTime, isNull);
      },
    );
  });

  group('refreshIfStale', () {
    test('is a no-op while the day key still matches', () async {
      repo.result = UsageGranted(_day(_today, ms: 1000));
      final cubit = build();
      await cubit.load();

      repo.throws = StateError('must not be called');
      await cubit.refreshIfStale();

      expect(cubit.state.status, InsightsStatus.granted);
    });

    test('recomputes once the day has rolled over', () async {
      repo.result = UsageGranted(_day(_today, ms: 1000));
      final cubit = build();
      await cubit.load();

      now = DateTime(2026, 9, 3, 0, 5);
      repo.result = UsageGranted(_day('03-09-2026', ms: 5000));
      await cubit.refreshIfStale();

      expect(cubit.state.stats?.dayKey, '03-09-2026');
    });

    test(
      'recomputes when access was denied, so a new grant is picked up',
      () async {
        repo.result = const UsageDenied();
        final cubit = build();
        await cubit.load();
        expect(cubit.state.status, InsightsStatus.denied);

        repo.result = UsageGranted(_day(_today, ms: 1000));
        await cubit.refreshIfStale();

        expect(cubit.state.status, InsightsStatus.granted);
      },
    );

    test('re-checks the grant within the same day, and only then', () async {
      repo.result = UsageGranted(_day(_today, ms: 1000));
      final cubit = build();
      await cubit.load();
      expect(cubit.state.status, InsightsStatus.granted);

      // Still granted: one cheap read, no recompute.
      await cubit.refreshIfStale();
      expect(repo.accessReads, 1);
      expect(cubit.state.stats?.screenTimeMs, 1000);

      // Revoked in Settings while the app was away. The day key still
      // matches, so the old check returned early and the stale numbers stayed
      // on screen as if live.
      repo
        ..access = false
        ..result = const UsageDenied();
      await cubit.refreshIfStale();
      expect(cubit.state.status, InsightsStatus.denied);
      expect(cubit.state.stats, isNull);

      // A read that did not answer is not a revocation.
      repo
        ..access = null
        ..result = UsageGranted(_day(_today, ms: 2000));
      await cubit.load();
      await cubit.refreshIfStale();
      expect(cubit.state.stats?.screenTimeMs, 2000);
    });
  });

  test('numbers are emitted before the app labels resolve', () async {
    final gate = Completer<List<InstalledApp>>();
    when(() => engine.installedApps()).thenAnswer((_) => gate.future);
    repo.result = UsageGranted(_day(_today, ms: 90000));
    final cubit = build();
    final seen = <InsightsStatus>[];
    cubit.stream.listen((s) => seen.add(s.status));

    final pending = cubit.load();
    await Future<void>.delayed(Duration.zero);

    // The screen already has real figures while the native scan is in flight.
    expect(cubit.state.status, InsightsStatus.granted);
    expect(cubit.state.stats?.screenTimeMs, 90000);

    gate.complete(const []);
    await pending;
    expect(seen, contains(InsightsStatus.granted));
  });

  test('a concurrent refresh is coalesced by the in-flight guard', () async {
    repo.result = UsageGranted(_day(_today, ms: 1000));
    final cubit = build();

    await Future.wait([cubit.load(), cubit.refresh()]);

    expect(cubit.state.status, InsightsStatus.granted);
  });
}
