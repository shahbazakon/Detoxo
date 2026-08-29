// M8 part B — the rationed escape: the ledger, the rolling-window quota, the
// validations that must all run before anything is written, and the locked-rule
// invariant enforced in the domain rather than in the UI.

import 'dart:convert';

import 'package:detoxo/features/blocking/shared/domain/repositories/blocking_repositories.dart';
import 'package:detoxo/features/limits/limits.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

final _now = DateTime(2026, 9, 6, 10);
int get _nowMs => _now.millisecondsSinceEpoch;
const _week = 7 * 24 * 60 * 60 * 1000;

BypassEntry _override({int agoMs = 0, String ruleId = 'r1'}) => BypassEntry(
  kind: BypassKind.override,
  atMs: _nowMs - agoMs,
  untilMs: _nowMs - agoMs + 30 * 60000,
  ruleId: ruleId,
  reason: OverrideReason.scheduleChange,
);

Rule _rule({
  String id = 'r1',
  bool locked = true,
  bool enabled = true,
  LockScope scope = LockScope.selection,
  RuleSelection? selection,
}) => Rule(
  id: id,
  name: 'Work hours',
  kind: RuleKind.schedule,
  createdAtMs: 0,
  enabled: enabled,
  locked: locked,
  lockScope: scope,
  selection:
      selection ??
      const RuleSelection(apps: ['com.instagram.android'], websites: ['x.com']),
  schedule: const RuleSchedule(
    days: {1, 2, 3, 4, 5},
    startMin: 540,
    endMin: 1020,
  ),
);

class _MockEngine extends Mock implements EngineRepository {}

class _FakeGrants implements TemporaryUnblockRepository {
  List<TemporaryUnblock> rows = const [];

  @override
  Future<List<TemporaryUnblock>> load() async => rows;

  @override
  Future<void> save(List<TemporaryUnblock> grants) async => rows = grants;
}

class _FakeLedger implements BypassLedgerRepository {
  _FakeLedger([BypassLedger? seed]) : _ledger = seed ?? const BypassLedger();

  BypassLedger _ledger;
  BypassLedger? saved;

  @override
  Future<BypassLedger> load() async => _ledger;

  @override
  Future<void> save(BypassLedger ledger) async {
    saved = ledger;
    _ledger = ledger;
  }
}

void main() {
  group('BypassEntry / BypassConfig', () {
    test('all six reason tokens round-trip', () {
      for (final r in OverrideReason.values) {
        expect(OverrideReason.fromWire(r.wire), r, reason: r.wire);
        expect(r.label, isNotEmpty);
        expect(
          r.label,
          isNot(equals(r.wire)),
          reason: 'the wire token must never be user-facing',
        );
      }
      expect(OverrideReason.fromWire('SOMETHING_ELSE'), isNull);
    });

    test('an unknown kind drops the row rather than miscounting it', () {
      expect(BypassEntry.fromJson({'kind': 'GIFT', 'atMs': 1}), isNull);
      expect(
        BypassEntry.fromJson({'kind': 'EMERGENCY', 'atMs': 1})?.kind,
        BypassKind.emergency,
        reason:
            'the discriminator ships from day one so M2.2 adds a preset '
            'instead of renaming a persisted key',
      );
    });

    test('the ledger document round-trips', () {
      final e = _override();
      final back = BypassEntry.fromJson(
        jsonDecode(jsonEncode(e.toJson())) as Map<String, dynamic>,
      );
      expect(back, e);
      final cfg = BypassConfig.fromJson(
        jsonDecode(jsonEncode(BypassConfig.defaults.toJson()))
            as Map<String, dynamic>,
      );
      expect(cfg, BypassConfig.defaults);
      expect(cfg.periodMs, _week, reason: 'WEEK is a rolling seven days');
    });

    test('a hostile config is clamped, never trusted verbatim', () {
      final cfg = BypassConfig.fromJson(const {
        'overrideLimit': 0,
        'overrideMaxWindowMs': 999999999,
      });
      expect(
        cfg.overrideLimit,
        greaterThanOrEqualTo(1),
        reason:
            'limit 0 is a lock nobody can ever lift — the plan says never ship '
            'it, so a corrupt blob cannot create one either',
      );
      expect(cfg.overrideMaxWindowMs, lessThanOrEqualTo(4 * 60 * 60 * 1000));
    });
  });

  group('UnblockQuota — the override quota', () {
    const cfg = BypassConfig.defaults;

    test('a rolling window, counted at exactly periodMs', () {
      expect(UnblockQuota.effectiveRemaining(const [], cfg, _nowMs), 2);
      expect(UnblockQuota.effectiveRemaining([_override()], cfg, _nowMs), 1);
      expect(
        UnblockQuota.effectiveRemaining(
          [_override(), _override(ruleId: 'r2')],
          cfg,
          _nowMs,
        ),
        0,
      );
      expect(
        UnblockQuota.effectiveRemaining(
          [_override(agoMs: _week - 1)],
          cfg,
          _nowMs,
        ),
        1,
        reason: 'one millisecond short of the period still counts',
      );
      expect(
        UnblockQuota.effectiveRemaining([_override(agoMs: _week)], cfg, _nowMs),
        2,
        reason: 'exactly periodMs old has aged out',
      );
    });

    test('remaining never goes negative, even over the limit', () {
      final many = [for (var i = 0; i < 10; i++) _override(ruleId: 'r$i')];
      expect(UnblockQuota.effectiveRemaining(many, cfg, _nowMs), 0);
    });

    test('emergency entries do not spend the override quota', () {
      final ledger = [
        BypassEntry(kind: BypassKind.emergency, atMs: _nowMs),
        BypassEntry(kind: BypassKind.emergency, atMs: _nowMs),
      ];
      expect(
        UnblockQuota.effectiveRemaining(ledger, cfg, _nowMs),
        2,
        reason: 'one store, two presets — each reads only its own kind',
      );
    });

    test('resetsAt is the OLDEST counted entry plus the period', () {
      expect(
        UnblockQuota.resetsAtMs([_override()], cfg, _nowMs),
        0,
        reason: 'still one left, so nothing to wait for',
      );
      final full = [
        _override(agoMs: 3 * 24 * 60 * 60 * 1000),
        _override(agoMs: 60000, ruleId: 'r2'),
      ];
      expect(
        UnblockQuota.resetsAtMs(full, cfg, _nowMs),
        _nowMs - 3 * 24 * 60 * 60 * 1000 + _week,
      );
    });

    test('a clock that moved BACKWARDS does not forgive an entry', () {
      // atMs is in the future relative to now, so `now - atMs` is negative:
      // younger than the period, therefore still counted.
      expect(
        UnblockQuota.effectiveRemaining(
          [_override(agoMs: -_week)],
          cfg,
          _nowMs,
        ),
        1,
      );
    });

    test('every validation runs, and refuses before any write', () {
      String? check({
        List<BypassEntry> entries = const [],
        OverrideReason? reason = OverrideReason.family,
        int startMs = 0,
        int endMs = 30 * 60000,
      }) => UnblockQuota.validateOverride(
        entries: entries,
        config: cfg,
        reason: reason,
        startMs: _nowMs + startMs,
        endMs: _nowMs + endMs,
        nowMs: _nowMs,
      );

      expect(check(), isNull);
      expect(
        check(
          entries: [
            _override(),
            _override(ruleId: 'r2'),
          ],
        ),
        UnblockQuota.noOverridesLeft,
      );
      expect(check(reason: null), UnblockQuota.reasonRequired);
      expect(check(startMs: 30 * 60000, endMs: 0), UnblockQuota.windowInverted);
      expect(check(endMs: 0), UnblockQuota.windowInverted);
      expect(
        check(endMs: cfg.overrideMaxWindowMs + 1),
        UnblockQuota.windowTooLong,
      );
      expect(
        check(endMs: cfg.overrideMaxWindowMs),
        isNull,
        reason: 'exactly maxWindow is allowed',
      );
    });

    test('a rule that is not blocking refuses FIRST, before the quota', () {
      // An override buys a window starting now. Spending one on a closed
      // schedule costs a scarce resource and lifts nothing — and the refusal
      // has to come before the quota check, or a user with none left would be
      // told the wrong reason.
      expect(
        UnblockQuota.validateOverride(
          entries: const [],
          config: cfg,
          reason: OverrideReason.family,
          startMs: _nowMs,
          endMs: _nowMs + 30 * 60000,
          nowMs: _nowMs,
          enforcingNow: false,
        ),
        UnblockQuota.notBlockingNow,
      );
      expect(
        UnblockQuota.validateOverride(
          entries: [
            _override(),
            _override(ruleId: 'r2'),
          ],
          config: cfg,
          reason: null,
          startMs: _nowMs,
          endMs: _nowMs,
          nowMs: _nowMs,
          enforcingNow: false,
        ),
        UnblockQuota.notBlockingNow,
        reason: 'it is checked first, so it wins over every other refusal',
      );
    });

    test('activeOverrides keys by rule and drops finished lifts', () {
      final live = _override();
      final over = BypassEntry(
        kind: BypassKind.override,
        atMs: _nowMs - 60 * 60000,
        untilMs: _nowMs - 30 * 60000,
        ruleId: 'r2',
        reason: OverrideReason.family,
      );
      final map = UnblockQuota.activeOverrides([live, over], _nowMs);
      expect(map.keys, ['r1']);
      expect(map['r1'], live);
    });

    test('the ledger prunes newest-first at its cap', () {
      final rows = [
        for (var i = 0; i < maxBypassEntries + 5; i++)
          BypassEntry(kind: BypassKind.override, atMs: i),
      ];
      final pruned = UnblockQuota.pruneLedger(rows);
      expect(pruned, hasLength(maxBypassEntries));
      expect(pruned.first.atMs, maxBypassEntries + 4);
    });
  });

  group('UnblockCubit.requestOverride', () {
    late _MockEngine engine;

    setUp(() {
      engine = _MockEngine();
      when(() => engine.pushTemporaryUnblocks(any())).thenAnswer((_) async {});
      when(() => engine.takePendingUnblock()).thenAnswer((_) async => null);
    });

    test('spends one, records the reason, and arms the lift window', () async {
      final ledger = _FakeLedger();
      final c = UnblockCubit(_FakeGrants(), ledger, engine, clock: () => _now);
      await c.load();
      expect(c.state.overridesLeft, 2);

      expect(
        await c.requestOverride(
          ruleId: 'r1',
          reason: OverrideReason.medicalAppointment,
          window: const Duration(minutes: 30),
        ),
        isNull,
      );
      final saved = ledger.saved!.entries.single;
      expect(saved.kind, BypassKind.override);
      expect(saved.ruleId, 'r1');
      expect(saved.reason, OverrideReason.medicalAppointment);
      expect(saved.untilMs, _nowMs + 30 * 60000);
      expect(c.state.overridesLeft, 1);
      expect(c.activeOverrideFor('r1'), isNotNull);
      expect(c.activeOverrideFor('r2'), isNull);

      // An override mints NO temporary-unblock grant: it is scoped to the rule,
      // not to the rule's targets, and is applied by splitting that rule's own
      // windows in the snapshot.
      expect(c.state.grants, isEmpty);
      await c.close();
    });

    test('at remaining == 0 it refuses BEFORE writing anything', () async {
      final ledger = _FakeLedger(
        BypassLedger(
          entries: [
            _override(),
            _override(ruleId: 'r2'),
          ],
        ),
      );
      final c = UnblockCubit(_FakeGrants(), ledger, engine, clock: () => _now);
      await c.load();
      expect(
        await c.requestOverride(
          ruleId: 'r3',
          reason: OverrideReason.family,
          window: const Duration(minutes: 5),
        ),
        UnblockQuota.noOverridesLeft,
      );
      expect(
        ledger.saved,
        isNull,
        reason: 'a refusal must not leave a half-spent quota behind',
      );
      await c.close();
    });

    test('a rule that is not blocking refuses without spending', () async {
      final ledger = _FakeLedger();
      final c = UnblockCubit(_FakeGrants(), ledger, engine, clock: () => _now);
      await c.load();
      expect(
        await c.requestOverride(
          ruleId: 'r1',
          reason: OverrideReason.family,
          window: const Duration(minutes: 30),
          enforcingNow: false,
        ),
        UnblockQuota.notBlockingNow,
      );
      expect(ledger.saved, isNull);
      expect(c.state.overridesLeft, 2, reason: 'quota untouched');
      await c.close();
    });

    test('a missing reason refuses without writing', () async {
      final ledger = _FakeLedger();
      final c = UnblockCubit(_FakeGrants(), ledger, engine, clock: () => _now);
      await c.load();
      expect(
        await c.requestOverride(
          ruleId: 'r1',
          reason: null,
          window: const Duration(minutes: 5),
        ),
        UnblockQuota.reasonRequired,
      );
      expect(ledger.saved, isNull);
      await c.close();
    });
  });

  group('EVO-053 — the grant budget', () {
    BypassEntry grantRow({int agoMs = 0}) => BypassEntry(
      kind: BypassKind.grant,
      atMs: _nowMs - agoMs,
      untilMs: _nowMs - agoMs + 15 * 60000,
      ruleId: 'com.instagram.android',
    );

    const rationed = BypassConfig(grantLimit: 2);
    const day = 24 * 60 * 60 * 1000;

    test('unlimited is null, not a large number', () {
      expect(
        UnblockQuota.grantsRemaining(const [], BypassConfig.defaults, _nowMs),
        isNull,
        reason:
            '"unlimited" and "plenty left" are different sentences — the sheet '
            'must not render a countdown for a budget nobody set',
      );
      expect(
        UnblockQuota.grantsResetAtMs(const [], BypassConfig.defaults, _nowMs),
        0,
      );
    });

    test('a rolling day, counted at exactly the period', () {
      expect(UnblockQuota.grantsRemaining(const [], rationed, _nowMs), 2);
      expect(UnblockQuota.grantsRemaining([grantRow()], rationed, _nowMs), 1);
      expect(
        UnblockQuota.grantsRemaining(
          [grantRow(), grantRow(agoMs: 60000)],
          rationed,
          _nowMs,
        ),
        0,
      );
      expect(
        UnblockQuota.grantsRemaining(
          [grantRow(agoMs: day - 1)],
          rationed,
          _nowMs,
        ),
        1,
      );
      expect(
        UnblockQuota.grantsRemaining([grantRow(agoMs: day)], rationed, _nowMs),
        2,
        reason: 'exactly a period old has aged out',
      );
    });

    test('the two budgets never spend each other', () {
      // One store, three presets — each reads only its own kind. This is the
      // property that let EVO-053 reuse M8's ledger instead of adding a store.
      expect(UnblockQuota.grantsRemaining([_override()], rationed, _nowMs), 2);
      expect(
        UnblockQuota.effectiveRemaining(
          [grantRow(), grantRow(agoMs: 1)],
          BypassConfig.defaults,
          _nowMs,
        ),
        2,
      );
    });

    test('the prune is PER KIND, so grants cannot refund an override', () {
      // 60 grants in one day would evict every override under a flat cap —
      // and an evicted override row inside its window is a refunded override.
      final ledger = <BypassEntry>[
        _override(agoMs: 60000),
        for (var i = 0; i < 60; i++) grantRow(agoMs: i),
      ];
      final pruned = UnblockQuota.pruneLedger(ledger);
      expect(
        pruned.where((e) => e.kind == BypassKind.override),
        hasLength(1),
        reason: 'the override must survive a burst of grants',
      );
      expect(pruned.where((e) => e.kind == BypassKind.grant), hasLength(50));
      expect(
        UnblockQuota.effectiveRemaining(pruned, BypassConfig.defaults, _nowMs),
        1,
      );
    });

    test('grantsResetAtMs is the oldest counted grant plus the period', () {
      expect(UnblockQuota.grantsResetAtMs([grantRow()], rationed, _nowMs), 0);
      final full = [
        grantRow(agoMs: 6 * 60 * 60 * 1000),
        grantRow(agoMs: 60000),
      ];
      expect(
        UnblockQuota.grantsResetAtMs(full, rationed, _nowMs),
        _nowMs - 6 * 60 * 60 * 1000 + day,
      );
    });

    test('a hostile grantLimit is clamped, and 0 stays 0', () {
      expect(BypassConfig.fromJson(const {'grantLimit': -5}).grantLimit, 0);
      expect(BypassConfig.fromJson(const {'grantLimit': 9999}).grantLimit, 50);
      expect(
        BypassConfig.fromJson(const {}).grantLimit,
        0,
        reason: 'unlimited is the shipped default; nobody is opted in',
      );
    });
  });

  group('EVO-052 — what the ledger says back', () {
    test('overrideSummary counts the window and keeps the reasons given', () {
      final summary = UnblockQuota.overrideSummary(
        [
          _override(),
          _override(agoMs: 2 * 24 * 60 * 60 * 1000, ruleId: 'r2'),
          _override(agoMs: 8 * 24 * 60 * 60 * 1000, ruleId: 'r3'),
        ],
        BypassConfig.defaults,
        _nowMs,
      );
      expect(summary.count, 2, reason: 'the 8-day-old row has aged out');
      expect(summary.reasons, hasLength(2));
      expect(summary.reasons.first, OverrideReason.scheduleChange);
      final empty = UnblockQuota.overrideSummary(
        const [],
        BypassConfig.defaults,
        _nowMs,
      );
      expect(empty.count, 0);
      expect(empty.reasons, isEmpty);
    });
  });

  group('LockGuard — the locked-rule invariant', () {
    test('a locked rule cannot be deleted', () {
      expect(LockGuard.check([_rule()], const []), LockGuard.deleteRefused);
    });

    test('a locked rule cannot be disabled', () {
      expect(
        LockGuard.check([_rule()], [_rule(enabled: false)]),
        LockGuard.disableRefused,
      );
    });

    test('a locked rule cannot be unlocked', () {
      expect(
        LockGuard.check([_rule()], [_rule(locked: false)]),
        LockGuard.unlockRefused,
      );
    });

    test('a locked rule cannot be narrowed on any dimension', () {
      for (final narrower in [
        const RuleSelection(websites: ['x.com']),
        const RuleSelection(apps: ['com.instagram.android']),
        const RuleSelection(
          mode: SelectionMode.allExcept,
          apps: ['com.instagram.android'],
          websites: ['x.com'],
        ),
      ]) {
        expect(
          LockGuard.check([_rule()], [_rule(selection: narrower)]),
          LockGuard.narrowRefused,
          reason: '$narrower',
        );
      }
      expect(
        LockGuard.check([_rule(scope: LockScope.distracting)], [_rule()]),
        LockGuard.narrowRefused,
        reason: 'shrinking the lock scope is narrowing too',
      );
    });

    test("a locked rule's schedule is frozen", () {
      // Moving a locked 09:00-17:00 window to 03:00-03:01 neuters the rule for
      // free, without spending an override — the same escape as deleting it,
      // wearing a different hat.
      final moved = _rule().copyWith(
        schedule: const RuleSchedule(
          days: {1, 2, 3, 4, 5},
          startMin: 180,
          endMin: 181,
        ),
      );
      expect(LockGuard.check([_rule()], [moved]), LockGuard.scheduleRefused);
      final fewerDays = _rule().copyWith(
        schedule: const RuleSchedule(days: {1}, startMin: 540, endMin: 1020),
      );
      expect(
        LockGuard.check([_rule()], [fewerDays]),
        LockGuard.scheduleRefused,
      );
    });

    test("a locked rule's budget can be tightened, never loosened", () {
      Rule limit(int minutes, {int opens = 0}) => Rule(
        id: 'r1',
        name: 'Budget',
        kind: RuleKind.timeLimit,
        createdAtMs: 0,
        locked: true,
        selection: const RuleSelection(apps: ['com.instagram.android']),
        thresholdMs: minutes * 60000,
        maxOpens: opens,
      );
      expect(
        LockGuard.check([limit(30)], [limit(240)]),
        LockGuard.budgetRefused,
        reason: 'dragging 30 min to 240 is the lock being dismantled',
      );
      expect(LockGuard.check([limit(30)], [limit(10)]), isNull);
      expect(LockGuard.check([limit(30)], [limit(30)]), isNull);
      expect(
        LockGuard.check([limit(30, opens: 5)], [limit(30, opens: 20)]),
        LockGuard.budgetRefused,
      );
    });

    test(
      'tightening a locked budget to ZERO is refused, not waved through',
      () {
        Rule limit({int minutes = 30, int opens = 0}) => Rule(
          id: 'r1',
          name: 'Budget',
          kind: RuleKind.timeLimit,
          createdAtMs: 0,
          locked: true,
          selection: const RuleSelection(apps: ['com.instagram.android']),
          thresholdMs: minutes * 60000,
          maxOpens: opens,
        );
        expect(
          LockGuard.check([limit()], [limit(minutes: 0)]),
          LockGuard.budgetRefused,
          reason:
              'resolveSnapshot emits NO entry at zero, so "tightening" to zero '
              'disables the rule while travelling the one direction the guard '
              'allows',
        );
        expect(
          LockGuard.check([limit(opens: 5)], [limit()]),
          LockGuard.budgetRefused,
        );
        // A rule that never had that budget is untouched — only a fall from a
        // real budget to nothing is the attack.
        expect(LockGuard.check([limit()], [limit(minutes: 1)]), isNull);
      },
    );

    test('a locked rule cannot be re-saved as a different KIND', () {
      const selection = RuleSelection(apps: ['com.instagram.android']);
      const schedule = Rule(
        id: 'r1',
        name: 'Work hours',
        kind: RuleKind.schedule,
        createdAtMs: 0,
        locked: true,
        selection: selection,
        schedule: RuleSchedule(
          days: RuleSchedule.weekdays,
          startMin: 9 * 60,
          endMin: 17 * 60,
        ),
      );
      // Same id, same targets, same schedule — but an open limit of zero, which
      // every other clause reads as "unchanged or tighter".
      const rewritten = Rule(
        id: 'r1',
        name: 'Work hours',
        kind: RuleKind.openLimit,
        createdAtMs: 0,
        locked: true,
        selection: selection,
        schedule: RuleSchedule(
          days: RuleSchedule.weekdays,
          startMin: 9 * 60,
          endMin: 17 * 60,
        ),
      );
      expect(LockGuard.check([schedule], [rewritten]), LockGuard.kindRefused);
    });

    test('renaming and WIDENING a locked rule are allowed', () {
      final wider = _rule(
        selection: const RuleSelection(
          apps: ['com.instagram.android', 'com.tiktok'],
          websites: ['x.com', 'y.com'],
          categories: ['short_form_video'],
        ),
      );
      expect(LockGuard.check([_rule()], [wider]), isNull);
      expect(
        LockGuard.check([_rule()], [_rule(scope: LockScope.distracting)]),
        isNull,
      );
      expect(
        LockGuard.check([_rule()], [_rule().copyWith(name: 'Deep work')]),
        isNull,
      );
    });

    test('unlocked rules are untouched, and a new rule is fine', () {
      expect(LockGuard.check([_rule(locked: false)], const []), isNull);
      expect(
        LockGuard.check(const [], [_rule()]),
        isNull,
        reason: 'creating a locked rule is exactly how one comes to exist',
      );
      expect(
        LockGuard.check([_rule()], [_rule(), _rule(id: 'r2', locked: false)]),
        isNull,
      );
    });
  });
}
