import 'dart:async';

import 'package:detoxo/core/platform_channels/engine_channel.dart';
import 'package:detoxo/core/platform_channels/installed_app.dart';
import 'package:detoxo/features/blocking/shared/data/repositories/engine_repository_impl.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockChannel extends Mock implements EngineChannel {}

void main() {
  const bravo = InstalledApp(packageName: 'com.b', appName: 'Bravo');
  const alpha = InstalledApp(packageName: 'com.a', appName: 'alpha');

  late _MockChannel channel;
  late EngineRepositoryImpl repo;

  setUp(() {
    channel = _MockChannel();
    repo = EngineRepositoryImpl(channel);
  });

  test('caches the first successful scan and sorts by name', () async {
    when(() => channel.installedApps()).thenAnswer((_) async => [bravo, alpha]);

    final first = await repo.installedApps();
    final second = await repo.installedApps();

    // Case-insensitive name order, one native scan for both calls.
    expect(first, [alpha, bravo]);
    expect(identical(first, second), isTrue);
    verify(() => channel.installedApps()).called(1);
  });

  test('refresh forces a rescan', () async {
    when(() => channel.installedApps()).thenAnswer((_) async => [alpha]);

    await repo.installedApps();
    await repo.installedApps(refresh: true);

    verify(() => channel.installedApps()).called(2);
  });

  test('a null (transient) failure is never cached', () async {
    when(() => channel.installedApps()).thenAnswer((_) async => null);

    expect(await repo.installedApps(), isNull);
    expect(await repo.installedApps(), isNull);

    // Both calls hit the channel — nothing was pinned by the failure.
    verify(() => channel.installedApps()).called(2);
  });

  test('concurrent misses share one in-flight native scan', () async {
    final scan = Completer<List<InstalledApp>?>();
    when(() => channel.installedApps()).thenAnswer((_) => scan.future);

    final first = repo.installedApps();
    final second = repo.installedApps();
    scan.complete([alpha]);

    expect(await first, [alpha]);
    expect(await second, [alpha]);
    verify(() => channel.installedApps()).called(1);
  });

  test('a failed refresh serves the stale cache instead of nothing', () async {
    when(() => channel.installedApps()).thenAnswer((_) async => [alpha]);
    final cached = await repo.installedApps();

    when(() => channel.installedApps()).thenAnswer((_) async => null);
    final afterFailure = await repo.installedApps(refresh: true);

    expect(afterFailure, cached);
  });
}
