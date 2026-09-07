import 'package:detoxo/features/analytics/analytics.dart';
import 'package:detoxo/features/analytics/presentation/widgets/by_app_section.dart';
import 'package:detoxo/features/content_counter/content_counter.dart';
import 'package:detoxo/features/usage/usage.dart';
import 'package:flutter_test/flutter_test.dart';

AppContentCount _reel(String package, int count) => AppContentCount(
  packageName: package,
  appName: package,
  displayName: '$package reels',
  iconUrl: 'assets/$package.png',
  count: count,
);

/// The By app card's pure row builder: the sort, the cap, the bar
/// normalisation and the spoken forms, reachable without a widget tree.
void main() {
  group('rowsFor', () {
    test('reels keep the counter order, carry names and icons, and speak', () {
      final rows = ByAppSection.rowsFor(
        ByAppSegment.reels,
        count: ContentCount(perAppToday: [_reel('a', 4), _reel('b', 1)]),
        blocks: const {},
      );

      expect(rows.map((r) => r.package), ['a', 'b']);
      expect(rows.first.name, 'a reels');
      expect(rows.first.iconUrl, 'assets/a.png');
      expect(rows.map((r) => r.fraction), [1.0, 0.25]);
      expect(rows.map((r) => r.spoken), ['4 reels', '1 reel']);
    });

    test('blocks are most-blocked first, bars relative to the busiest', () {
      final rows = ByAppSection.rowsFor(
        ByAppSegment.blocks,
        count: const ContentCount(),
        blocks: const {'b': 3, 'a': 9, 'c': 1},
      );

      expect(rows.map((r) => r.package), ['a', 'b', 'c']);
      expect(rows.map((r) => r.trailing), ['9', '3', '1']);
      expect(rows.map((r) => r.spoken), ['9 blocks', '3 blocks', '1 block']);
      expect(rows.last.fraction, closeTo(1 / 9, 1e-9));
      expect(rows.first.name, isNull);
    });

    test('time draws five of the stored ten, formatted', () {
      final rows = ByAppSection.rowsFor(
        ByAppSegment.time,
        count: const ContentCount(),
        blocks: const {},
        stats: DailyStats(
          dayKey: '02-09-2026',
          topApps: [
            for (var i = 10; i > 0; i--)
              AppUsage(package: 'p$i', foregroundMillis: i * 60000),
          ],
        ),
      );

      expect(rows.length, ByAppSection.visibleTimeApps);
      expect(rows.first.trailing, '10m');
      expect(rows.first.fraction, 1.0);
      expect(rows.last.fraction, 0.6);
    });

    test('an empty tally yields no rows and no division by zero', () {
      expect(
        ByAppSection.rowsFor(
          ByAppSegment.time,
          count: const ContentCount(),
          blocks: const {},
        ),
        isEmpty,
      );
      final zero = ByAppSection.rowsFor(
        ByAppSegment.blocks,
        count: const ContentCount(),
        blocks: const {'a': 0},
      );
      expect(zero.single.fraction, 0.0);
    });
  });

  test('the empty copy names a switched-off counter', () {
    expect(
      ByAppSection.emptyCopy(ByAppSegment.reels, counting: false),
      'Counting is off. Turn it on under Appearance.',
    );
    expect(
      ByAppSection.emptyCopy(ByAppSegment.reels, counting: true),
      'No reels counted yet.',
    );
    expect(
      ByAppSection.emptyCopy(ByAppSegment.blocks, counting: true),
      'No blocks yet today.',
    );
    expect(
      ByAppSection.emptyCopy(ByAppSegment.time, counting: true),
      'Nothing yet today.',
    );
  });
}
