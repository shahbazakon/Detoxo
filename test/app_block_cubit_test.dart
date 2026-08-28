import 'package:detoxo/features/limits/app_blocker/domain/entities/app_block_entry.dart';
import 'package:detoxo/features/limits/app_blocker/domain/repositories/app_block_repository.dart';
import 'package:detoxo/features/limits/app_blocker/presentation/app_block_cubit.dart';
import 'package:detoxo/features/protected_apps/protected_apps.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeRepo implements AppBlockRepository {
  List<AppBlockEntry>? saved;
  bool failLoad = false;
  bool failSave = false;

  @override
  Future<List<AppBlockEntry>> load() async {
    if (failLoad) throw const FormatException('corrupt blob');
    return saved ?? const [];
  }

  @override
  Future<void> save(List<AppBlockEntry> entries) async {
    if (failSave) throw Exception('disk full');
    saved = entries;
  }
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

  test('a corrupt blob loads as empty instead of throwing', () async {
    final repo = _FakeRepo()..failLoad = true;
    final cubit = AppBlockCubit(repo);
    await cubit.load(); // must not throw: the screen fires this unawaited
    expect(cubit.state, isEmpty);
  });

  test('a failed save reverts the list, reports failed, never syncs', () async {
    final repo = _FakeRepo();
    var calls = 0;
    final cubit = AppBlockCubit(repo, onChanged: () async => calls++);
    await cubit.add('com.ok.app', 'Ok');
    repo.failSave = true;

    expect(await cubit.add('com.other.app', 'Other'), AppBlockAddResult.failed);
    expect(cubit.state.map((e) => e.packageName), ['com.ok.app']);
    await cubit.toggle(0, enabled: false);
    expect(cubit.state.single.enabled, isTrue, reason: 'toggle not reverted');
    expect(repo.saved!.single.packageName, 'com.ok.app');
    expect(calls, 1, reason: 'onChanged must not fire for a failed save');
  });
}
