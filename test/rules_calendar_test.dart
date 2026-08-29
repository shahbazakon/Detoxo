import 'package:detoxo/features/limits/limits.dart';
import 'package:detoxo/features/usage/usage.dart';
import 'package:flutter_test/flutter_test.dart';

// 2026-09-02 is a Wednesday; 2026-09-04 Friday; 2026-09-05 Saturday;
// 2026-09-06 Sunday. 2026-03-08 (US spring-forward) and 2026-11-01 (fall-back)
// are both Sundays.
void main() {
  const nineToFive = RuleSchedule(
    days: RuleSchedule.weekdays,
    startMin: 9 * 60,
    endMin: 17 * 60,
  );
  const fridayNight = RuleSchedule(
    days: {5},
    startMin: 22 * 60,
    endMin: 6 * 60,
  );

  group('inWeeklyWindow', () {
    bool inNineToFive(DateTime t) => inWeeklyWindow(
      nineToFive.days,
      nineToFive.startMin,
      nineToFive.endMin,
      t,
    );
    bool inFridayNight(DateTime t) => inWeeklyWindow(
      fridayNight.days,
      fridayNight.startMin,
      fridayNight.endMin,
      t,
    );

    test('a normal window is [start, end) on a listed day', () {
      expect(inNineToFive(DateTime(2026, 9, 2, 9)), isTrue);
      expect(inNineToFive(DateTime(2026, 9, 2, 12, 30)), isTrue);
      expect(inNineToFive(DateTime(2026, 9, 2, 16, 59)), isTrue);
      expect(inNineToFive(DateTime(2026, 9, 2, 17)), isFalse, reason: 'end');
      expect(inNineToFive(DateTime(2026, 9, 2, 8, 59)), isFalse);
      expect(inNineToFive(DateTime(2026, 9, 5, 12)), isFalse, reason: 'Sat');
    });

    test(
      'an overnight window attributes the morning slice to the START day',
      () {
        expect(
          inFridayNight(DateTime(2026, 9, 4, 23)),
          isTrue,
          reason: 'Fri 23:00',
        );
        expect(
          inFridayNight(DateTime(2026, 9, 5, 2)),
          isTrue,
          reason: "Sat 02:00 belongs to Friday's window",
        );
        expect(
          inFridayNight(DateTime(2026, 9, 5, 6)),
          isFalse,
          reason: 'Sat 06:00',
        );
        expect(
          inFridayNight(DateTime(2026, 9, 4, 2)),
          isFalse,
          reason: 'Fri 02:00 is Thursday night',
        );
        expect(
          inFridayNight(DateTime(2026, 9, 6, 2)),
          isFalse,
          reason: 'Sun 02:00',
        );
        expect(
          inFridayNight(DateTime(2026, 9, 5, 23)),
          isFalse,
          reason: 'Sat 23:00',
        );
      },
    );

    test('start == end never matches', () {
      expect(
        inWeeklyWindow(
          RuleSchedule.everyDay,
          600,
          600,
          DateTime(2026, 9, 2, 10),
        ),
        isFalse,
      );
    });
  });

  group('scheduleWindows', () {
    test(
      'Mon–Fri from a Sunday yields the five weekday windows at 09/17 local',
      () {
        final windows = scheduleWindows(nineToFive, DateTime(2026, 9, 6, 12));
        expect(windows.length, 5);
        for (var i = 0; i < 5; i++) {
          final start = DateTime.fromMillisecondsSinceEpoch(windows[i].startMs);
          final end = DateTime.fromMillisecondsSinceEpoch(windows[i].endMs);
          expect(start.day, 7 + i);
          expect((start.hour, start.minute), (9, 0));
          expect((end.hour, end.minute), (17, 0));
          expect(start.weekday, i + 1);
        }
      },
    );

    test(
      'an open window is kept, a finished one dropped, the horizon wraps',
      () {
        // Wed 10:00: Wed (open), Thu, Fri, then Mon, Tue of next week.
        final windows = scheduleWindows(nineToFive, DateTime(2026, 9, 2, 10));
        expect(windows.length, 5);
        final first = windows.first;
        expect(
          first.contains(DateTime(2026, 9, 2, 10).millisecondsSinceEpoch),
          isTrue,
        );
        expect(
          DateTime.fromMillisecondsSinceEpoch(windows.last.startMs).day,
          8,
          reason: 'Tue 8 Sep closes the 7-day horizon',
        );
      },
    );

    test(
      'an overnight window that began yesterday is included and crosses midnight',
      () {
        final windows = scheduleWindows(fridayNight, DateTime(2026, 9, 5, 2));
        expect(windows.length, 2, reason: 'this Friday night and next');
        final start = DateTime.fromMillisecondsSinceEpoch(
          windows.first.startMs,
        );
        final end = DateTime.fromMillisecondsSinceEpoch(windows.first.endMs);
        expect((start.day, start.hour), (4, 22));
        expect((end.day, end.hour), (5, 6));
        expect(
          windows.first.contains(
            DateTime(2026, 9, 5, 2).millisecondsSinceEpoch,
          ),
          isTrue,
        );
      },
    );

    test(
      'DST transition days keep local wall times (calendar, not 24 h, arithmetic)',
      () {
        for (final from in [
          DateTime(2026, 3, 7, 8),
          DateTime(2026, 10, 31, 8),
        ]) {
          final windows = scheduleWindows(
            const RuleSchedule(
              days: RuleSchedule.everyDay,
              startMin: 9 * 60,
              endMin: 17 * 60,
            ),
            from,
            horizonDays: 3,
          );
          expect(windows.length, 3);
          for (var i = 0; i < windows.length; i++) {
            final start = DateTime.fromMillisecondsSinceEpoch(
              windows[i].startMs,
            );
            final end = DateTime.fromMillisecondsSinceEpoch(windows[i].endMs);
            expect(
              start.hour,
              9,
              reason: 'start lands on 09:00 local on ${start.day}',
            );
            expect(
              end.hour,
              17,
              reason: 'end lands on 17:00 local on ${end.day}',
            );
            expect(
              start.day,
              DateTime(from.year, from.month, from.day + i).day,
            );
            if (i > 0) {
              // Consecutive days are 23, 24 or 25 hours apart on a DST machine.
              final gap = windows[i].startMs - windows[i - 1].startMs;
              expect((gap - 86_400_000).abs(), lessThanOrEqualTo(3_600_000));
            }
          }
        }
      },
    );

    test('start == end or no days yields nothing', () {
      expect(
        scheduleWindows(
          const RuleSchedule(
            days: RuleSchedule.everyDay,
            startMin: 600,
            endMin: 600,
          ),
          DateTime(2026, 9, 2),
        ),
        isEmpty,
      );
      expect(
        scheduleWindows(
          const RuleSchedule(days: {}, startMin: 600, endMin: 700),
          DateTime(2026, 9, 2),
        ),
        isEmpty,
      );
    });
  });

  test('todayInterval is local midnight to the next local midnight', () {
    final (start, end) = todayInterval(DateTime(2026, 3, 8, 13, 45));
    expect(start, DateTime(2026, 3, 8));
    expect(end, DateTime(2026, 3, 9));
    expect(end.difference(start).inHours, inInclusiveRange(23, 25));
  });

  test('countOpens counts foreground transitions only', () {
    UsageEvent fg(String pkg, int t) => UsageEvent(
      package: pkg,
      type: UsageEventType.moveToForeground,
      timestampMillis: t,
    );
    final opens = countOpens([
      fg('com.a', 1),
      fg('com.a', 2), // the same app resuming its next activity
      fg('com.b', 3),
      const UsageEvent(
        package: 'com.a',
        type: UsageEventType.screenInteractive,
        timestampMillis: 4,
      ),
      fg('com.a', 5),
      fg('com.launcher', 6),
      fg('com.a', 7),
    ]);
    expect(opens['com.a'], 3);
    expect(opens['com.b'], 1);
    expect(opens['com.c'], isNull);
    expect(countOpens(const []), isEmpty);
  });

  test('RuleSchedule HH:mm round-trips and tolerates garbage', () {
    expect(RuleSchedule.parseHHmm('09:05'), 545);
    expect(RuleSchedule.formatHHmm(545), '09:05');
    expect(RuleSchedule.parseHHmm('nope'), 0);
    expect(RuleSchedule.parseHHmm('25:99'), 23 * 60 + 59);
    final json = fridayNight.toJson();
    expect(json['type'], 'REPEATING');
    expect(RuleSchedule.fromJson(json), fridayNight);
  });
}
