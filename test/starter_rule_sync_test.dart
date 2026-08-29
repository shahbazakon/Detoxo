import 'package:detoxo/app/starter_rule_sync.dart';
import 'package:detoxo/features/limits/limits.dart';
import 'package:detoxo/features/onboarding/onboarding.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeOnboardingRepo implements OnboardingRepository {
  _FakeOnboardingRepo(this.progress);
  OnboardingProgress? progress;
  int clears = 0;

  @override
  Future<OnboardingProgress> load() async =>
      progress ?? const OnboardingProgress();
  @override
  Future<void> save(OnboardingProgress p) async => progress = p;
  @override
  Future<void> clear() async {
    clears++;
    progress = null;
  }
}

class _ThrowingRepo implements OnboardingRepository {
  @override
  Future<OnboardingProgress> load() async => throw StateError('hive gone');
  @override
  Future<void> save(OnboardingProgress p) async {}
  @override
  Future<void> clear() async {}
}

const _armed = OnboardingProgress(
  step: OnboardingStepId.permissions,
  mattersMost: MattersMost.sleep,
  platforms: {'ig_reel'},
);

void main() {
  late _FakeOnboardingRepo repo;
  late List<Rule> saved;

  setUp(() {
    repo = _FakeOnboardingRepo(_armed);
    saved = [];
  });

  /// The real `applyStarterRule`, with its two collaborators faked.
  Future<void> run({bool accept = true, bool mounted = true}) =>
      applyStarterRule(
        repo: repo,
        save: (rule) async {
          if (!accept) return false;
          saved.add(rule);
          return true;
        },
        isMounted: () => mounted,
      );

  group('which records write a rule', () {
    test("only the permissions step is onboarding's window", () {
      expect(starterRuleAction(_armed), StarterRuleAction.write);
      expect(
        starterRuleAction(
          const OnboardingProgress(step: OnboardingStepId.completed),
        ),
        StarterRuleAction.clearOrphan,
      );
      for (final step in [
        OnboardingStepId.welcome,
        OnboardingStepId.survey,
        OnboardingStepId.projection,
        OnboardingStepId.selection,
        OnboardingStepId.commitment,
      ]) {
        expect(
          starterRuleAction(OnboardingProgress(step: step)),
          StarterRuleAction.none,
          reason: '$step is a run still in progress',
        );
      }
    });

    test('an armed record writes exactly one rule and is consumed', () async {
      await run();
      expect(saved, hasLength(1));
      expect(saved.single.kind, RuleKind.schedule);
      expect(saved.single.schedule!.isOvernight, isTrue, reason: 'SLEEP');
      expect(saved.single.selection.platforms, ['ig_reel']);
      expect(repo.clears, 1);
    });

    test('an existing install never gets a rule it did not ask for', () async {
      // The upgrade path: no record at all, which reads as `welcome`.
      repo.progress = null;
      await run();
      expect(saved, isEmpty);
      expect(repo.clears, 0);
    });

    test('running twice writes only one rule', () async {
      await run();
      await run();
      expect(saved, hasLength(1), reason: 'the record was consumed');
    });

    test('a skipped survey still gets the rule its promise named', () async {
      // `mattersMost` is null when the survey is skipped. The commitment screen
      // renders the doomscroll-budget promise for that case, so the write has
      // to agree with it — it used to refuse, leaving the user with an empty
      // Rules screen and a promise the app had just made on-screen.
      repo.progress = const OnboardingProgress(
        step: OnboardingStepId.permissions,
        platforms: {'yt_shorts'},
      );
      await run();
      expect(saved, hasLength(1));
      expect(saved.single.kind, RuleKind.timeLimit);
      expect(saved.single.thresholdMs, 30 * 60000);
      expect(repo.clears, 1);
    });
  });

  group('what must NOT consume the record', () {
    test('a refused save leaves it armed for the next attempt', () async {
      await run(accept: false);
      expect(saved, isEmpty);
      expect(repo.clears, 0);
      expect(repo.progress, _armed, reason: 'still armed');
    });

    test('an unmounted teardown leaves it armed', () async {
      // `mounted` used to sit inside the same condition as the data guards, so
      // a false one skipped the write and then fell straight through to the
      // consume — the rule was never written and could never be retried.
      await run(mounted: false);
      expect(saved, isEmpty);
      expect(repo.clears, 0);
      expect(repo.progress, _armed);
    });

    test('a load failure is swallowed, never rethrown', () {
      // This runs behind the app's first real screen.
      expect(
        applyStarterRule(
          repo: _ThrowingRepo(),
          save: (_) async => true,
          isMounted: () => true,
        ),
        completes,
      );
    });
  });

  group('cleanup', () {
    test('a completed record orphaned by a crash is dropped', () async {
      // `completed` is written before `clear()`; a kill in that gap used to
      // leave the record — and the user's name — in Hive forever, because the
      // step guard short-circuited before ever reaching the clear again.
      repo.progress = const OnboardingProgress(
        step: OnboardingStepId.completed,
        name: 'Sam',
      );
      await run();
      expect(repo.clears, 1);
      expect(repo.progress, isNull);
      expect(saved, isEmpty, reason: 'the rule already exists');
    });
  });

  group('the starter rule actually enforces something', () {
    // The budget preset is what FOUR of six survey answers produce, including
    // "skip" — and `starterRule` replaces its category selection with the feeds
    // the user picked. A limit meters PACKAGES, so a feed-only limit summed 0
    // forever and could never become spent, while `_limitEntry` also dropped
    // platformIds, so it covered nothing either. Onboarding's one artifact was
    // silently inert on the most ordinary path there is.
    for (final answer in <MattersMost?>[
      null,
      MattersMost.present,
      MattersMost.mental,
      MattersMost.other,
    ]) {
      test('${answer?.name ?? 'skipped'} → a rule that can actually block', () {
        final rule = starterRule(
          mattersMost: answer,
          platforms: {'instagram_reels'},
          id: 'r1',
          nowMs: 0,
        );
        final entry = resolveSnapshot(
          rules: [rule],
          now: DateTime(2026, 9, 6, 10),
        ).snapshot.entries.single;
        expect(
          entry.platformIds,
          contains('instagram_reels'),
          reason: 'an entry that covers nothing blocks nothing',
        );
        expect(
          entry.reelTimeLimitMs,
          greaterThan(0),
          reason:
              'native meters reel time for this shape with Detoxo closed; a '
              'usageLimitMs on zero packages is measured against nothing',
        );
        expect(entry.usageLimitMs, 0);
      });
    }

    test('a limit on APPS still meters packages, and keeps its feeds', () {
      const rule = Rule(
        id: 'r1',
        name: 'Mixed',
        kind: RuleKind.timeLimit,
        createdAtMs: 0,
        selection: RuleSelection(
          apps: ['com.instagram.android'],
          platforms: ['instagram_reels'],
        ),
        thresholdMs: 30 * 60000,
      );
      final entry = resolveSnapshot(
        rules: [rule],
        now: DateTime(2026, 9, 6, 10),
      ).snapshot.entries.single;
      expect(entry.usageLimitMs, 30 * 60000);
      expect(entry.reelTimeLimitMs, 0);
      expect(
        entry.platformIds,
        contains('instagram_reels'),
        reason: 'a spent budget has to close the feeds the rule named too',
      );
    });
  });
}
