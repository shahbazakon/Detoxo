import 'package:detoxo/features/blocking/blocking.dart';
import 'package:detoxo/features/catalog/catalog.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Dart half of the soft nudge (M7): the three settings fields and the
/// derived watch list. The dwell machine itself is native and covered by
/// `android/app/src/test/kotlin/.../NudgeTrackerTest.kt`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppSettings nudge fields', () {
    test('default to off, five minutes, four a day', () {
      const s = AppSettings();
      expect(s.nudgeEnabled, isFalse);
      expect(s.nudgeThresholdMinutes, 5);
      expect(s.nudgeDailyCap, 4);
    });

    test('round-trip through JSON', () {
      const s = AppSettings(
        nudgeEnabled: true,
        nudgeThresholdMinutes: 15,
        nudgeDailyCap: 10,
      );
      final back = AppSettings.fromJson(s.toJson());
      expect(back.nudgeEnabled, isTrue);
      expect(back.nudgeThresholdMinutes, 15);
      expect(back.nudgeDailyCap, 10);
      expect(back, s);
    });

    test('settings persisted before M7 read as off, not as broken', () {
      // An upgrade's stored blob has none of these keys.
      final legacy = AppSettings.fromJson(const {'vibrationEnabled': false});
      expect(legacy.nudgeEnabled, isFalse);
      expect(legacy.nudgeThresholdMinutes, 5);
      expect(legacy.nudgeDailyCap, 4);
    });

    test('copyWith carries each field independently', () {
      const s = AppSettings();
      expect(s.copyWith(nudgeEnabled: true).nudgeThresholdMinutes, 5);
      expect(s.copyWith(nudgeThresholdMinutes: 30).nudgeEnabled, isFalse);
      expect(s.copyWith(nudgeDailyCap: 2).nudgeDailyCap, 2);
    });
  });

  group('nudge watch list', () {
    test("is the catalog's distracting packages, and is not empty", () {
      final packages = nudgePackages();
      expect(packages, isNotEmpty);
      for (final pkg in packages) {
        expect(
          Catalog.bundled.behaviorForPackage(pkg),
          AppBehavior.distracting,
          reason: pkg,
        );
      }
    });

    test('excludes productive and neutral apps', () {
      final packages = nudgePackages().toSet();
      for (final category in Catalog.bundled.categories) {
        if (category.behavior == AppBehavior.distracting) continue;
        for (final pkg in Catalog.bundled.packagesIn(category.id)) {
          expect(packages, isNot(contains(pkg)), reason: pkg);
        }
      }
    });

    test('nudging is not blocking: the list is derived, never curated', () {
      // packagesWithBehavior must agree with the per-package lookup, which is
      // what the rest of the app already trusts.
      final derived = Catalog.bundled
          .packagesWithBehavior(AppBehavior.productive)
          .toSet();
      final scanned = <String>{
        for (final c in Catalog.bundled.categories)
          if (c.behavior == AppBehavior.productive)
            ...Catalog.bundled.packagesIn(c.id),
      };
      expect(derived, scanned);
    });
  });
}
