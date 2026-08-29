import 'package:detoxo/features/blocking/blocking.dart';
import 'package:detoxo/features/content_counter/content_counter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The block screen's wire shapes and copy. Two invariants live here: an
/// adult hit is never named (EVO-018), and the wire token `CURIOUS` never
/// reaches a user-visible string — the label is always "Conscious".
void main() {
  group('BlockScreenPayload', () {
    test('preview defaults are a reel block on the given plan', () {
      final p = BlockScreenPayload.preview();
      expect(p.referenceType, BlockReferenceType.reel);
      expect(p.blockReason, BlockReason.plan);
      expect(p.plan, BlockingPlan.blockAll);
      expect(p.todayCount, 12);
      expect(p.allowanceLeft, -1);
      expect(p.bankMs, -1);
      expect(p.opensToday, 7);
      expect(p.packageName, 'com.instagram.android');
      expect(p.offersOpenApp, isTrue);
      expect(p.offersUnblock, isFalse);
    });

    test('a zero count previews the sample 12, a real count shows itself', () {
      expect(BlockScreenPayload.preview(todayCount: 0).todayCount, 12);
      expect(BlockScreenPayload.preview(todayCount: 3).todayCount, 3);
    });

    test('toWire carries the wire tokens and CURIOUS verbatim', () {
      final w = BlockScreenPayload.preview(plan: BlockingPlan.curious).toWire();
      expect(w['referenceType'], 'REEL');
      expect(w['blockReason'], 'PLAN');
      expect(w['plan'], 'CURIOUS');
      expect(w['allowance'], 1);
    });

    test('survives a full wire round-trip', () {
      final original = BlockScreenPayload.preview(
        plan: BlockingPlan.oneReel,
        allowance: 5,
        todayCount: 3,
      ).copyWith(offersUnblock: true, appLabel: 'Instagram');
      expect(BlockScreenPayload.fromWire(original.toWire()), original);
    });

    test('fromWire defaults on null and garbage', () {
      expect(BlockScreenPayload.fromWire(null), BlockScreenPayload.preview());
      final p = BlockScreenPayload.fromWire(const {
        'referenceType': 'nope',
        'blockReason': 'nope',
        'plan': '',
        'todayCount': 'x',
      });
      expect(p.referenceType, BlockReferenceType.reel);
      expect(p.blockReason, BlockReason.plan);
      expect(p.plan, isNull);
      expect(p.todayCount, -1);
    });

    test('an adult hit is never named and never unblockable', () {
      const p = BlockScreenPayload(
        referenceType: BlockReferenceType.website,
        referenceId: 'example.test',
        displayName: 'example.test',
        appLabel: 'Chrome',
        blockReason: BlockReason.adult,
        plan: BlockingPlan.blockAll,
        offersUnblock: true,
      );
      final s = p.sanitised();
      expect(s.displayName, '');
      expect(s.referenceId, '');
      expect(s.appLabel, 'Chrome');
      expect(s.offersUnblock, isFalse);
      expect(s.plan, isNull);
    });

    test('only a plan block keeps its plan chip', () {
      const app = BlockScreenPayload(
        referenceType: BlockReferenceType.app,
        referenceId: 'com.a',
        displayName: 'A',
        blockReason: BlockReason.appBlock,
        plan: BlockingPlan.blockAll,
      );
      expect(app.sanitised().plan, isNull);
      expect(
        BlockScreenPayload.preview().sanitised().plan,
        BlockingPlan.blockAll,
      );
    });
  });

  group('planLabel', () {
    test('maps every plan to its user-facing name', () {
      expect(planLabel(BlockingPlan.curious), 'Conscious');
      expect(planLabel(BlockingPlan.oneReel), 'One Reel');
      expect(planLabel(BlockingPlan.oneReel, allowance: 5), 'Unblock');
      expect(planLabel(BlockingPlan.blockAll), 'Block All');
      expect(planLabel(BlockingPlan.paused), 'Paused');
      expect(planLabel(null), '');
    });

    test('the wire token never reaches a label', () {
      for (final plan in [...BlockingPlan.values, null]) {
        for (final allowance in [1, 5]) {
          expect(
            planLabel(plan, allowance: allowance).toLowerCase(),
            isNot(contains('curious')),
          );
        }
      }
    });
  });

  group('BlockScreenCopy', () {
    const style = BlockScreenStyle.defaults();

    test('a Conscious reel block reads as Conscious, never curious', () {
      final copy = BlockScreenCopy.from(
        BlockScreenPayload.preview(plan: BlockingPlan.curious, todayCount: 7),
        style,
      );
      expect(copy.chip, 'Conscious');
      expect(copy.headline, 'Instagram Reels is blocked by Detoxo');
      expect(copy.reason, 'Your Conscious time bank is empty');
      expect(copy.stats, [
        '7 reels today',
        '0:00 left in your bank',
        'Instagram opened 7 times today',
      ]);
      expect(copy.buttons.map((b) => b.label), [
        'Go home',
        'Open Detoxo',
        'Back to Instagram · 5',
      ]);
      expect(copy.semanticsLabel.toLowerCase(), isNot(contains('curious')));
    });

    test(
      'the ghost exit is locked while its countdown runs, instant when off',
      () {
        final counting = BlockScreenCopy.from(
          BlockScreenPayload.preview(),
          style,
        );
        final back = counting.buttons.last;
        expect(back.label, 'Back to Instagram · 5');
        expect(back.locked, isTrue);
        expect(back.ghost, isTrue);
        expect(back.action, 'DISMISS');
        expect(counting.buttons.where((b) => b.locked).length, 1);

        final instant = BlockScreenCopy.from(
          BlockScreenPayload.preview(),
          style.copyWith(backDelaySec: 0),
        );
        expect(instant.buttons.last.label, 'Back to Instagram');
        expect(instant.buttons.last.locked, isFalse);
      },
    );

    test('the opens line follows the usage layer and its toggle', () {
      final one = BlockScreenCopy.from(
        BlockScreenPayload.preview().copyWith(opensToday: 1),
        style,
      );
      expect(one.stats.last, 'Instagram opened 1 time today');
      final unknown = BlockScreenCopy.from(
        BlockScreenPayload.preview().copyWith(opensToday: -1),
        style,
      );
      expect(unknown.stats, ['12 reels today']);
      final off = BlockScreenCopy.from(
        BlockScreenPayload.preview(),
        style.copyWith(showOpens: false),
      );
      expect(off.stats, ['12 reels today']);
    });

    test('an Unblock-5 block names the allowance', () {
      final copy = BlockScreenCopy.from(
        BlockScreenPayload.preview(plan: BlockingPlan.oneReel, allowance: 5),
        style,
      );
      expect(copy.chip, 'Unblock');
      expect(copy.reason, 'You’ve watched your 5 reels');
      expect(copy.stats[1], '0 reels left');
      final one = BlockScreenCopy.from(
        BlockScreenPayload.preview(plan: BlockingPlan.oneReel, todayCount: 1),
        style,
      );
      expect(one.chip, 'One Reel');
      expect(one.reason, 'You’ve watched your reel');
      expect(one.stats.first, '1 reel today');
    });

    test('an app block says Got it and never Go home', () {
      const p = BlockScreenPayload(
        referenceType: BlockReferenceType.app,
        referenceId: 'com.instagram.android',
        displayName: 'Instagram',
        appLabel: 'Instagram',
        blockReason: BlockReason.appBlock,
        plan: BlockingPlan.blockAll,
      );
      final copy = BlockScreenCopy.from(p.sanitised(), style);
      expect(copy.chip, '');
      expect(copy.reason, 'Locked in your App blocker');
      expect(copy.stats, isEmpty);
      expect(copy.buttons.first.label, 'Got it');
      expect(copy.buttons.first.action, 'DISMISS');
      expect(copy.buttons.map((b) => b.label), isNot(contains('Go home')));
    });

    test('an adult web block is unnamed and offers the browser back', () {
      const p = BlockScreenPayload(
        referenceType: BlockReferenceType.website,
        referenceId: 'example.test',
        displayName: 'example.test',
        appLabel: 'Chrome',
        blockReason: BlockReason.adult,
        offersUnblock: true,
      );
      final copy = BlockScreenCopy.from(p.sanitised(), style);
      expect(copy.headline, 'Adult site blocked by Detoxo');
      expect(copy.headline, isNot(contains('example.test')));
      expect(copy.reason, 'Adult content (18+)');
      expect(copy.buttons.map((b) => b.label), [
        'Go home',
        'Open Detoxo',
        'Back to Chrome · 5',
      ]);
    });

    test('showCount off drops the count line only', () {
      final copy = BlockScreenCopy.from(
        BlockScreenPayload.preview(plan: BlockingPlan.curious, todayCount: 7),
        style.copyWith(showCount: false),
      );
      expect(copy.stats, [
        '0:00 left in your bank',
        'Instagram opened 7 times today',
      ]);
    });
  });

  group('onColorFor', () {
    test('navy on the accent, white on a deep-red usage band', () {
      const navy = Color(0xFF0B1326);
      expect(onColorFor(const Color(0xFF12A594)), navy); // light accent
      expect(onColorFor(const Color(0xFF44E2CD)), navy); // dark accent
      expect(onColorFor(bandColorFor(0)), navy); // green band
      expect(onColorFor(bandColorFor(400)), Colors.white); // deep red band
    });
  });

  group('BlockScreenStyle', () {
    test('defaults are on, system theme, glass, count + opens shown, 5 s', () {
      const s = BlockScreenStyle.defaults();
      expect(s.enabled, isTrue);
      expect(s.theme, WidgetTheme.system);
      expect(s.background, WidgetBackground.glassDark);
      expect(s.showCount, isTrue);
      expect(s.showOpens, isTrue);
      expect(s.accentByUsage, isFalse);
      expect(s.backDelaySec, 5);
    });

    test('survives a wire round-trip and keeps enabled=false', () {
      const s = BlockScreenStyle(
        enabled: false,
        theme: WidgetTheme.dark,
        background: WidgetBackground.usageTint,
        showCount: false,
        showOpens: false,
        accentByUsage: true,
        backDelaySec: 0,
      );
      final w = s.toWire();
      expect(w['enabled'], isFalse);
      expect(w['background'], 'USAGE_TINT');
      expect(w['backDelaySec'], 0);
      expect(BlockScreenStyle.fromWire(w), s);
    });

    test('backDelaySec is clamped and tolerant', () {
      expect(
        BlockScreenStyle.fromWire(const {'backDelaySec': 900}).backDelaySec,
        60,
      );
      expect(
        BlockScreenStyle.fromWire(const {'backDelaySec': -3}).backDelaySec,
        0,
      );
      expect(
        BlockScreenStyle.fromWire(const {'backDelaySec': 'x'}).backDelaySec,
        5,
      );
    });

    test('fromWire defaults on null / empty / garbage', () {
      expect(
        BlockScreenStyle.fromWire(null),
        const BlockScreenStyle.defaults(),
      );
      expect(
        BlockScreenStyle.fromWire(const {}),
        const BlockScreenStyle.defaults(),
      );
      final s = BlockScreenStyle.fromWire(const {
        'enabled': 'x',
        'theme': 'weird',
      });
      expect(s.enabled, isTrue);
      expect(s.theme, WidgetTheme.system);
    });
  });
}
