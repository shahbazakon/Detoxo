import 'package:detoxo/features/analytics/analytics.dart';
import 'package:detoxo/features/catalog/catalog.dart';
import 'package:detoxo/features/usage/usage.dart';
import 'package:flutter_test/flutter_test.dart';

/// `computeDailyStats` is pure, so every case here is a handcrafted event list
/// and no device. These figures are what the user compares against Digital
/// Wellbeing, so the boundary and de-duplication rules are pinned, not assumed.

final DateTime _start = DateTime(2026, 9, 2);
final DateTime _end = DateTime(2026, 9, 3);

/// A real distracting package from the shipped seed (`short_form_video`).
const String _reels = 'com.instagram.android';

/// Google Drive — a real `productivity` package in the shipped seed, so "not
/// distracting" is tested against a catalogued app and not only an unknown one.
const String _drive = 'com.google.android.apps.docs';

/// Not in the seed at all — must count as screen time, never as distraction.
const String _unknown = 'com.example.unknown';

UsageEvent _fg(String pkg, int hour, {int minute = 0}) => UsageEvent(
  package: pkg,
  type: UsageEventType.moveToForeground,
  timestampMillis: DateTime(2026, 9, 2, hour, minute).millisecondsSinceEpoch,
);

UsageEvent _wake(int hour, {int minute = 0}) => UsageEvent(
  package: 'android',
  type: UsageEventType.screenInteractive,
  timestampMillis: DateTime(2026, 9, 2, hour, minute).millisecondsSinceEpoch,
);

AppUsage _use(String pkg, int minutes) =>
    AppUsage(package: pkg, foregroundMillis: minutes * 60000);

DailyStats _compute({
  List<AppUsage> usage = const [],
  List<UsageEvent> events = const [],
  int reelCount = 0,
  bool complete = false,
  DateTime? start,
  DateTime? end,
}) => computeDailyStats(
  usage: usage,
  events: events,
  catalog: Catalog.bundled,
  start: start ?? _start,
  end: end ?? _end,
  reelCount: reelCount,
  complete: complete,
);

void main() {
  group('computeDailyStats — degenerate input', () {
    test('empty input is a zero day, not a null-deref', () {
      final s = _compute();

      expect(s.screenTimeMs, 0);
      expect(s.distractionMs, 0);
      expect(s.distractionOpens, 0);
      expect(s.pickupCount, 0);
      expect(s.contextSwitches, 0);
      expect(s.topApps, isEmpty);
      expect(s.isEmpty, isTrue);
    });

    test('no pickup events leaves both timestamps null, never midnight', () {
      final s = _compute(events: [_fg(_reels, 9)]);

      expect(s.firstPickupMs, isNull);
      expect(s.lastPickupMs, isNull);
      expect(s.firstPickup, isNull);
      expect(s.lastPickup, isNull);
    });

    test('day key is dd-MM-yyyy, taken from the window start', () {
      expect(_compute().dayKey, '02-09-2026');
    });

    test('a zero-foreground app never reaches topApps or screen time', () {
      final s = _compute(
        usage: [
          const AppUsage(package: _reels, foregroundMillis: 0),
          _use(_drive, 5),
        ],
      );

      expect(s.topApps.map((a) => a.package), [_drive]);
      expect(s.screenTimeMs, 5 * 60000);
      expect(s.distractionMs, 0);
    });
  });

  group('computeDailyStats — context switches', () {
    test('a single foreground event is not a switch', () {
      expect(_compute(events: [_fg(_reels, 9)]).contextSwitches, 0);
    });

    test('repeated foregrounds of the same app are not switches', () {
      final s = _compute(
        events: [_fg(_reels, 9), _fg(_reels, 10), _fg(_reels, 11)],
      );

      expect(s.contextSwitches, 0);
      expect(s.distractionOpens, 1);
    });

    test('A, A, B, A is two switches and two opens of A', () {
      final s = _compute(
        events: [
          _fg(_reels, 9),
          _fg(_reels, 10),
          _fg(_drive, 11),
          _fg(_reels, 12),
        ],
      );

      expect(s.contextSwitches, 2);
      // Transition semantics: A opened twice, not three times.
      expect(s.distractionOpens, 2);
    });

    test('interleaved pickups do not break the foreground chain', () {
      final s = _compute(
        events: [_fg(_reels, 9), _wake(10), _fg(_reels, 11), _fg(_drive, 12)],
      );

      // The wake between two Instagram foregrounds must not mint a second open.
      expect(s.distractionOpens, 1);
      expect(s.contextSwitches, 1);
    });

    test('events arriving out of order are sorted, never counted negative', () {
      final ordered = _compute(
        events: [_fg(_reels, 9), _fg(_drive, 10), _fg(_reels, 11)],
      );
      final shuffled = _compute(
        events: [_fg(_reels, 11), _fg(_reels, 9), _fg(_drive, 10)],
      );

      expect(shuffled.contextSwitches, ordered.contextSwitches);
      expect(shuffled.distractionOpens, ordered.distractionOpens);
      expect(shuffled.contextSwitches, greaterThanOrEqualTo(0));
    });
  });

  group('computeDailyStats — pickups', () {
    test('counts wakes and reports the first and last of the day', () {
      final s = _compute(events: [_wake(7, minute: 30), _wake(12), _wake(23)]);

      expect(s.pickupCount, 3);
      expect(s.firstPickup, DateTime(2026, 9, 2, 7, 30));
      expect(s.lastPickup, DateTime(2026, 9, 2, 23));
    });

    test('first and last come from time order, not arrival order', () {
      final s = _compute(events: [_wake(23), _wake(7), _wake(12)]);

      expect(s.firstPickup, DateTime(2026, 9, 2, 7));
      expect(s.lastPickup, DateTime(2026, 9, 2, 23));
    });
  });

  group('computeDailyStats — window boundaries', () {
    test('an event exactly at start is kept; exactly at end is dropped', () {
      final atStart = UsageEvent(
        package: 'android',
        type: UsageEventType.screenInteractive,
        timestampMillis: _start.millisecondsSinceEpoch,
      );
      final atEnd = UsageEvent(
        package: 'android',
        type: UsageEventType.screenInteractive,
        timestampMillis: _end.millisecondsSinceEpoch,
      );

      expect(_compute(events: [atStart, atEnd]).pickupCount, 1);
    });

    test('events outside the window are dropped entirely', () {
      final yesterday = UsageEvent(
        package: _reels,
        type: UsageEventType.moveToForeground,
        timestampMillis: DateTime(2026, 9, 1, 23).millisecondsSinceEpoch,
      );

      final s = _compute(events: [yesterday, _fg(_drive, 9)]);

      expect(s.distractionOpens, 0);
      expect(s.contextSwitches, 0);
    });
  });

  group('computeDailyStats — catalog split', () {
    test('distraction is the distracting slice of screen time', () {
      final s = _compute(usage: [_use(_reels, 90), _use(_drive, 30)]);

      expect(s.screenTimeMs, 120 * 60000);
      expect(s.distractionMs, 90 * 60000);
      expect(s.distractionShare, closeTo(0.75, 0.0001));
    });

    test('an uncatalogued app is screen time but never distraction', () {
      final s = _compute(usage: [_use(_unknown, 60)]);

      expect(s.screenTimeMs, 60 * 60000);
      expect(s.distractionMs, 0);
      expect(s.distractionShare, 0);
    });

    test('distractionShare is 0 on a day with no screen time', () {
      expect(_compute().distractionShare, 0);
    });

    test('topApps is descending and capped at ten', () {
      final s = _compute(
        usage: [for (var i = 0; i < 14; i++) _use('pkg.$i', i + 1)],
      );

      expect(s.topApps.length, kTopAppsCap);
      // The ten longest, longest first — the four smallest are dropped.
      expect(
        s.topApps.map((a) => a.package),
        orderedEquals([for (var i = 13; i >= 4; i--) 'pkg.$i']),
      );
    });
  });

  group('computeDailyStats — passthrough fields', () {
    test('reel count and completeness are carried, not derived', () {
      final s = _compute(reelCount: 96, complete: true);

      expect(s.reelCount, 96);
      expect(s.complete, isTrue);
      expect(s.isEmpty, isFalse, reason: 'reels alone make the day non-empty');
    });

    test('a record survives a JSON round trip unchanged', () {
      final s = _compute(
        usage: [_use(_reels, 70), _use(_drive, 20)],
        events: [_fg(_reels, 9), _fg(_drive, 10), _wake(7), _wake(22)],
        reelCount: 96,
        complete: true,
      );

      expect(DailyStats.fromJson(s.dayKey, s.toJson()), s);
    });

    test('a partial document reads as zeros, never as a throw', () {
      final s = DailyStats.fromJson('02-09-2026', const {'screenTimeMs': 10});

      expect(s.screenTimeMs, 10);
      expect(s.pickupCount, 0);
      expect(s.topApps, isEmpty);
      expect(s.firstPickupMs, isNull);
      expect(s.complete, isFalse);
    });

    test('wrong values are coerced, not only wrong types', () {
      // Negative durations floor at zero; topApps is re-sorted on read, so
      // the screen's "first is busiest" assumption holds for any document.
      final s = DailyStats.fromJson('02-09-2026', const {
        'screenTimeMs': -5,
        'distractionMs': -1,
        'topApps': [
          {'package': 'pkg.small', 'ms': 10},
          {'package': 'pkg.big', 'ms': 30},
          {'package': 'pkg.negative', 'ms': -20},
        ],
      });

      expect(s.screenTimeMs, 0);
      expect(s.distractionMs, 0);
      expect(s.topApps.map((a) => a.package), [
        'pkg.big',
        'pkg.small',
        'pkg.negative',
      ]);
      expect(s.topApps.last.foregroundMillis, 0);
    });
  });

  group('computeDailyStats — window bounds on usage rows', () {
    test('a row longer than the window is clipped to it', () {
      // `queryAndAggregateUsageStats` hands back bucket totals that are not
      // clipped to the window: at 00:10 the "day" bucket can still carry
      // most of yesterday, which used to persist as a five-hour "today".
      final s = _compute(
        usage: [_use(_reels, 300)],
        end: DateTime(2026, 9, 2, 0, 10),
      );

      expect(s.screenTimeMs, 10 * 60000);
      expect(s.distractionMs, 10 * 60000);
      expect(s.topApps.single.foregroundMillis, 10 * 60000);
    });

    test('rows inside the window are untouched', () {
      final s = _compute(usage: [_use(_reels, 70), _use(_drive, 20)]);

      expect(s.screenTimeMs, 90 * 60000);
      expect(s.topApps.first.foregroundMillis, 70 * 60000);
    });
  });
}
