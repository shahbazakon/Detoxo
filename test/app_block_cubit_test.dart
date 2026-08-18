import 'package:detoxo/features/limits/app_blocker/domain/entities/app_block_entry.dart';
import 'package:detoxo/features/limits/app_blocker/domain/repositories/app_block_repository.dart';
import 'package:detoxo/features/limits/app_blocker/presentation/app_block_cubit.dart';
import 'package:detoxo/features/protected_apps/protected_apps.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeRepo implements AppBlockRepository {
  List<AppBlockEntry>? saved;

  @override
  Future<List<AppBlockEntry>> load() async => saved ?? const [];

  @override
  Future<void> save(List<AppBlockEntry> entries) async => saved = entries;
}

void main() {
  test('add refuses sensitive catalog packages and never saves', () async {
    final repo = _FakeRepo();
    final cubit = AppBlockCubit(repo);
    final result = await cubit.add(
      ProtectedAppCatalog.apps.first.packageName,
      'Bank',
    );
    expect(result, AppBlockAddResult.sensitive);
    expect(cubit.state, isEmpty);
    expect(repo.saved, isNull);
  });

  test('add still accepts a normal package', () async {
    final repo = _FakeRepo();
    final cubit = AppBlockCubit(repo);
    expect(await cubit.add('com.ok.app', 'Ok'), AppBlockAddResult.added);
    expect(cubit.state.single.packageName, 'com.ok.app');
    expect(repo.saved, cubit.state);
  });

  test('add reports duplicates and garbage without saving', () async {
    final repo = _FakeRepo();
    final cubit = AppBlockCubit(repo);
    await cubit.add('com.ok.app', 'Ok');

    expect(await cubit.add('com.ok.app', 'Again'), AppBlockAddResult.duplicate);
    expect(await cubit.add('not a package', 'X'), AppBlockAddResult.invalid);
    expect(await cubit.add('nodots', 'X'), AppBlockAddResult.invalid);
    // Real-world casing survives (com.Slack is a genuine application id).
    expect(await cubit.add('com.Slack', 'Slack'), AppBlockAddResult.added);
    expect(cubit.state, hasLength(2));
  });

  test('every persisted mutation fires onChanged exactly once', () async {
    final repo = _FakeRepo();
    var calls = 0;
    final cubit = AppBlockCubit(repo, onChanged: () async => calls++);

    await cubit.add('com.ok.app', 'Ok');
    expect(calls, 1);
    await cubit.toggle(0, enabled: false);
    expect(calls, 2);
    await cubit.removeAt(0);
    expect(calls, 3);

    // Refused adds never commit, so they never fire it.
    await cubit.add('not a package', 'X');
    expect(calls, 3);
  });
}
