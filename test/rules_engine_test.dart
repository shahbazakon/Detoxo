import 'dart:async';
import 'dart:convert';

import 'package:detoxo/features/blocking/shared/domain/repositories/blocking_repositories.dart';
import 'package:detoxo/features/catalog/catalog.dart';
import 'package:detoxo/features/limits/limits.dart';
import 'package:detoxo/features/usage/usage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockEngine extends Mock implements EngineRepository {}

class _FakeRules implements RuleRepository {
  _FakeRules(this.rules, {this.failSave = false});
  List<Rule> rules;
  final bool failSave;
  List<Rule>? saved;

  @override
  Future<List<Rule>> load() async => rules;

  @override
  Future<void> save(List<Rule> rules) async {
    if (failSave) throw StateError('disk full');
    saved = rules;
    this.rules = rules;
  }
}

class _ThrowingRules implements RuleRepository {
  bool savedCalled = false;

  @override
  Future<List<Rule>> load() async => throw StateError('corrupt');

  @override
  Future<void> save(List<Rule> rules) async => savedCalled = true;
}

class _FakeDailyLimit implements DailyLimitRepository {
  _FakeDailyLimit(this.limit);
  final Duration limit;

  @override
  Future<DailyLimit> load() async => DailyLimit(limit: limit);

  @override
  Future<void> save(DailyLimit limit) async {}
}

class _FakeUsage implements UsageRepository {
  _FakeUsage({this.usage, this.events, this.denied = false});
  final List<AppUsage>? usage;
  final List<UsageEvent>? events;
  final bool denied;
  int usageCalls = 0;
  int eventCalls = 0;
  int get calls => usageCalls + eventCalls;

  @override
  Future<bool?> hasAccess() async => !denied;

  @override
  Future<UsageQueryResult<List<AppUsage>>> queryAppUsage(
    DateTime start,
    DateTime end,
  ) async {
    usageCalls++;
    return denied ? const UsageDenied() : UsageGranted(usage ?? const []);
  }

  @override
  Future<UsageQueryResult<List<UsageEvent>>> queryUsageEvents(
    DateTime start,
    DateTime end,
  ) async {
    eventCalls++;
    return denied ? const UsageDenied() : UsageGranted(events ?? const []);
  }
}

// Wednesday 2 Sep 2026, 10:00 local.
final _now = DateTime(2026, 9, 2, 10);
const _ig = 'com.instagram.android';

Rule _schedule({
  String id = 's1',
  int createdAtMs = 1,
  bool enabled = true,
  bool strict = false,
  bool locked = false,
  LockScope lockScope = LockScope.selection,
  RuleSelection selection = const RuleSelection(apps: [_ig]),
  RuleSchedule schedule = const RuleSchedule(
    days: RuleSchedule.weekdays,
    startMin: 9 * 60,
    endMin: 17 * 60,
  ),
}) => Rule(
  id: id,
  name: 'Work hours',
  kind: RuleKind.schedule,
  createdAtMs: createdAtMs,
  enabled: enabled,
  strict: strict,
  locked: locked,
  lockScope: lockScope,
  selection: selection,
  schedule: schedule,
);

Rule _timeLimit({int thresholdMin = 30, List<String> apps = const [_ig]}) =>
    Rule(
      id: 't1',
      name: 'Insta budget',
      kind: RuleKind.timeLimit,
      createdAtMs: 2,
      selection: RuleSelection(apps: apps),
      thresholdMs: thresholdMin * 60000,
    );

Rule _openLimit({int maxOpens = 5}) => Rule(
  id: 'o1',
  name: 'Five opens',
  kind: RuleKind.openLimit,
  createdAtMs: 3,
  selection: const RuleSelection(apps: [_ig]),
  maxOpens: maxOpens,
);

void main() {
  group('resolveSnapshot', () {
    test(
      'a schedule becomes one entry with flattened targets + 7-day windows',
      () {
        final eval = resolveSnapshot(
          rules: [
            _schedule(
              selection: const RuleSelection(
                apps: ['com.x'],
                categories: ['short_form_video'],
                websites: ['WWW.Example.com'],
              ),
            ),
          ],
          now: _now,
        );
        final e = eval.snapshot.entries.single;
        expect(e.reason, SnapshotEntry.reasonSchedule);
        expect(e.packages, containsAll(['com.x', _ig]));
        expect(e.domains, containsAll(['instagram.com', 'example.com']));
        expect(e.windows.length, 5);
        expect(e.always, isFalse);
        // A popular-site website covers its aliases, as the web blocker's own
        // chip does — "X (Twitter)" stores x.com and must close twitter.com.
        final x = resolveSnapshot(
          rules: [
            _schedule(
              selection: const RuleSelection(websites: ['x.com', 'news.io']),
            ),
          ],
          now: _now,
        ).snapshot.entries.single;
        expect(x.domains, containsAll(['x.com', 'twitter.com', 'news.io']));
        // Two rules stamped in the same millisecond keep one order every
        // resolve: native takes the first blocking entry.
        final tied = resolveSnapshot(
          rules: [
            _schedule(id: 'b', createdAtMs: 9),
            _schedule(id: 'a', createdAtMs: 9),
          ],
          now: _now,
        ).snapshot.entries.map((e) => e.id);
        expect(tied, ['a', 'b']);
        expect(
          eval.statuses['s1']!.activeNow,
          isTrue,
          reason: 'Wed 10:00 is inside',
        );
        expect(
          eval.statuses['s1']!.nextChangeMs,
          DateTime(2026, 9, 2, 17).millisecondsSinceEpoch,
        );
        expect(
          eval.snapshot.nextBoundaryMs,
          DateTime(2026, 9, 2, 17).millisecondsSinceEpoch,
          reason: 'the earliest edge after now is today 17:00',
        );
      },
    );

    test('disabled rules and rules with no upcoming window are omitted', () {
      final eval = resolveSnapshot(
        rules: [
          _schedule(enabled: false),
          _schedule(
            id: 's2',
            schedule: const RuleSchedule(days: {}, startMin: 0, endMin: 60),
          ),
        ],
        now: _now,
      );
      expect(eval.snapshot.entries, isEmpty);
      expect(eval.snapshot.nextBoundaryMs, 0);
      expect(eval.statuses['s1'], RuleStatus.off);
      expect(eval.statuses['s2']!.activeNow, isFalse);
    });

    test(
      'entries follow createdAtMs order (first blocking rule wins natively)',
      () {
        final eval = resolveSnapshot(
          rules: [
            _schedule(id: 'late', createdAtMs: 20),
            _schedule(id: 'early', createdAtMs: 10),
          ],
          now: _now,
        );
        expect(eval.snapshot.entries.map((e) => e.id), ['early', 'late']);
      },
    );

    test('ALL_EXCEPT rides the wire unchanged', () {
      final eval = resolveSnapshot(
        rules: [
          _schedule(
            selection: const RuleSelection(mode: SelectionMode.allExcept),
          ),
        ],
        now: _now,
      );
      final e = eval.snapshot.entries.single;
      expect(e.mode, SelectionMode.allExcept);
      expect(e.packages, isEmpty);
      expect(e.toJson()['mode'], 'ALL_EXCEPT');
    });

    test(
      'a time limit is spent at used == threshold and blocks the whole day',
      () {
        final eval = resolveSnapshot(
          rules: [_timeLimit()],
          now: _now,
          usageMsByPackage: {_ig: 30 * 60000},
          usageKnown: true,
        );
        final e = eval.snapshot.entries.single;
        expect(e.reason, SnapshotEntry.reasonDailyLimit);
        expect(e.packages, [_ig]);
        expect(e.windows, [
          TimeWindow(
            DateTime(2026, 9, 2).millisecondsSinceEpoch,
            DateTime(2026, 9, 3).millisecondsSinceEpoch,
          ),
        ]);
        final s = eval.statuses['t1']!;
        expect((s.spent, s.activeNow, s.usedMs), (true, true, 30 * 60000));
        expect(
          eval.snapshot.nextBoundaryMs,
          DateTime(2026, 9, 3).millisecondsSinceEpoch,
        );
      },
    );

    test('an unspent time limit rides along PENDING and projects its end', () {
      final eval = resolveSnapshot(
        rules: [_timeLimit(), _schedule()],
        now: _now,
        usageMsByPackage: {_ig: 10 * 60000},
        usageKnown: true,
      );
      expect(eval.snapshot.entries.map((e) => e.id), ['s1', 't1']);
      final pending = eval.snapshot.entries.last;
      expect(
        (pending.spent, pending.usageLimitMs),
        (false, 30 * 60000),
        reason:
            'EVO-029: native needs the budget to re-measure it while Detoxo '
            'is closed, and must not block until it says spent',
      );
      expect(eval.statuses['t1']!.spent, isFalse);
      expect(eval.statuses['t1']!.usedMs, 10 * 60000);
      expect(
        eval.snapshot.nextBoundaryMs,
        _now.add(const Duration(minutes: 20)).millisecondsSinceEpoch,
        reason: '20 minutes of budget left beats the 17:00 window edge',
      );
    });

    test('a spent limit on a category closes its websites too', () {
      const rule = Rule(
        id: 't1',
        name: 'Social budget',
        kind: RuleKind.timeLimit,
        createdAtMs: 2,
        selection: RuleSelection(categories: ['short_form_video']),
        thresholdMs: 60000,
      );
      final packages = Catalog.bundled.packagesIn('short_form_video');
      final eval = resolveSnapshot(
        rules: [rule],
        now: _now,
        usageMsByPackage: {for (final p in packages) p: 60000},
        usageKnown: true,
      );
      final e = eval.snapshot.entries.single;
      expect(e.packages, isNotEmpty);
      expect(
        e.domains,
        isNotEmpty,
        reason:
            'a category flattens to packages AND domains — blocking only the '
            'apps leaves the same service open in the browser',
      );
    });

    test('unknown usage holds a limit that was already blocking', () {
      final blocking = resolveSnapshot(
        rules: [_timeLimit()],
        now: _now,
        usageMsByPackage: {_ig: 30 * 60000},
        usageKnown: true,
      );
      expect(blocking.snapshot.entries.single.id, 't1');

      // Usage access revoked (or the platform query failed) on the next push.
      final after = resolveSnapshot(
        rules: [_timeLimit()],
        now: _now.add(const Duration(minutes: 5)),
        previousEntries: blocking.snapshot.entries,
      );
      expect(
        after.snapshot.entries.single.id,
        't1',
        reason:
            'dropping it would lift a block that is already up — and make '
            'revoking Usage Access a one-step unlock',
      );

      // But unknown usage still never STARTS a block.
      final fresh = resolveSnapshot(rules: [_timeLimit()], now: _now);
      expect(fresh.snapshot.entries.single.spent, isFalse);
    });

    test('a limits-only snapshot still pushes its projected boundary', () {
      final eval = resolveSnapshot(
        rules: [_timeLimit()],
        now: _now,
        usageMsByPackage: {_ig: 10 * 60000},
        usageKnown: true,
      );
      expect(eval.snapshot.entries.single.spent, isFalse);
      expect(
        eval.snapshot.nextBoundaryMs,
        _now.add(const Duration(minutes: 20)).millisecondsSinceEpoch,
        reason:
            'nothing is blocking yet, but native and the timer must still come '
            'back when the budget runs out — zeroing the boundary here left '
            'the limit enforcing only on the next app open',
      );
    });

    test('a nearly-spent limit floors its projection to a minute', () {
      final eval = resolveSnapshot(
        rules: [_timeLimit()],
        now: _now,
        usageMsByPackage: {_ig: 30 * 60000 - 1000},
        usageKnown: true,
      );
      expect(
        eval.snapshot.nextBoundaryMs,
        _now.add(const Duration(minutes: 1)).millisecondsSinceEpoch,
        reason:
            'a one-second projection re-arms the resync at that instant, and '
            'an unused app never moves `used` — that spins until midnight',
      );
    });

    test('unknown usage never spends a limit and says so', () {
      final eval = resolveSnapshot(
        rules: [_timeLimit(), _openLimit()],
        now: _now,
        usageMsByPackage: {_ig: 999 * 60000},
        opensByPackage: {_ig: 99},
      );
      expect(
        eval.snapshot.entries.every((e) => !e.spent),
        isTrue,
        reason: 'both ride along PENDING; neither may block',
      );
      expect(eval.statuses['t1']!.usageKnown, isFalse);
      expect(eval.statuses['o1']!.spent, isFalse);
    });

    test('an open limit is spent once opens reach the maximum', () {
      final eval = resolveSnapshot(
        rules: [_openLimit()],
        now: _now,
        opensByPackage: {_ig: 5},
        usageKnown: true,
      );
      expect(
        eval.snapshot.entries.single.reason,
        SnapshotEntry.reasonDailyLimit,
      );
      expect(eval.statuses['o1']!.opens, 5);
      expect(eval.snapshot.entries.single.spent, isTrue);
      expect(
        resolveSnapshot(
          rules: [_openLimit()],
          now: _now,
          opensByPackage: {_ig: 4},
          usageKnown: true,
        ).snapshot.entries.single.spent,
        isFalse,
        reason: 'one launch short: present for native to measure, not blocking',
      );
    });

    test('the daily reel limit entry is appended last, only when set', () {
      final eval = resolveSnapshot(
        rules: [_schedule()],
        now: _now,
        dailyReelLimit: const Duration(minutes: 45),
      );
      final e = eval.snapshot.entries.last;
      expect(e.id, SnapshotEntry.dailyReelLimitId);
      expect(e.always, isTrue);
      expect(e.platformIds, [SnapshotEntry.allPlatforms]);
      expect(e.reelTimeLimitMs, 45 * 60000);
      expect(
        resolveSnapshot(rules: const [], now: _now).snapshot.entries,
        isEmpty,
      );
    });

    test('the wire JSON carries the mirror-contract keys', () {
      final json =
          jsonDecode(
                resolveSnapshot(
                  rules: [_schedule()],
                  now: _now,
                  dailyReelLimit: const Duration(minutes: 5),
                ).snapshot.toJsonString(),
              )
              as List<dynamic>;
      final first = json.first as Map<String, dynamic>;
      expect(
        first.keys,
        containsAll([
          'id',
          'reason',
          'mode',
          'packages',
          'domains',
          'platformIds',
          'windows',
          'always',
          'reelTimeLimitMs',
        ]),
      );
      expect((first['windows'] as List<dynamic>).first, hasLength(2));
    });
  });

  test('every preset is savable and actually resolves to an entry', () {
    for (final preset in RulePreset.all) {
      final rule = preset.stamp(
        id: 'p-${preset.template.name}',
        createdAtMs: 1,
      );
      expect(
        rule.validate(),
        isNull,
        reason: '${preset.template.name} would be rejected by its own editor',
      );
      final eval = resolveSnapshot(
        rules: [rule],
        now: _now,
        // Limit presets only enter the snapshot once spent; schedules enter on
        // their windows. Both must produce SOMETHING native can act on.
        usageKnown: true,
        usageMsByPackage: {
          for (final p in Catalog.bundled.packagesIn('short_form_video'))
            p: 10 * 60 * 60000,
        },
      );
      expect(
        eval.snapshot.entries,
        isNotEmpty,
        reason: '${preset.template.name} resolved to nothing enforceable',
      );
    }
  });

  group('Rule JSON', () {
    test('round-trips every kind and keeps the storage vocabulary', () {
      for (final r in [_schedule(), _timeLimit(), _openLimit()]) {
        final json = r.toJson();
        expect(
          Rule.fromJson(jsonDecode(jsonEncode(json)) as Map<String, dynamic>),
          r,
        );
      }
      final json = _timeLimit().toJson();
      expect(json['enabledState'], 'ENABLED');
      expect(json['activation'], {'type': 'ALWAYS_ON'});
      expect((json['timeLimit'] as Map)['lockPeriod'], 'END_OF_DAY');
      expect(_schedule(enabled: false).toJson()['enabledState'], 'DISABLED');
    });

    test('a wrong-typed field degrades that field, never the list', () {
      // The shape a newer build (or a restored backup) could legitimately
      // write: the vocabulary is additive, so the types must be tolerated.
      final parsed = Rule.fromJson({
        'id': 'x',
        'kind': 'SCHEDULE',
        'name': 42,
        'createdAtMs': '1756800000000',
        'enabledState': const ['ENABLED'],
        'activation': {
          'type': 'REPEATING',
          'repeatDays': 'WEEKDAYS',
          'timeStart': 900,
          'timeEnd': '17:00',
        },
        'timeLimit': {'thresholdMs': '600000'},
      });
      expect(parsed, isNotNull, reason: 'a cast here would throw out the list');
      expect(
        (parsed!.name, parsed.createdAtMs, parsed.thresholdMs),
        ('', 0, 0),
      );
      expect(parsed.schedule!.days, isEmpty);
      expect(
        (parsed.schedule!.startMin, parsed.schedule!.endMin),
        (0, 17 * 60),
      );
    });

    test('an unknown kind is dropped rather than guessed', () {
      expect(Rule.fromJson({'id': 'x', 'kind': 'FRICTION'}), isNull);
      expect(RuleKind.fromWire('nope'), isNull);
      expect(SelectionMode.fromWire('nope'), SelectionMode.block);
    });

    test('a document without an id is dropped, not listed unenforced', () {
      // Native skips a row with no id, so such a rule would list and toggle
      // while blocking nothing — and `remove('')` would take every one.
      expect(Rule.fromJson({'kind': 'SCHEDULE'}), isNull);
      expect(Rule.fromJson({'id': '', 'kind': 'SCHEDULE'}), isNull);
      expect(Rule.fromJson({'id': 7, 'kind': 'SCHEDULE'}), isNull);
    });

    test('a limit with no budget is refused by the shared validator', () {
      // `resolveSnapshot` emits nothing for a budget of zero, so the rule
      // would read "0 min a day" and block nothing.
      expect(_timeLimit(thresholdMin: 0).validate(), isNotNull);
      expect(_openLimit(maxOpens: 0).validate(), isNotNull);
      expect(_timeLimit().validate(), isNull);
      expect(_openLimit().validate(), isNull);
    });
  });

  group('syncRules', () {
    late _MockEngine engine;

    setUp(() {
      engine = _MockEngine();
      when(() => engine.pushRules(any(), any())).thenAnswer((_) async => true);
    });

    test(
      'pushes the snapshot JSON and boundary, skipping usage for schedules',
      () async {
        final usage = _FakeUsage();
        final eval = await syncRules(
          _FakeRules([_schedule()]),
          _FakeDailyLimit(Duration.zero),
          usage,
          engine,
          now: () => _now,
        );
        expect(eval, isNotNull);
        expect(usage.calls, 0, reason: 'no limit rule → no UsageStats read');
        final captured = verify(
          () => engine.pushRules(captureAny(), captureAny()),
        ).captured;
        final entries = jsonDecode(captured[0] as String) as List<dynamic>;
        expect((entries.single as Map<String, dynamic>)['id'], 's1');
        expect(captured[1], DateTime(2026, 9, 2, 17).millisecondsSinceEpoch);
      },
    );

    test('a corrupt store aborts the push — never wipes native', () async {
      final eval = await syncRules(
        _ThrowingRules(),
        _FakeDailyLimit(Duration.zero),
        _FakeUsage(),
        engine,
        now: () => _now,
      );
      expect(eval, isNull);
      verifyNever(() => engine.pushRules(any(), any()));
    });

    test('usage denied leaves limits unspent but still pushes', () async {
      final eval = await syncRules(
        _FakeRules([_timeLimit()]),
        _FakeDailyLimit(const Duration(minutes: 30)),
        _FakeUsage(denied: true),
        engine,
        now: () => _now,
      );
      expect(eval!.statuses['t1']!.usageKnown, isFalse);
      expect(eval.snapshot.entries.map((e) => e.id), [
        't1',
        SnapshotEntry.dailyReelLimitId,
      ]);
      expect(
        eval.snapshot.entries.first.spent,
        isFalse,
        reason: 'denied usage never starts a block — native re-measures it',
      );
      verify(() => engine.pushRules(any(), any())).called(1);
    });

    test('granted usage spends a time limit', () async {
      final eval = await syncRules(
        _FakeRules([_timeLimit()]),
        _FakeDailyLimit(Duration.zero),
        _FakeUsage(
          usage: const [AppUsage(package: _ig, foregroundMillis: 31 * 60000)],
        ),
        engine,
        now: () => _now,
      );
      expect(eval!.statuses['t1']!.spent, isTrue);
      expect(eval.snapshot.entries.single.id, 't1');
    });

    test('each budget kind reads only the UsageStats query it needs', () async {
      final time = _FakeUsage();
      await syncRules(
        _FakeRules([_timeLimit()]),
        _FakeDailyLimit(Duration.zero),
        time,
        engine,
        now: () => _now,
      );
      expect((time.usageCalls, time.eventCalls), (1, 0));

      final opens = _FakeUsage();
      final eval = await syncRules(
        _FakeRules([_openLimit()]),
        _FakeDailyLimit(Duration.zero),
        opens,
        engine,
        now: () => _now,
      );
      expect((opens.usageCalls, opens.eventCalls), (0, 1));
      expect(eval!.statuses['o1']!.usageKnown, isTrue);
    });

    test(
      'an unchanged snapshot pushes the boundary without the array',
      () async {
        final first = await syncRules(
          _FakeRules([_schedule()]),
          _FakeDailyLimit(Duration.zero),
          _FakeUsage(),
          engine,
          now: () => _now,
        );
        final second = await syncRules(
          _FakeRules([_schedule()]),
          _FakeDailyLimit(Duration.zero),
          _FakeUsage(),
          engine,
          now: () => _now,
          previous: first!.snapshot,
        );
        expect(second!.snapshot, first.snapshot);
        final captured = verify(
          () => engine.pushRules(captureAny(), captureAny()),
        ).captured;
        expect(captured[0], isA<String>());
        expect(
          captured[2],
          isNull,
          reason: 'byte-identical → not re-marshalled',
        );
        expect(captured[3], first.snapshot.nextBoundaryMs);
      },
    );

    test('a push native did not take reports nothing new', () async {
      when(() => engine.pushRules(any(), any())).thenAnswer((_) async => false);
      final eval = await syncRules(
        _FakeRules([_schedule()]),
        _FakeDailyLimit(Duration.zero),
        _FakeUsage(),
        engine,
        now: () => _now,
      );
      expect(
        eval,
        isNull,
        reason: 'the caller must not record a snapshot native never received',
      );
    });

    test(
      'granted usage events spend an open limit through countOpens',
      () async {
        UsageEvent fg(int t) => UsageEvent(
          package: _ig,
          type: UsageEventType.moveToForeground,
          timestampMillis: t,
        );
        const other = UsageEvent(
          package: 'com.launcher',
          type: UsageEventType.moveToForeground,
          timestampMillis: 0,
        );
        final eval = await syncRules(
          _FakeRules([_openLimit(maxOpens: 2)]),
          _FakeDailyLimit(Duration.zero),
          _FakeUsage(events: [fg(1), other, fg(3), fg(4)]),
          engine,
          now: () => _now,
        );
        expect(eval!.statuses['o1']!.opens, 2, reason: 'fg(4) resumes fg(3)');
        expect(eval.statuses['o1']!.spent, isTrue);
      },
    );
  });

  test('RuleSummary copy', () {
    expect(RuleSummary.describe(_schedule()), 'Weekdays · 09:00–17:00 · 1 app');
    expect(
      RuleSummary.describe(
        _schedule(
          schedule: const RuleSchedule(
            days: {5, 6},
            startMin: 22 * 60,
            endMin: 6 * 60,
          ),
          selection: const RuleSelection(
            categories: ['social'],
            websites: ['a.com', 'b.com'],
          ),
        ),
      ),
      'Fri, Sat · 22:00–06:00 (next day) · 1 category, 2 sites',
    );
    expect(RuleSummary.describe(_timeLimit()), '30 min a day · 1 app');
    expect(
      RuleSummary.describe(_openLimit(maxOpens: 1)),
      '1 open a day · 1 app',
    );
    expect(RuleSummary.days(RuleSchedule.everyDay), 'Every day');
    expect(RuleSummary.days(const {6, 7}), 'Weekends');

    const active = RuleStatus(activeNow: true, nextChangeMs: 1756800000000);
    expect(RuleSummary.status(_schedule(), active, _now), 'Active now');
    expect(RuleSummary.status(_schedule(enabled: false), active, _now), 'Off');
    expect(
      RuleSummary.status(
        _timeLimit(),
        const RuleStatus(usedMs: 22 * 60000),
        _now,
      ),
      '22/30 min',
    );
    expect(
      RuleSummary.status(
        _openLimit(),
        const RuleStatus(usageKnown: false),
        _now,
      ),
      'Needs usage access',
    );
    expect(
      RuleSummary.status(
        _timeLimit(),
        const RuleStatus(spent: true, activeNow: true),
        _now,
      ),
      'Limit reached',
    );

    final until = DateTime(2026, 9, 2, 17).millisecondsSinceEpoch;
    expect(
      RuleSummary.nextEvent(
        [_schedule()],
        {'s1': RuleStatus(activeNow: true, nextChangeMs: until)},
        _now,
      ),
      'Work hours · until 17:00',
    );
    final monday = DateTime(2026, 9, 7, 9).millisecondsSinceEpoch;
    expect(
      RuleSummary.nextEvent(
        [_schedule()],
        {'s1': RuleStatus(nextChangeMs: monday)},
        _now,
      ),
      'Next: Work hours · Mon 09:00',
    );
    expect(
      RuleSummary.nextEvent(const [], const {}, _now),
      'Schedules and daily limits',
    );
    expect(
      RuleSummary.nextEvent(
        [_schedule(enabled: false)],
        {'s1': RuleStatus.off},
        _now,
      ),
      'All rules are off',
    );
  });

  test('the bundled catalog resolves the categories a rule can pick', () {
    expect(Catalog.bundled.packagesIn('short_form_video'), contains(_ig));
    expect(Catalog.bundled.packagesIn('nope'), isEmpty);
  });

  // ── M8 ─────────────────────────────────────────────────────────────────
  group('M8 — locked rules and the override window split', () {
    // A real lift always STARTED already — `UnblockQuota.activeOverrides` only
    // hands back the ones covering `now` — so the fixture is one too.
    TimeWindow lift({int fromMin = -30, int toMin = 30}) => TimeWindow(
      _now.add(Duration(minutes: fromMin)).millisecondsSinceEpoch,
      _now.add(Duration(minutes: toMin)).millisecondsSinceEpoch,
    );

    test('locked emits strict: true, and adds NO snapshot key', () {
      final e = resolveSnapshot(
        rules: [_schedule(locked: true)],
        now: _now,
      ).snapshot.entries.single;
      expect(
        e.strict,
        isTrue,
        reason:
            'a locked rule a two-minute Pause lifts is theatre, so locking '
            'implies strict — and native therefore learns nothing new',
      );
      expect(
        (jsonDecode(
                  resolveSnapshot(
                    rules: [_schedule(locked: true)],
                    now: _now,
                  ).snapshot.toJsonString(),
                )
                as List<dynamic>)[0]
            as Map<String, dynamic>,
        isNot(contains('locked')),
        reason: 'the pushRules snapshot gains no key for M8',
      );
    });

    test('an override splits the covering window into two', () {
      final eval = resolveSnapshot(
        rules: [_schedule(locked: true)],
        now: _now,
        activeOverrides: {'s1': lift()},
      );
      final midnight = DateTime(
        _now.year,
        _now.month,
        _now.day + 1,
      ).millisecondsSinceEpoch;
      final today = eval.snapshot.entries.single.windows
          .where((w) => w.startMs < midnight)
          .toList();
      expect(today, hasLength(2), reason: '09:00–09:30 and 10:30–17:00');
      expect(today[0].endMs, lift().startMs);
      expect(today[1].startMs, lift().endMs);
      expect(
        eval.snapshot.nextBoundaryMs,
        lift().endMs,
        reason:
            'the rule resumes when the lift ends, and native re-arms there by '
            'the long compare it already does — with Flutter dead',
      );
    });

    test('a lift covering the whole window removes it, keeping the rest', () {
      final wide = TimeWindow(
        _now.subtract(const Duration(hours: 5)).millisecondsSinceEpoch,
        _now.add(const Duration(hours: 12)).millisecondsSinceEpoch,
      );
      final entries = resolveSnapshot(
        rules: [_schedule(locked: true)],
        now: _now,
        activeOverrides: {'s1': wide},
      ).snapshot.entries;
      // Today's 09:00-17:00 is gone; the next four weekdays survive.
      expect(entries.single.windows, hasLength(4));
    });

    test('a lifted rule reports Lifted, not Active now', () {
      final eval = resolveSnapshot(
        rules: [_schedule(locked: true)],
        now: _now,
        activeOverrides: {
          's1': TimeWindow(
            _now.subtract(const Duration(minutes: 5)).millisecondsSinceEpoch,
            _now.add(const Duration(minutes: 25)).millisecondsSinceEpoch,
          ),
        },
      );
      final status = eval.statuses['s1']!;
      expect(status.activeNow, isFalse);
      expect(status.isLifted, isTrue);
      expect(
        RuleSummary.status(_schedule(locked: true), status, _now),
        startsWith('Lifted to'),
      );
    });

    test('a spent limit keeps spent: true while its window is split', () {
      final e = resolveSnapshot(
        rules: [_timeLimit()],
        now: _now,
        usageMsByPackage: const {_ig: 40 * 60000},
        usageKnown: true,
        activeOverrides: {'t1': lift()},
      ).snapshot.entries.single;
      expect(
        e.spent,
        isTrue,
        reason:
            'flipping it to pending would hand the entry back to the native '
            'reconciler, which would re-close the override at the next tick',
      );
      expect(e.windows, hasLength(2));
    });

    test('subtractWindow leaves disjoint windows alone', () {
      const w = [TimeWindow(100, 200)];
      expect(subtractWindow(w, 200, 300), w);
      expect(subtractWindow(w, 0, 100), w);
      expect(
        subtractWindow(w, 150, 150),
        w,
        reason: 'an empty lift is a no-op',
      );
      expect(subtractWindow(w, 100, 200), isEmpty);
    });

    test('lockScope DISTRACTING widens a BLOCK schedule', () {
      final plain = resolveSnapshot(
        rules: [_schedule(locked: true)],
        now: _now,
      ).snapshot.entries.single;
      final wide = resolveSnapshot(
        rules: [_schedule(locked: true, lockScope: LockScope.distracting)],
        now: _now,
      ).snapshot.entries.single;
      expect(wide.packages.length, greaterThan(plain.packages.length));
      expect(
        wide.packages,
        containsAll(
          Catalog.bundled.packagesWithBehavior(AppBehavior.distracting),
        ),
      );
      expect(wide.domains.length, greaterThan(plain.domains.length));
      expect(wide.packages, contains(_ig), reason: 'the selection survives');
    });

    test('DISTRACTING never widens a limit — that would widen its BUDGET', () {
      const rule = Rule(
        id: 't1',
        name: 'Insta budget',
        kind: RuleKind.timeLimit,
        createdAtMs: 2,
        locked: true,
        lockScope: LockScope.distracting,
        selection: RuleSelection(apps: [_ig]),
        thresholdMs: 30 * 60000,
      );
      final e = resolveSnapshot(
        rules: [rule],
        now: _now,
        usageMsByPackage: const {_ig: 1},
        usageKnown: true,
      ).snapshot.entries.single;
      expect(
        e.packages,
        [_ig],
        reason:
            '"30 min of Instagram" must not become "30 min of any distracting '
            'app", spent within minutes of opening anything',
      );
    });

    test(
      'DISTRACTING never widens an ALL_EXCEPT rule — it would invert it',
      () {
        final e = resolveSnapshot(
          rules: [
            _schedule(
              locked: true,
              lockScope: LockScope.distracting,
              selection: const RuleSelection(
                mode: SelectionMode.allExcept,
                apps: [_ig],
              ),
            ),
          ],
          now: _now,
        ).snapshot.entries.single;
        expect(
          e.packages,
          [_ig],
          reason:
              'under ALL_EXCEPT the widened set would become the only apps '
              'EXEMPT from the rule',
        );
      },
    );

    test('an unknown-usage limit stays spent THROUGH a lift', () {
      // The previous snapshot has the lift's window cut out of it, so probing
      // `now` while the lift runs finds no covering window. Before the fix a
      // usage read that failed mid-lift silently un-spent the budget — and left
      // it un-spent after the lift ended, because `_wasSpent` then had nothing
      // spent to find.
      final spentEntry = resolveSnapshot(
        rules: [_timeLimit()],
        now: _now,
        usageMsByPackage: const {_ig: 40 * 60000},
        usageKnown: true,
      ).snapshot;
      final duringLift = resolveSnapshot(
        rules: [_timeLimit()],
        now: _now,
        activeOverrides: {'t1': lift()},
        previousEntries: spentEntry.entries,
      ).snapshot.entries.single;
      expect(
        duringLift.spent,
        isTrue,
        reason: 'the hole must not read as "the budget was never spent"',
      );
      // …and after the lift ends, with usage still unknown, it is still spent.
      final after = resolveSnapshot(
        rules: [_timeLimit()],
        now: _now.add(const Duration(minutes: 45)),
        previousEntries: [duringLift],
      ).snapshot.entries.single;
      expect(after.spent, isTrue);
    });

    test('a lift on a rule that is not enforcing is not reported as Lifted', () {
      // Saturday: the weekday schedule has no open window, so there is nothing
      // to suppress. Calling that "Lifted" both lies and hides the real next
      // change.
      final saturday = DateTime(2026, 9, 5, 10);
      final status = resolveSnapshot(
        rules: [_schedule(locked: true)],
        now: saturday,
        activeOverrides: {
          's1': TimeWindow(
            saturday
                .subtract(const Duration(minutes: 5))
                .millisecondsSinceEpoch,
            saturday.add(const Duration(minutes: 25)).millisecondsSinceEpoch,
          ),
        },
      ).statuses['s1']!;
      expect(status.isLifted, isFalse);
      expect(status.activeNow, isFalse);
      expect(
        status.nextChangeMs,
        DateTime(2026, 9, 7, 9).millisecondsSinceEpoch,
        reason: 'Monday 09:00 is the real next change, not the lift end',
      );
      // An unspent limit is the same: nothing to lift.
      expect(
        resolveSnapshot(
          rules: [_timeLimit()],
          now: _now,
          usageMsByPackage: const {_ig: 1},
          usageKnown: true,
          activeOverrides: {'t1': lift()},
        ).statuses['t1']!.isLifted,
        isFalse,
      );
    });

    test('locked and lockScope round-trip, sparsely', () {
      final locked = _schedule(locked: true, lockScope: LockScope.distracting);
      final back = Rule.fromJson(locked.toJson())!;
      expect(back.locked, isTrue);
      expect(back.lockScope, LockScope.distracting);
      expect(back.isStrict, isTrue);
      expect(
        _schedule().toJson().keys,
        isNot(contains('locked')),
        reason: 'an unlocked rule is byte-identical to a pre-M8 document',
      );
      expect(
        _schedule(locked: true).toJson().keys,
        isNot(contains('lockScope')),
        reason: 'the default scope is not written either',
      );
      expect(
        Rule.fromJson({
          'id': 'x',
          'kind': 'SCHEDULE',
          'locked': 'yes-please',
        })!.locked,
        isFalse,
        reason: 'a wrong-typed field degrades to the safe default',
      );
    });
  });

  group('RulesCubit', () {
    late _MockEngine engine;
    late StreamController<int> boundaries;

    RulesCubit cubit(_FakeRules repo) => RulesCubit(
      repo,
      _FakeDailyLimit(Duration.zero),
      _FakeUsage(),
      engine,
      clock: () => _now,
    );

    setUp(() {
      engine = _MockEngine();
      boundaries = StreamController<int>.broadcast();
      when(() => engine.pushRules(any(), any())).thenAnswer((_) async => true);
      when(
        () => engine.ruleBoundaryStream(),
      ).thenAnswer((_) => boundaries.stream);
    });

    tearDown(() => boundaries.close());

    test('a mutation after a failed load is refused, never written', () async {
      final repo = _ThrowingRules();
      final c = RulesCubit(
        repo,
        _FakeDailyLimit(Duration.zero),
        _FakeUsage(),
        engine,
        clock: () => _now,
      );
      await c.load();
      expect(c.state.loaded, isFalse);
      expect(c.state.rules, isEmpty);

      expect(await c.save(_schedule()), isFalse);
      expect(
        repo.savedCalled,
        isFalse,
        reason:
            'the store still holds the real rules — saving the empty list the '
            'failed load left behind would replace every one of them',
      );
      expect(c.state.error, RulesCubit.loadFailed);
      await c.close();
    });

    test('load pushes the stored rules and fills statuses', () async {
      final c = cubit(_FakeRules([_schedule()]));
      await c.load();
      expect(c.state.isLoading, isFalse);
      expect(c.state.rules.single.id, 's1');
      expect(c.state.statusOf(c.state.rules.single).activeNow, isTrue);
      verify(() => engine.pushRules(any(), any())).called(1);
      await c.close();
    });

    test('save is optimistic, persists, then re-pushes', () async {
      final repo = _FakeRules([]);
      final c = cubit(repo);
      await c.load();
      expect(await c.save(_timeLimit()), isTrue);
      expect(repo.saved!.single.id, 't1');
      expect(c.state.rules.single.kind, RuleKind.timeLimit);
      verify(() => engine.pushRules(any(), any())).called(2);
      await c.close();
    });

    test('a failed save reverts the list and reports it', () async {
      final c = cubit(_FakeRules([_schedule()], failSave: true));
      await c.load();
      expect(await c.setEnabled('s1', enabled: false), isFalse);
      expect(c.state.rules.single.enabled, isTrue, reason: 'reverted');
      expect(c.state.error, RulesCubit.saveFailed);
      verify(() => engine.pushRules(any(), any())).called(1);
      await c.close();
    });

    test('toggling off drops the rule from the pushed snapshot', () async {
      final c = cubit(_FakeRules([_schedule()]));
      await c.load();
      expect(await c.setEnabled('s1', enabled: true), isTrue);
      expect(await c.setEnabled('s1', enabled: false), isTrue);
      final captured = verify(
        () => engine.pushRules(captureAny(), captureAny()),
      ).captured;
      expect(captured[captured.length - 2], '[]');
      expect(captured.last, 0);
      await c.close();
    });

    test('a native ruleBoundary re-pushes', () async {
      final c = cubit(_FakeRules([_schedule()]));
      await c.load();
      boundaries.add(1);
      await Future<void>.delayed(Duration.zero);
      verify(() => engine.pushRules(any(), any())).called(2);
      await c.close();
    });

    test('resyncs queued before one starts run as one', () async {
      final c = cubit(_FakeRules([_schedule()]));
      await c.load();
      clearInteractions(engine);
      // A resume, the screen's post-frame resync and the boundary timer land
      // together; without coalescing that was three full cycles.
      await Future.wait([c.resync(), c.resync(), c.resync()]);
      verify(() => engine.pushRules(any(), any())).called(1);
      await c.close();
    });

    test('the cap refuses the 51st rule without touching the store', () async {
      final repo = _FakeRules([
        for (var i = 0; i < maxRules; i++) _schedule(id: 'r$i', createdAtMs: i),
      ]);
      final c = cubit(repo);
      await c.load();
      expect(await c.save(_timeLimit()), isFalse);
      expect(c.state.error, contains('$maxRules'));
      expect(repo.saved, isNull);
      await c.close();
    });
  });
}
