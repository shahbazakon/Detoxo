// M8 part A — per-target temporary unblocks: the entity, the pure helpers, the
// wire payload, the cubit's derived state, and the one-time migration of the
// web blocker's per-site pause onto the same mechanism.

import 'dart:convert';

import 'package:detoxo/core/storage/local_store.dart';
import 'package:detoxo/features/blocking/shared/domain/repositories/blocking_repositories.dart';
import 'package:detoxo/features/limits/limits.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

final _now = DateTime(2026, 9, 6, 10);
const _fifteenMin = Duration(minutes: 15);
int get _nowMs => _now.millisecondsSinceEpoch;

TemporaryUnblock _grant({
  UnblockTargetType type = UnblockTargetType.app,
  String id = 'com.instagram.android',
  int startOffsetMs = 0,
  int minutes = 15,
  int? cancelledMs,
  UnblockSource source = UnblockSource.wall,
}) => TemporaryUnblock(
  targetType: type,
  targetId: id,
  startMs: _nowMs + startOffsetMs,
  endMs: _nowMs + startOffsetMs + minutes * 60000,
  cancelledMs: cancelledMs,
  source: source,
);

class _MockEngine extends Mock implements EngineRepository {}

/// In-memory store, so the migration can be exercised against a real blob.
class _FakeStore implements LocalStore {
  final Map<String, String> data = {};

  @override
  String? read(String key) => data[key];

  @override
  Future<void> write(String key, String value) async => data[key] = value;

  @override
  Future<void> delete(String key) async => data.remove(key);

  @override
  Future<String?> readSecret(String key) async => null;

  @override
  Future<void> writeSecret(String key, String value) async {}

  @override
  Future<void> deleteSecret(String key) async {}

  @override
  Future<void> clearAll() async => data.clear();
}

class _FakeGrants implements TemporaryUnblockRepository {
  List<TemporaryUnblock> _rows = const [];
  List<TemporaryUnblock>? saved;

  @override
  Future<List<TemporaryUnblock>> load() async => _rows;

  @override
  Future<void> save(List<TemporaryUnblock> grants) async {
    saved = grants;
    _rows = grants;
  }
}

class _ThrowingGrants implements TemporaryUnblockRepository {
  bool savedCalled = false;

  @override
  Future<List<TemporaryUnblock>> load() async => throw Exception('corrupt');

  @override
  Future<void> save(List<TemporaryUnblock> grants) async => savedCalled = true;
}

class _FakeLedger implements BypassLedgerRepository {
  _FakeLedger([BypassLedger? seed]) : _ledger = seed ?? const BypassLedger();

  BypassLedger _ledger;
  BypassLedger? saved;

  /// A corrupt `bypass_ledger` blob — the repository casts on read, so this is
  /// what a truncated or wrong-shaped document actually does to the cubit.
  bool throwOnLoad = false;

  @override
  Future<BypassLedger> load() async {
    if (throwOnLoad) throw const FormatException('corrupt ledger');
    return _ledger;
  }

  @override
  Future<void> save(BypassLedger ledger) async {
    saved = ledger;
    _ledger = ledger;
  }
}

void main() {
  group('TemporaryUnblock', () {
    test('is active from startMs inclusive to endMs exclusive', () {
      final g = _grant();
      expect(g.isActiveAt(g.startMs), isTrue, reason: 'start is inclusive');
      expect(g.isActiveAt(g.endMs - 1), isTrue);
      expect(g.isActiveAt(g.endMs), isFalse, reason: 'end is exclusive');
      expect(g.isActiveAt(g.startMs - 1), isFalse);
    });

    test('cancelling wins immediately, not at endMs', () {
      final g = _grant().cancelledAt(_nowMs + 60000);
      expect(
        g.isActiveAt(_nowMs + 60001),
        isFalse,
        reason: '"I\'m done" gives protection back now',
      );
      expect(g.endMs, _nowMs + 15 * 60000, reason: 'the ask is kept honest');
      expect(g.isSpentAt(_nowMs), isTrue);
    });

    test('a cancellation before the start clamps into the window', () {
      final g = _grant(startOffsetMs: 60000).cancelledAt(_nowMs);
      expect(g.cancelledMs, g.startMs);
    });

    test('the wire carries exactly the three keys native reads', () {
      expect(
        _grant().toWire(),
        {
          'targetType': 'APP',
          'targetId': 'com.instagram.android',
          'endMs': _nowMs + 15 * 60000,
        },
        reason:
            'startMs has already passed, cancelled rows never ship, and source '
            'is Dart-side bookkeeping',
      );
    });

    test('round-trips through JSON', () {
      final g = _grant(source: UnblockSource.blocklistRow);
      expect(
        TemporaryUnblock.fromJson(
          jsonDecode(jsonEncode(g.toJson())) as Map<String, dynamic>,
        ),
        g,
      );
    });

    test('a host is normalised on the way IN, not by the constructor', () {
      // Native lower-cases the pushed id too, so a stored mixed-case host would
      // silently never match. Both readers (`fromJson` and `UnblockCubit.grant`)
      // normalise; the entity itself stays dumb.
      final back = TemporaryUnblock.fromJson(
        _grant(type: UnblockTargetType.website, id: 'YouTube.com').toJson(),
      );
      expect(back!.targetId, 'youtube.com');
    });

    test('an unusable row is dropped rather than half-parsed', () {
      expect(
        TemporaryUnblock.fromJson({'targetType': 'GALAXY', 'targetId': 'x'}),
        isNull,
      );
      expect(
        TemporaryUnblock.fromJson({'targetType': 'APP', 'targetId': '  '}),
        isNull,
      );
      expect(
        TemporaryUnblock.fromJson({
          'targetType': 'APP',
          'targetId': 'a',
          'startMs': 100,
          'endMs': 100,
        }),
        isNull,
        reason: 'an inverted or empty window can never be active',
      );
    });

    test('a wrong-typed field degrades that field, never the row', () {
      final g = TemporaryUnblock.fromJson({
        'targetType': 'APP',
        'targetId': 'com.x',
        'startMs': 0,
        'endMs': 10,
        'cancelledMs': 'nonsense',
        'source': 42,
      });
      expect(g, isNotNull);
      expect(g!.cancelledMs, isNull);
      expect(g.source, UnblockSource.wall);
    });
  });

  group('UnblockQuota — grants', () {
    test('activeAt ignores cancelled, future and finished rows', () {
      final live = _grant();
      final rows = [
        live,
        _grant(id: 'com.cancelled', cancelledMs: _nowMs),
        _grant(id: 'com.future', startOffsetMs: 60000),
        _grant(id: 'com.done', startOffsetMs: -60 * 60000),
      ];
      expect(UnblockQuota.activeAt(rows, _nowMs), [live]);
    });

    test('prune drops spent rows and caps the list', () {
      final rows = [
        for (var i = 0; i < maxTemporaryUnblocks + 5; i++)
          _grant(id: 'com.app$i'),
        _grant(id: 'com.done', startOffsetMs: -60 * 60000),
      ];
      final pruned = UnblockQuota.prune(rows, _nowMs);
      expect(pruned, hasLength(maxTemporaryUnblocks));
      expect(pruned.map((g) => g.targetId), isNot(contains('com.done')));
    });

    test('nextExpiryMs is the soonest live end, 0 with none', () {
      expect(UnblockQuota.nextExpiryMs(const [], _nowMs), 0);
      expect(
        UnblockQuota.nextExpiryMs([
          _grant(minutes: 30),
          _grant(id: 'com.b', minutes: 5),
        ], _nowMs),
        _nowMs + 5 * 60000,
      );
    });

    test('activeFor matches on type AND id, never one alone', () {
      final rows = [_grant()];
      expect(
        UnblockQuota.activeFor(
          rows,
          UnblockTargetType.app,
          'com.instagram.android',
          _nowMs,
        ),
        isNotNull,
      );
      expect(
        UnblockQuota.activeFor(
          rows,
          UnblockTargetType.reel,
          'com.instagram.android',
          _nowMs,
        ),
        isNull,
        reason: 'unblocking the app must not unblock its reels',
      );
    });
  });

  group('UnblockCubit', () {
    late _MockEngine engine;

    UnblockCubit build({_FakeGrants? grants, _FakeLedger? ledger}) =>
        UnblockCubit(
          grants ?? _FakeGrants(),
          ledger ?? _FakeLedger(),
          engine,
          clock: () => _now,
        );

    List<Map<String, dynamic>> lastPushed() {
      final calls = verify(
        () => engine.pushTemporaryUnblocks(captureAny()),
      ).captured;
      return [
        for (final m in jsonDecode(calls.last as String) as List<dynamic>)
          Map<String, dynamic>.from(m as Map),
      ];
    }

    setUp(() {
      engine = _MockEngine();
      when(() => engine.pushTemporaryUnblocks(any())).thenAnswer((_) async {});
      when(() => engine.takePendingUnblock()).thenAnswer((_) async => null);
      when(() => engine.takeNativeGrants()).thenAnswer((_) async => null);
    });

    test('a grant pushes exactly the wire shape', () async {
      final c = build();
      await c.load();
      expect(
        await c.grant(
          UnblockTargetType.app,
          'com.instagram.android',
          const Duration(minutes: 15),
        ),
        isTrue,
      );
      final pushed = lastPushed().single;
      expect(pushed['targetType'], 'APP');
      expect(pushed['targetId'], 'com.instagram.android');
      expect(pushed['endMs'], _nowMs + 15 * 60000);
      await c.close();
    });

    test('alsoFree mints one grant per alias', () async {
      final c = build();
      await c.load();
      await c.grant(
        UnblockTargetType.website,
        'youtube.com',
        const Duration(minutes: 5),
        source: UnblockSource.blocklistRow,
        alsoFree: const ['youtu.be'],
      );
      expect(
        lastPushed().map((m) => m['targetId']),
        unorderedEquals(<String>['youtube.com', 'youtu.be']),
        reason:
            'aliases ride the blocklist wire as their own patterns, so they '
            'need their own grants — exactly what the pause did',
      );
      await c.close();
    });

    test('a second grant on the same target replaces, never stacks', () async {
      final c = build();
      await c.load();
      await c.grant(UnblockTargetType.app, 'com.x', const Duration(minutes: 5));
      await c.grant(
        UnblockTargetType.app,
        'com.x',
        const Duration(minutes: 30),
      );
      expect(c.state.grants, hasLength(1));
      expect(c.state.grants.single.endMs, _nowMs + 30 * 60000);
      await c.close();
    });

    test(
      'EVO-053 a rationed budget refuses before it writes anything',
      () async {
        final grants = _FakeGrants();
        final ledger = _FakeLedger(
          const BypassLedger(config: BypassConfig(grantLimit: 1)),
        );
        final c = build(grants: grants, ledger: ledger);
        await c.load();
        expect(c.state.grantsLeft, 1);

        expect(
          await c.grant(UnblockTargetType.app, 'com.x', _fifteenMin),
          isTrue,
        );
        expect(c.state.grantsLeft, 0);

        final before = c.state.grants;
        expect(
          await c.grant(UnblockTargetType.app, 'com.y', _fifteenMin),
          isFalse,
          reason: 'the budget is spent',
        );
        expect(c.state.error, UnblockCubit.noGrantsLeft);
        expect(
          c.state.grants,
          before,
          reason: 'a refusal must leave nothing half-written',
        );
        await c.close();
      },
    );

    test(
      'EVO-053 one user action spends one allowance, aliases included',
      () async {
        final ledger = _FakeLedger(
          const BypassLedger(config: BypassConfig(grantLimit: 2)),
        );
        final c = build(ledger: ledger);
        await c.load();
        await c.grant(
          UnblockTargetType.website,
          'x.com',
          _fifteenMin,
          alsoFree: const ['twitter.com'],
        );
        expect(c.state.active, hasLength(2), reason: 'two grants');
        expect(
          c.state.ledger.where((e) => e.kind == BypassKind.grant),
          hasLength(1),
          reason: 'freeing a site and its alias is ONE decision, so one spend',
        );
        expect(c.state.grantsLeft, 1);
        await c.close();
      },
    );

    test(
      'EVO-053 unlimited is the default and still records history',
      () async {
        final c = build();
        await c.load();
        expect(c.state.grantsLeft, isNull);
        await c.grant(UnblockTargetType.app, 'com.x', _fifteenMin);
        expect(
          c.state.ledger.where((e) => e.kind == BypassKind.grant),
          hasLength(1),
          reason: 'a budget switched on tomorrow needs today to mean something',
        );
        expect(c.state.grantsLeft, isNull);
        await c.close();
      },
    );

    test('EVO-050 a grant taken on the wall survives the next push', () async {
      final c = build();
      await c.load();
      // Native already enforces this row; Hive has never seen it, and the push
      // `load()` just made would delete it on the next resync.
      when(() => engine.takeNativeGrants()).thenAnswer(
        (_) async => jsonEncode([
          {
            'targetType': 'APP',
            'targetId': 'com.instagram.android',
            'endMs': _nowMs + 30 * 60000,
          },
        ]),
      );
      await c.absorbNativeGrants();
      expect(c.state.active, hasLength(1));
      expect(c.state.active.single.targetId, 'com.instagram.android');
      expect(
        lastPushed().single['targetId'],
        'com.instagram.android',
        reason: 'the very next push must carry it, not erase it',
      );
      expect(
        c.state.ledger.where((e) => e.kind == BypassKind.grant),
        hasLength(1),
        reason: 'a wall grant is a spend like any other',
      );
      await c.close();
    });

    test('EVO-050 an expired or malformed native row is dropped', () async {
      final c = build();
      await c.load();
      when(() => engine.takeNativeGrants()).thenAnswer(
        (_) async => jsonEncode([
          {'targetType': 'APP', 'targetId': 'com.x', 'endMs': _nowMs - 1},
          {
            'targetType': 'GALAXY',
            'targetId': 'com.y',
            'endMs': _nowMs + 60000,
          },
          {'targetType': 'APP', 'targetId': '  ', 'endMs': _nowMs + 60000},
          'not an object',
        ]),
      );
      await c.absorbNativeGrants();
      expect(c.state.active, isEmpty);
      await c.close();
    });

    test('endEarly also ends the aliases the same tap freed', () async {
      final c = build();
      await c.load();
      // What a popular website row does: one action, one grant per alias.
      await c.grant(
        UnblockTargetType.website,
        'x.com',
        const Duration(minutes: 30),
        alsoFree: const ['twitter.com'],
      );
      expect(c.state.active, hasLength(2));
      await c.endEarly(
        UnblockTargetType.website,
        'x.com',
        alsoEnd: const ['twitter.com'],
      );
      expect(
        c.state.active,
        isEmpty,
        reason:
            'ending only the exact id left twitter.com open for the rest of '
            'the window while the row read as protected again',
      );
      expect(lastPushed(), isEmpty);
      await c.close();
    });

    test(
      'a website grant is matched case-insensitively on the way out',
      () async {
        final c = build();
        await c.load();
        await c.grant(
          UnblockTargetType.website,
          'YouTube.com',
          const Duration(minutes: 30),
        );
        expect(c.state.grants, hasLength(1));
        expect(c.state.grants.single.targetId, 'youtube.com');
        // A second grant on the same host REPLACES rather than stacking, which
        // it could not do while the replace scan compared raw input against
        // lower-cased stored ids.
        await c.grant(
          UnblockTargetType.website,
          'YOUTUBE.COM',
          const Duration(minutes: 5),
        );
        expect(c.state.grants, hasLength(1));
        await c.endEarly(UnblockTargetType.website, 'YouTube.com');
        expect(c.state.active, isEmpty);
        await c.close();
      },
    );

    test('a corrupt ledger disables the quota, not the grants', () async {
      final grants = _FakeGrants();
      await grants.save([_grant()]);
      final ledger = _FakeLedger()..throwOnLoad = true;
      final c = build(grants: grants, ledger: ledger);
      await c.load();
      expect(c.state.error, UnblockCubit.loadFailed);
      expect(
        c.state.loaded,
        isTrue,
        reason:
            'returning early here left every grant and "end early" refused for '
            'the life of the process, and native never re-pushed',
      );
      expect(c.state.active, hasLength(1));
      expect(lastPushed(), hasLength(1));
      await c.close();
    });

    test('endEarly restores protection now and stops pushing it', () async {
      final c = build();
      await c.load();
      await c.grant(
        UnblockTargetType.app,
        'com.x',
        const Duration(minutes: 30),
      );
      expect(c.state.active, hasLength(1));
      await c.endEarly(UnblockTargetType.app, 'com.x');
      expect(c.state.active, isEmpty);
      expect(
        lastPushed(),
        isEmpty,
        reason: 'native must re-block immediately, not at endMs',
      );
      await c.close();
    });

    test('the derived active list changes when a grant lapses', () async {
      // The whole reason M8 needs no `temporaryUnblockExpired` event: a cubit
      // whose state holds only the raw rows would emit an EQUAL state on the
      // timer tick, `emit` would no-op, and a dead countdown would stay on
      // screen. This pins that `active` actually moves.
      var clock = _now;
      final c = UnblockCubit(
        _FakeGrants(),
        _FakeLedger(),
        engine,
        clock: () => clock,
      );
      await c.load();
      await c.grant(UnblockTargetType.app, 'com.x', const Duration(minutes: 5));
      final before = c.state;
      expect(before.active, hasLength(1));
      clock = _now.add(const Duration(minutes: 6));
      await c.resync();
      expect(c.state.active, isEmpty);
      expect(c.state, isNot(before), reason: 'props must actually change');
      await c.close();
    });

    test(
      'a failed load refuses every mutation, never writing over it',
      () async {
        final repo = _ThrowingGrants();
        final c = build(grants: _FakeGrants());
        // Load succeeded here; now prove the guard itself by building one that
        // never loaded.
        await c.close();
        final blind = UnblockCubit(
          repo,
          _FakeLedger(),
          engine,
          clock: () => _now,
        );
        expect(
          await blind.grant(
            UnblockTargetType.app,
            'com.x',
            const Duration(minutes: 5),
          ),
          isFalse,
        );
        expect(repo.savedCalled, isFalse);
        expect(blind.state.error, UnblockCubit.loadFailed);
        await blind.close();
      },
    );

    test(
      'a corrupt store aborts the push instead of clearing native',
      () async {
        final c = UnblockCubit(
          _ThrowingGrants(),
          _FakeLedger(),
          engine,
          clock: () => _now,
        );
        await c.resync();
        verifyNever(() => engine.pushTemporaryUnblocks(any()));
        await c.close();
      },
    );

    test('a pending wall tap is parsed and consumed once', () async {
      when(
        () => engine.takePendingUnblock(),
      ).thenAnswer((_) async => 'APP|com.instagram.android');
      final c = build();
      await c.load();
      await c.takePending();
      expect(c.state.pending?.targetType, UnblockTargetType.app);
      expect(c.state.pending?.targetId, 'com.instagram.android');
      c.clearPending();
      expect(c.state.pending, isNull);
      await c.close();
    });

    test('a malformed pending value is dropped, not shown', () async {
      for (final raw in ['', 'APP', '|com.x', 'APP|', 'NOPE|com.x']) {
        expect(PendingUnblock.parse(raw), isNull, reason: 'for "$raw"');
      }
      expect(
        PendingUnblock.parse('WEBSITE|example.com')?.targetId,
        'example.com',
      );
    });
  });

  group('migrateWebPauses', () {
    Future<void> seed(_FakeStore store, {int? pausedUntil}) => store.write(
      StoreKeys.webBlocklist,
      jsonEncode([
        {
          'pattern': 'youtube.com',
          'matchType': 'DOMAIN',
          'enabled': true,
          'source': 'POPULAR',
          'pausedUntil': ?pausedUntil,
        },
      ]),
    );

    test('a live pause becomes a grant, and its aliases too', () async {
      final store = _FakeStore();
      final grants = _FakeGrants();
      await seed(store, pausedUntil: _nowMs + 5 * 60000);
      await migrateWebPauses(store, grants, now: () => _now);
      expect(
        grants.saved!.map((g) => g.targetId),
        containsAll(<String>['youtube.com', 'youtu.be']),
      );
      expect(grants.saved!.first.endMs, _nowMs + 5 * 60000);
      expect(grants.saved!.first.targetType, UnblockTargetType.website);
    });

    test('it strips the field, so it can never run twice', () async {
      final store = _FakeStore();
      final grants = _FakeGrants();
      await seed(store, pausedUntil: _nowMs + 5 * 60000);
      await migrateWebPauses(store, grants, now: () => _now);
      expect(
        store.read(StoreKeys.webBlocklist),
        isNot(contains('pausedUntil')),
      );

      grants.saved = null;
      await migrateWebPauses(store, grants, now: () => _now);
      expect(grants.saved, isNull, reason: 'idempotent');
    });

    test('an already-expired pause carries nothing over', () async {
      final store = _FakeStore();
      final grants = _FakeGrants();
      await seed(store, pausedUntil: _nowMs - 1);
      await migrateWebPauses(store, grants, now: () => _now);
      expect(grants.saved, isNull, reason: 'nothing to save');
      expect(
        store.read(StoreKeys.webBlocklist),
        isNot(contains('pausedUntil')),
      );
    });

    test('a blocklist with no pause is untouched', () async {
      final store = _FakeStore();
      final grants = _FakeGrants();
      await seed(store);
      final before = store.read(StoreKeys.webBlocklist);
      await migrateWebPauses(store, grants, now: () => _now);
      expect(store.read(StoreKeys.webBlocklist), before);
      expect(grants.saved, isNull);
    });

    test('a corrupt blob is survived, not thrown', () async {
      final store = _FakeStore();
      await store.write(StoreKeys.webBlocklist, '{pausedUntil oops');
      await expectLater(
        migrateWebPauses(store, _FakeGrants(), now: () => _now),
        completes,
      );
    });
  });
}
