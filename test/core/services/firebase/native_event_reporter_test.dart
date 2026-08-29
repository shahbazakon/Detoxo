import 'dart:async';

import 'package:detoxo/core/constants/channel_constants.dart';
import 'package:detoxo/core/platform_channels/engine_channel.dart';
import 'package:detoxo/core/services/firebase/analytics/analytics_service.dart';
import 'package:detoxo/core/services/firebase/analytics/native_event_reporter.dart';
import 'package:detoxo/core/services/firebase/crashlytics/crash_reporting_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockEngine extends Mock implements EngineChannel {}

class _MockAnalytics extends Mock implements AnalyticsService {}

class _MockCrash extends Mock implements CrashReportingService {}

void main() {
  late StreamController<Map<String, dynamic>> controller;
  late _MockEngine engine;
  late _MockAnalytics analytics;
  late _MockCrash crash;
  late FirebaseNativeEventReporter reporter;

  setUpAll(() => registerFallbackValue(Object()));

  setUp(() {
    controller = StreamController<Map<String, dynamic>>.broadcast();
    engine = _MockEngine();
    analytics = _MockAnalytics();
    crash = _MockCrash();
    when(engine.events).thenAnswer((_) => controller.stream);
    when(
      () => analytics.logBlockTriggered(
        platform: any(named: 'platform'),
        mode: any(named: 'mode'),
      ),
    ).thenAnswer((_) async {});
    when(() => analytics.logReelsCounted(any())).thenAnswer((_) async {});
    when(
      () => analytics.logWebBlocked(mode: any(named: 'mode')),
    ).thenAnswer((_) async {});
    when(
      () => analytics.logBlockScreenAction(action: any(named: 'action')),
    ).thenAnswer((_) async {});
    when(() => crash.setKey(any(), any())).thenAnswer((_) async {});
    reporter = FirebaseNativeEventReporter(engine, analytics, crash)..start();
  });

  tearDown(() async {
    await reporter.dispose();
    await controller.close();
  });

  // Lets the broadcast stream deliver queued events to the listener.
  Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 10));

  test('blocked event logs block_triggered and updates crash keys', () async {
    controller.add({
      'type': ChannelEvents.blocked,
      'platformId': 'youtube',
      'mode': 'PRESS_BACK',
      'today': 3,
      'total': 10,
    });
    await pump();

    verify(
      () =>
          analytics.logBlockTriggered(platform: 'youtube', mode: 'PRESS_BACK'),
    ).called(1);
    verify(() => crash.setKey('blocks_today', 3)).called(1);
    verify(() => crash.setKey('blocks_total', 10)).called(1);
  });

  test('webBlocked logs web_blocked WITHOUT the host', () async {
    controller.add({
      'type': ChannelEvents.webBlocked,
      'host': 'private.example.com',
      'mode': 'PRESS_BACK',
    });
    await pump();

    verify(() => analytics.logWebBlocked(mode: 'PRESS_BACK')).called(1);
    // The host is never forwarded.
    verifyNever(
      () => analytics.logBlockTriggered(
        platform: any(named: 'platform'),
        mode: any(named: 'mode'),
      ),
    );
  });

  test('blockScreenAction logs the action token only', () async {
    controller.add({
      'type': ChannelEvents.blockScreenAction,
      'action': 'GO_HOME',
      'referenceType': 'WEBSITE',
      'referenceId': 'private.example.com',
      'preview': false,
    });
    await pump();

    verify(() => analytics.logBlockScreenAction(action: 'GO_HOME')).called(1);
  });

  test('a preview wall from the editor is not an intervention', () async {
    controller.add({
      'type': ChannelEvents.blockScreenAction,
      'action': 'DISMISS',
      'preview': true,
    });
    await pump();

    verifyNever(
      () => analytics.logBlockScreenAction(action: any(named: 'action')),
    );
  });

  test('reels are batched and flushed once the threshold is reached', () async {
    for (var i = 0; i < 25; i++) {
      controller.add({'type': ChannelEvents.contentCounted, 'today': i});
    }
    await pump();

    verify(() => analytics.logReelsCounted(25)).called(1);
  });

  test('sub-threshold reels are flushed on dispose', () async {
    controller
      ..add({'type': ChannelEvents.contentCounted})
      ..add({'type': ChannelEvents.contentCounted});
    await pump();
    verifyNever(() => analytics.logReelsCounted(any()));

    await reporter.dispose();
    verify(() => analytics.logReelsCounted(2)).called(1);
  });
}
