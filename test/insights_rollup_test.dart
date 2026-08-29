import 'dart:convert';

import 'package:detoxo/core/storage/local_store.dart';
import 'package:detoxo/features/analytics/analytics.dart';
import 'package:detoxo/features/analytics/insights/data/repositories/insights_repository_impl.dart';
import 'package:detoxo/features/content_counter/content_counter.dart';
import 'package:detoxo/features/protected_apps/protected_apps.dart';
import 'package:detoxo/features/usage/usage.dart';
import 'package:flutter_test/flutter_test.dart';

/// The rollup store's contract: 90-day retention, an honest denied state, and
/// day keys that never drift from `daySignature`'s `dd-MM-yyyy`.

/// In-memory [LocalStore] (no Hive / secure storage) for repository tests.
class _FakeStore implements LocalStore {
  final Map<String, String> values = {};

  @override
  String? read(String key) => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} not used by insights');
}

/// A usage layer with pinned answers, so grant handling is tested without a
/// device and without mocktail's `when` ceremony for two methods.
class _FakeUsage implements UsageRepository {
  _FakeUsage({this.usage = const [], this.events = const [], this.result});

  List<AppUsage> usage;
  List<UsageEvent> events;

  /// When set, both queries answer with this instead of granting.
  UsageQueryResult<Never>? result;

  int appUsageCalls = 0;
  int eventCalls = 0;

  @override
  Future<bool?> hasAccess() async => result == null;

  @override
  Future<UsageQueryResult<List<AppUsage>>> queryAppUsage(
    DateTime start,
    DateTime end,
  ) async {
    appUsageCalls++;
    return result ?? UsageGranted(usage);
  }

  @override
  Future<UsageQueryResult<List<UsageEvent>>> queryUsageEvents(
    DateTime start,
    DateTime end,
  ) async {
    eventCalls++;
    return result ?? UsageGranted(events);
  }
}

class _FakeCounter implements ContentCounterRepository {
  _FakeCounter({this.today = 0, this.fail = false});

  int today;
  bool fail;

  @override
  Future<ContentCount> current() async {
    if (fail) throw StateError('engine down');
    return ContentCount(today: today, total: today);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} not used by insights');
}

/// The user's own protected additions; the bundled catalog is always on top.
class _FakeProtected implements ProtectedAppsRepository {
  _FakeProtected([this.apps = const []]);

  List<ProtectedApp> apps;
  bool fail = false;

  @override
  Future<List<ProtectedApp>> load() async {
    if (fail) throw StateError('protected store unreadable');
    return apps;
  }

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnsupportedError('${i.memberName} not used by insights');
}

final DateTime _now = DateTime(2026, 9, 2, 14, 30);
const String _todayKey = '02-09-2026';
const String _yesterdayKey = '01-09-2026';
const String _reels = 'com.instagram.android';

InsightsRepositoryImpl _repo({
  required _FakeStore store,
  _FakeUsage? usage,
  _FakeCounter? counter,
  _FakeProtected? protected,
  DateTime? now,
}) => InsightsRepositoryImpl(
  usage ?? _FakeUsage(),
  counter ?? _FakeCounter(),
  protected ?? _FakeProtected(),
  store,
  clock: () => now ?? _now,
);

Map<String, dynamic> _days(_FakeStore store) =>
    (jsonDecode(store.values[StoreKeys.usageDaily]!) as Map)['days']
        as Map<String, dynamic>;

void main() {
  group('today()', () {
    test('computes, caches and marks the current day incomplete', () async {
      final store = _FakeStore();
      final usage = _FakeUsage(
        usage: const [AppUsage(package: _reels, foregroundMillis: 600000)],
        events: [
          UsageEvent(
            package: _reels,
            type: UsageEventType.moveToForeground,
            timestampMillis: DateTime(2026, 9, 2, 9).millisecondsSinceEpoch,
          ),
        ],
      );

      final result = await _repo(
        store: store,
        usage: usage,
        counter: _FakeCounter(today: 42),
      ).today();

      expect(result, isA<UsageGranted<DailyStats>>());
      final stats = result.dataOrNull!;
      expect(stats.dayKey, _todayKey);
      expect(stats.screenTimeMs, 600000);
      expect(stats.distractionMs, 600000);
      expect(stats.reelCount, 42);
      expect(stats.complete, isFalse, reason: 'today is still running');
      expect(_days(store)[_todayKey], isNotNull);
    });

    test('backfills yesterday once, as a complete day', () async {
      final store = _FakeStore();
      final usage = _FakeUsage(
        usage: const [AppUsage(package: _reels, foregroundMillis: 1000)],
      );

      await _repo(store: store, usage: usage).today();

      final days = _days(store);
      expect(days.keys, containsAll([_todayKey, _yesterdayKey]));
      expect((days[_yesterdayKey] as Map)['complete'], isTrue);
      expect((days[_todayKey] as Map)['complete'], isFalse);
      // Two windows queried: today and yesterday.
      expect(usage.appUsageCalls, 2);

      // A second run must not recompute a day already stored as complete.
      usage.appUsageCalls = 0;
      await _repo(store: store, usage: usage).today();
      expect(usage.appUsageCalls, 1);
    });

    test('every persisted key is dd-MM-yyyy, never yyyy-MM-dd', () async {
      final store = _FakeStore();
      await _repo(store: store).today();

      for (final key in _days(store).keys) {
        expect(key, matches(RegExp(r'^\d{2}-\d{2}-\d{4}$')));
      }
    });

    test('a backwards clock never downgrades a finished day', () async {
      final store = _FakeStore();
      final usage = _FakeUsage(
        usage: const [AppUsage(package: _reels, foregroundMillis: 3600000)],
      );
      // Live through 02-09 and let 01-09 be backfilled as finished.
      await _repo(store: store, usage: usage).today();
      final finished = _days(store)[_yesterdayKey]! as Map;
      expect(finished['complete'], isTrue);

      // The user sets the device date back a day and opens the tab: today()
      // now recomputes 01-09 over a partial window.
      usage.usage = const [AppUsage(package: _reels, foregroundMillis: 60000)];
      await _repo(
        store: store,
        usage: usage,
        now: DateTime(2026, 9, 1, 0, 20),
      ).today();

      final after = _days(store)[_yesterdayKey]! as Map;
      expect(
        after['complete'],
        isTrue,
        reason: 'a partial recompute must not clobber a finished day',
      );
      expect(after['screenTimeMs'], finished['screenTimeMs']);
    });

    test('at exactly midnight a missing grant still shows as denied', () async {
      // The one EVO-014 hole in the fast path: answering a confident 0m to
      // someone who never granted Usage Access.
      final result = await _repo(
        store: _FakeStore(),
        usage: _FakeUsage(result: const UsageDenied()),
        now: DateTime(2026, 9, 2),
      ).today();

      expect(result, isA<UsageDenied<DailyStats>>());
    });

    test(
      'at exactly midnight it answers a zero day without querying',
      () async {
        final store = _FakeStore();
        final usage = _FakeUsage();

        final result = await _repo(
          store: store,
          usage: usage,
          now: DateTime(2026, 9, 2),
        ).today();

        expect(result.dataOrNull!.screenTimeMs, 0);
        expect(
          usage.appUsageCalls,
          0,
          reason: 'an empty window answers nothing',
        );
      },
    );

    test('a reel-count failure costs the count, not the screen', () async {
      final store = _FakeStore();

      final result = await _repo(
        store: store,
        usage: _FakeUsage(
          usage: const [AppUsage(package: _reels, foregroundMillis: 5000)],
        ),
        counter: _FakeCounter(fail: true),
      ).today();

      expect(result.dataOrNull!.reelCount, 0);
      expect(result.dataOrNull!.screenTimeMs, 5000);
    });
  });

  group('today() — grant handling (EVO-014)', () {
    test('denied propagates as denied, never as an empty day', () async {
      final store = _FakeStore();

      final result = await _repo(
        store: store,
        usage: _FakeUsage(result: const UsageDenied()),
      ).today();

      expect(result, isA<UsageDenied<DailyStats>>());
      expect(result.dataOrNull, isNull);
      expect(store.values[StoreKeys.usageDaily], isNull);
    });

    test('denied never falls back to a cached day', () async {
      final store = _FakeStore();
      // Seed a real record for today, then revoke access.
      await _repo(
        store: store,
        usage: _FakeUsage(
          usage: const [AppUsage(package: _reels, foregroundMillis: 999)],
        ),
      ).today();

      final result = await _repo(
        store: store,
        usage: _FakeUsage(result: const UsageDenied()),
      ).today();

      expect(result, isA<UsageDenied<DailyStats>>());
    });

    test('unavailable with a cached today serves the cached record', () async {
      final store = _FakeStore();
      await _repo(
        store: store,
        usage: _FakeUsage(
          usage: const [AppUsage(package: _reels, foregroundMillis: 777)],
        ),
      ).today();

      final result = await _repo(
        store: store,
        usage: _FakeUsage(result: const UsageUnavailable()),
      ).today();

      expect(result.dataOrNull?.screenTimeMs, 777);
    });

    test('unavailable with no cache stays unavailable', () async {
      final result = await _repo(
        store: _FakeStore(),
        usage: _FakeUsage(result: const UsageUnavailable()),
      ).today();

      expect(result, isA<UsageUnavailable<DailyStats>>());
      expect(result.dataOrNull, isNull);
    });
  });

  group('protected apps are never named (doc 24 §6)', () {
    /// A real catalog entry — a UPI app the user expects Detoxo to ignore.
    const upi = 'com.phonepe.app';

    test(
      'a catalog-protected app is kept out of topApps and the store',
      () async {
        final store = _FakeStore();
        final result = await _repo(
          store: store,
          usage: _FakeUsage(
            usage: const [
              AppUsage(package: upi, foregroundMillis: 2460000),
              AppUsage(package: _reels, foregroundMillis: 600000),
            ],
          ),
        ).today();

        final stats = result.dataOrNull!;
        expect(stats.topApps.map((a) => a.package), [_reels]);
        // The promise is about the persisted document too, not only the screen.
        expect(jsonEncode(_days(store)), isNot(contains(upi)));
      },
    );

    test(
      'its time still counts toward the aggregate, so the day is honest',
      () async {
        final result = await _repo(
          store: _FakeStore(),
          usage: _FakeUsage(
            usage: const [
              AppUsage(package: upi, foregroundMillis: 2460000),
              AppUsage(package: _reels, foregroundMillis: 600000),
            ],
          ),
        ).today();

        // Hiding the row must not make the total disagree with Digital Wellbeing.
        expect(result.dataOrNull!.screenTimeMs, 2460000 + 600000);
      },
    );

    test("a user's own addition is excluded too", () async {
      const mine = 'com.example.diary';
      final result = await _repo(
        store: _FakeStore(),
        usage: _FakeUsage(
          usage: const [
            AppUsage(package: mine, foregroundMillis: 900000),
            AppUsage(package: _reels, foregroundMillis: 600000),
          ],
        ),
        protected: _FakeProtected(const [
          ProtectedApp(packageName: mine, appName: 'Diary'),
        ]),
      ).today();

      expect(result.dataOrNull!.topApps.map((a) => a.package), [_reels]);
    });

    test('an unreadable protected store still hides the catalog', () async {
      final result = await _repo(
        store: _FakeStore(),
        usage: _FakeUsage(
          usage: const [
            AppUsage(package: upi, foregroundMillis: 2460000),
            AppUsage(package: _reels, foregroundMillis: 600000),
          ],
        ),
        protected: _FakeProtected()..fail = true,
      ).today();

      expect(result.dataOrNull!.topApps.map((a) => a.package), [_reels]);
    });
  });

  group('retention', () {
    test('91 days prune to exactly 90, dropping the oldest', () async {
      final store = _FakeStore();
      // 91 consecutive days ending yesterday, so today's write pushes past cap.
      final seeded = <String, dynamic>{
        for (var i = 1; i <= 91; i++)
          _key(DateTime(2026, 9, 2).subtract(Duration(days: i))):
              const DailyStats(dayKey: 'x', screenTimeMs: 1).toJson(),
      };
      store.values[StoreKeys.usageDaily] = jsonEncode({'days': seeded});

      await _repo(store: store).today();

      final days = _days(store);
      expect(days.length, InsightsRepositoryImpl.maxDays);
      expect(days.containsKey(_todayKey), isTrue, reason: 'newest is kept');
      // The oldest seeded day (91 days back) is gone.
      expect(
        days.containsKey(
          _key(DateTime(2026, 9, 2).subtract(const Duration(days: 91))),
        ),
        isFalse,
      );
    });

    test('pruning is chronological, not insertion-ordered', () async {
      final store = _FakeStore();
      // Insert newest first so insertion order disagrees with day order.
      final seeded = <String, dynamic>{
        for (var i = 95; i >= 1; i--)
          _key(DateTime(2026, 9, 2).subtract(Duration(days: i))):
              const DailyStats(dayKey: 'x').toJson(),
      };
      store.values[StoreKeys.usageDaily] = jsonEncode({'days': seeded});

      await _repo(store: store).today();

      final kept = _days(store).keys.toList();
      expect(kept.length, InsightsRepositoryImpl.maxDays);
      // The most recent days survived; the 90-days-back one did not.
      expect(kept, contains(_yesterdayKey));
      expect(
        kept,
        isNot(
          contains(
            _key(DateTime(2026, 9, 2).subtract(const Duration(days: 95))),
          ),
        ),
      );
    });
  });

  group('corrupt storage', () {
    test('a corrupt blob is treated as empty, not thrown', () async {
      final store = _FakeStore()
        ..values[StoreKeys.usageDaily] = '{not json at all';

      final result = await _repo(store: store).today();

      expect(result, isA<UsageGranted<DailyStats>>());
      expect(_days(store).containsKey(_todayKey), isTrue);
    });

    test('a well-formed blob with the wrong shape reads as empty', () {
      final store = _FakeStore()
        ..values[StoreKeys.usageDaily] = jsonEncode({'days': 'nonsense'});

      expect(_repo(store: store).cached(_todayKey), isNull);
    });

    test('cached() returns null for an unknown day', () {
      expect(_repo(store: _FakeStore()).cached('31-12-1999'), isNull);
    });
  });
}

/// Local `dd-MM-yyyy` key, matching `daySignature` without importing it — so a
/// change to the format breaks this test loudly instead of silently agreeing.
String _key(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-${d.year}';
