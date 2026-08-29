import 'package:detoxo/features/blocking/shared/domain/repositories/blocking_repositories.dart';
import 'package:detoxo/features/limits/app_blocker/domain/app_block_sync.dart';
import 'package:detoxo/features/limits/app_blocker/domain/entities/app_block_entry.dart';
import 'package:detoxo/features/limits/app_blocker/domain/repositories/app_block_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockEngine extends Mock implements EngineRepository {}

class _FakeRepo implements AppBlockRepository {
  _FakeRepo(this.entries);
  final List<AppBlockEntry> entries;

  @override
  Future<List<AppBlockEntry>> load() async => entries;

  @override
  Future<void> save(List<AppBlockEntry> entries) async {}
}

class _ThrowingRepo implements AppBlockRepository {
  @override
  Future<List<AppBlockEntry>> load() async => throw StateError('corrupt');

  @override
  Future<void> save(List<AppBlockEntry> entries) async {}
}

void main() {
  late _MockEngine engine;

  setUp(() {
    engine = _MockEngine();
    when(() => engine.pushAppBlocklist(any())).thenAnswer((_) async {});
  });

  test('pushes only the enabled package names', () async {
    await syncAppBlocklist(
      _FakeRepo(const [
        AppBlockEntry(packageName: 'com.a.on', appName: 'On'),
        AppBlockEntry(packageName: 'com.b.off', appName: 'Off', enabled: false),
        AppBlockEntry(packageName: 'com.c.on', appName: 'On2'),
      ]),
      engine,
    );
    verify(() => engine.pushAppBlocklist(['com.a.on', 'com.c.on'])).called(1);
  });

  test('an empty-but-valid list pushes [] (explicit clear)', () async {
    await syncAppBlocklist(_FakeRepo(const []), engine);
    verify(() => engine.pushAppBlocklist([])).called(1);
  });

  test('a failed load aborts the push — never wipes native', () async {
    await syncAppBlocklist(_ThrowingRepo(), engine);
    verifyNever(() => engine.pushAppBlocklist(any()));
  });
}
