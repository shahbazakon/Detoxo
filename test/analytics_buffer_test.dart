import 'dart:async';
import 'dart:convert';

import 'package:detoxo/core/storage/local_store.dart';
import 'package:detoxo/features/analytics/data/repositories/analytics_repository_impl.dart';
import 'package:detoxo/features/analytics/presentation/analytics_cubit.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/engine_event.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/enums.dart';
import 'package:detoxo/features/blocking/shared/domain/repositories/blocking_repositories.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockEngine extends Mock implements EngineRepository {}

/// In-memory [LocalStore] whose writes can be made slow, so two appends can be
/// made to overlap deliberately.
class _FakeStore implements LocalStore {
  final Map<String, String> values = {};
  Duration writeDelay = Duration.zero;
  int writes = 0;

  @override
  String? read(String key) => values[key];

  @override
  Future<void> write(String key, String value) async {
    writes++;
    if (writeDelay > Duration.zero) await Future<void>.delayed(writeDelay);
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnsupportedError('${i.memberName} not used here');
}

BlockEvent _block(String id) => BlockEvent(
  platformId: id,
  packageName: 'com.example.$id',
  mode: BlockingMode.pressBack,
  timestamp: DateTime(2026, 9, 2, 12),
);

int _stored(_FakeStore store) =>
    (jsonDecode(store.values[StoreKeys.analyticsEvents]!) as List).length;

void main() {
  test('concurrent appends never drop an event', () async {
    // Overlapping read-modify-writes on one Hive key used to lose all but the
    // last — the user's own block history, silently short.
    final store = _FakeStore()..writeDelay = const Duration(milliseconds: 5);
    final repo = AnalyticsRepositoryImpl(store);

    await Future.wait([
      repo.logBlock(_block('a')),
      repo.logBlock(_block('b')),
      repo.logBlock(_block('c')),
    ]);

    expect(_stored(store), 3);
    final ids = (await repo.recent(limit: 10)).map((e) => e.platformId);
    expect(ids, containsAll(['a', 'b', 'c']));
  });

  test('a wipe is not undone by a stale in-memory buffer', () async {
    final store = _FakeStore();
    final repo = AnalyticsRepositoryImpl(store);
    await repo.logBlock(_block('before'));

    // "Reset app data" clears the box underneath the singleton repo.
    store.values.clear();
    await repo.logBlock(_block('after'));

    final ids = (await repo.recent(limit: 10)).map((e) => e.platformId);
    expect(ids, ['after']);
    expect(ids, isNot(contains('before')));
  });

  test('closing the cubit cancels its block-stream subscription', () async {
    final engine = _MockEngine();
    final store = _FakeStore();
    final blocks = StreamController<BlockEvent>.broadcast();
    when(engine.blockStream).thenAnswer((_) => blocks.stream);

    final cubit = AnalyticsCubit(AnalyticsRepositoryImpl(store), engine);
    await Future<void>.delayed(Duration.zero);
    expect(blocks.hasListener, isTrue);

    await cubit.close();

    // Without the cancel every mount left a permanent writer behind.
    expect(blocks.hasListener, isFalse);
    await blocks.close();
  });

  test('events after close are not persisted by a dead cubit', () async {
    final engine = _MockEngine();
    final store = _FakeStore();
    final blocks = StreamController<BlockEvent>.broadcast();
    when(engine.blockStream).thenAnswer((_) => blocks.stream);

    final cubit = AnalyticsCubit(AnalyticsRepositoryImpl(store), engine);
    await Future<void>.delayed(Duration.zero);
    await cubit.close();

    blocks.add(_block('ghost'));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(store.values[StoreKeys.analyticsEvents], isNull);
    expect(store.writes, 0);
    await blocks.close();
  });
}
