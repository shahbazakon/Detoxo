import 'package:detoxo/core/constants/channel_constants.dart';
import 'package:detoxo/core/platform_channels/engine_channel.dart';
import 'package:detoxo/features/usage/data/repositories/usage_repository_impl.dart';
import 'package:detoxo/features/usage/usage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockChannel extends Mock implements EngineChannel {}

/// The usage layer's one promise: "not allowed to look" and "didn't answer"
/// never degrade into an empty list a screen could print as `0 m` (EVO-014).
void main() {
  late _MockChannel channel;
  late UsageRepositoryImpl repo;
  final start = DateTime(2026, 9, 2);
  final end = DateTime(2026, 9, 3);

  setUp(() {
    channel = _MockChannel();
    repo = UsageRepositoryImpl(channel);
  });

  void stubUsage(Future<List<Map<String, dynamic>>?> Function() answer) {
    when(
      () => channel.queryAppUsage(
        startMillis: any(named: 'startMillis'),
        endMillis: any(named: 'endMillis'),
      ),
    ).thenAnswer((_) => answer());
  }

  void stubEvents(Future<List<Map<String, dynamic>>?> Function() answer) {
    when(
      () => channel.queryUsageEvents(
        startMillis: any(named: 'startMillis'),
        endMillis: any(named: 'endMillis'),
      ),
    ).thenAnswer((_) => answer());
  }

  test('denied → UsageDenied, never an empty list', () async {
    stubUsage(() => throw PlatformException(code: 'USAGE_ACCESS_DENIED'));
    final r = await repo.queryAppUsage(start, end);
    expect(r, isA<UsageDenied<List<AppUsage>>>());
    expect(r.isGranted, isFalse);
    expect(r.dataOrNull, isNull);
  });

  test('no native side (null) → UsageUnavailable', () async {
    stubUsage(() async => null);
    expect(
      await repo.queryAppUsage(start, end),
      isA<UsageUnavailable<List<AppUsage>>>(),
    );
  });

  test('any other channel failure → UsageUnavailable', () async {
    stubEvents(() => throw PlatformException(code: 'USAGE_QUERY_FAILED'));
    expect(
      await repo.queryUsageEvents(start, end),
      isA<UsageUnavailable<List<UsageEvent>>>(),
    );
  });

  test('a normal usage response maps cleanly and passes the bounds', () async {
    stubUsage(
      () async => [
        {'package': 'com.instagram.android', 'foregroundMillis': 5000},
        {'package': 'com.whatsapp', 'foregroundMillis': 120},
      ],
    );
    final r = await repo.queryAppUsage(start, end);
    expect(r.dataOrNull, [
      const AppUsage(package: 'com.instagram.android', foregroundMillis: 5000),
      const AppUsage(package: 'com.whatsapp', foregroundMillis: 120),
    ]);
    verify(
      () => channel.queryAppUsage(
        startMillis: start.millisecondsSinceEpoch,
        endMillis: end.millisecondsSinceEpoch,
      ),
    ).called(1);
  });

  test('events map to the two modelled types and drop the rest', () async {
    stubEvents(
      () async => [
        {'package': 'com.a', 'type': 1, 'timestampMillis': 10},
        {'package': 'android', 'type': 18, 'timestampMillis': 20},
        {'package': 'com.b', 'type': 23, 'timestampMillis': 30},
        {'package': '', 'type': 1, 'timestampMillis': 40},
      ],
    );
    final r = await repo.queryUsageEvents(start, end);
    expect(r.dataOrNull, [
      const UsageEvent(
        package: 'com.a',
        type: UsageEventType.moveToForeground,
        timestampMillis: 10,
      ),
      const UsageEvent(
        package: 'android',
        type: UsageEventType.screenInteractive,
        timestampMillis: 20,
      ),
    ]);
  });

  test('BAD_ARGS from native surfaces as an ArgumentError', () async {
    stubUsage(() => throw PlatformException(code: 'BAD_ARGS'));
    expect(() => repo.queryAppUsage(start, end), throwsArgumentError);
  });

  test('an inverted window is refused before the channel is touched', () async {
    expect(() => repo.queryAppUsage(end, start), throwsArgumentError);
    expect(() => repo.queryUsageEvents(start, start), throwsArgumentError);
    verifyNever(
      () => channel.queryAppUsage(
        startMillis: any(named: 'startMillis'),
        endMillis: any(named: 'endMillis'),
      ),
    );
  });

  test('hasAccess passes the tri-state through untouched', () async {
    when(
      () => channel.invokeBoolOrNull(ChannelMethods.hasUsageAccess),
    ).thenAnswer((_) async => null);
    expect(await repo.hasAccess(), isNull);
    when(
      () => channel.invokeBoolOrNull(ChannelMethods.hasUsageAccess),
    ).thenAnswer((_) async => false);
    expect(await repo.hasAccess(), isFalse);
  });

  test('UsageEventType.fromRaw models exactly 1 and 18', () {
    expect(UsageEventType.fromRaw(1), UsageEventType.moveToForeground);
    expect(UsageEventType.fromRaw(18), UsageEventType.screenInteractive);
    expect(UsageEventType.fromRaw(2), isNull);
    expect(UsageEventType.fromRaw(null), isNull);
  });
}
