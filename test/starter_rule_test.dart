import 'package:detoxo/features/limits/limits.dart';
import 'package:detoxo/features/onboarding/domain/entities/onboarding_progress.dart';
import 'package:detoxo/features/onboarding/domain/starter_rule.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const platforms = {'ig_reel', 'yt_shorts'};

  Rule build(MattersMost matters) => starterRule(
    mattersMost: matters,
    platforms: platforms,
    id: 'starter-1',
    nowMs: 1756742400000,
  );

  group('survey → rule mapping', () {
    test('SLEEP is an overnight 22:00–07:00 schedule, every day', () {
      final rule = build(MattersMost.sleep);
      expect(rule.kind, RuleKind.schedule);
      expect(rule.schedule!.days, RuleSchedule.everyDay);
      expect(rule.schedule!.startMin, 22 * 60);
      expect(rule.schedule!.endMin, 7 * 60);
      // The overnight-wrap path: the morning slice belongs to the START day.
      expect(rule.schedule!.isOvernight, isTrue);
    });

    test('FOCUS is a Mon–Fri 09:00–17:00 schedule', () {
      final rule = build(MattersMost.focus);
      expect(rule.kind, RuleKind.schedule);
      expect(rule.schedule!.days, RuleSchedule.weekdays);
      expect(rule.schedule!.startMin, 9 * 60);
      expect(rule.schedule!.endMin, 17 * 60);
      expect(rule.schedule!.isOvernight, isFalse);
    });

    test('PRESENT, MENTAL and OTHER all get the 30 min/day time limit', () {
      for (final m in [
        MattersMost.present,
        MattersMost.mental,
        MattersMost.other,
      ]) {
        final rule = build(m);
        expect(rule.kind, RuleKind.timeLimit, reason: '$m');
        expect(rule.thresholdMs, 30 * 60000, reason: '$m');
        expect(rule.schedule, isNull, reason: '$m');
      }
    });

    test('every MattersMost value maps to something savable', () {
      for (final m in MattersMost.values) {
        expect(build(m).validate(), isNull, reason: '$m must be savable');
      }
    });
  });

  group('selection', () {
    test(
      'the rule targets the feeds the user picked, not the preset defaults',
      () {
        for (final m in MattersMost.values) {
          final rule = build(m);
          expect(rule.selection.platforms, [
            'ig_reel',
            'yt_shorts',
          ], reason: '$m');
          // The preset's category selection must NOT survive: a starter rule that
          // blocks a default taxonomy instead of the user's picks is a rule they
          // did not agree to.
          expect(rule.selection.categories, isEmpty, reason: '$m');
        }
      },
    );

    test('identity comes from the caller, never from the preset template', () {
      final rule = build(MattersMost.sleep);
      expect(rule.id, 'starter-1');
      expect(rule.createdAtMs, 1756742400000);
      expect(rule.enabled, isTrue);
    });
  });

  group('wire contract', () {
    test('a time-limit starter rule serialises lockPeriod END_OF_DAY', () {
      // M3 ships END_OF_DAY as the only lock behaviour; the plan doc asks for
      // it explicitly, so pin it here rather than assuming it stays implicit.
      final json = build(MattersMost.present).toJson();
      expect(json['timeLimit'], {
        'thresholdMs': 30 * 60000,
        'lockPeriod': 'END_OF_DAY',
      });
    });

    test('a starter rule survives a JSON round trip unchanged', () {
      for (final m in MattersMost.values) {
        final rule = build(m);
        expect(Rule.fromJson(rule.toJson()), rule, reason: '$m');
      }
    });
  });

  test('the named presets are the ones the empty state still offers', () {
    // starter_rule.dart reaches presets by name so reordering `all` cannot
    // silently change which rule a new user gets — but they must stay the
    // SAME objects the rules screen lists.
    expect(
      RulePreset.all,
      containsAll([
        RulePreset.workHours,
        RulePreset.sleep,
        RulePreset.doomscrollBudget,
      ]),
    );
  });
}
