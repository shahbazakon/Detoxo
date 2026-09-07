import 'package:detoxo/core/services/firebase/analytics/analytics_service.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockFirebaseAnalytics extends Mock implements FirebaseAnalytics {}

void main() {
  late _MockFirebaseAnalytics fa;
  late FirebaseAnalyticsService service;

  setUp(() {
    fa = _MockFirebaseAnalytics();
    when(
      () => fa.logEvent(
        name: any(named: 'name'),
        parameters: any(named: 'parameters'),
      ),
    ).thenAnswer((_) async {});
    when(
      () => fa.logScreenView(screenName: any(named: 'screenName')),
    ).thenAnswer((_) async {});
    service = FirebaseAnalyticsService(analytics: fa);
  });

  /// Captures the `(name, parameters)` of the single logged event.
  List<Object?> capturedEvent() => verify(
    () => fa.logEvent(
      name: captureAny(named: 'name'),
      parameters: captureAny(named: 'parameters'),
    ),
  ).captured;

  test('logPlanChanged → plan_changed { plan }', () async {
    await service.logPlanChanged('curious');
    final e = capturedEvent();
    expect(e[0], 'plan_changed');
    expect(e[1], {'plan': 'curious'});
  });

  test('logBlockingToggled → blocking_toggled { enabled: 1/0 }', () async {
    await service.logBlockingToggled(enabled: true);
    final e = capturedEvent();
    expect(e[0], 'blocking_toggled');
    expect(e[1], {'enabled': 1});
  });

  test(
    'logBlockTriggered → block_triggered { platform, mode, wall }',
    () async {
      await service.logBlockTriggered(platform: 'youtube', mode: 'PRESS_BACK');
      final e = capturedEvent();
      expect(e[0], 'block_triggered');
      expect(e[1], {'platform': 'youtube', 'mode': 'PRESS_BACK', 'wall': 0});
    },
  );

  test('logReelsCounted → reels_counted { count }', () async {
    await service.logReelsCounted(7);
    final e = capturedEvent();
    expect(e[0], 'reels_counted');
    expect(e[1], {'count': 7});
  });

  test('logPauseStarted → pause_started { duration_min }', () async {
    await service.logPauseStarted(const Duration(minutes: 15));
    final e = capturedEvent();
    expect(e[0], 'pause_started');
    expect(e[1], {'duration_min': 15});
  });

  test('logScreenView delegates to Firebase screen-view API', () async {
    await service.logScreenView('Dashboard');
    verify(() => fa.logScreenView(screenName: 'Dashboard')).called(1);
  });
}
