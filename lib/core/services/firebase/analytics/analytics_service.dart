import 'package:detoxo/core/services/firebase/analytics/analytics_events.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/widgets.dart' show NavigatorObserver;

/// App-facing analytics surface. Exposes *semantic* methods (not a raw
/// `logEvent`) so call sites stay declarative and the event/param vocabulary is
/// enforced in one place. Behind an interface so it mocks cleanly in tests
/// (the app registers interfaces → impls; see `core/di/injector.dart`).
abstract interface class AnalyticsService {
  /// A [NavigatorObserver] that logs `screen_view` on every route push — add it
  /// to `GoRouter.observers`.
  NavigatorObserver get navigatorObserver;

  Future<void> setUserId(String id);
  Future<void> setCollectionEnabled({required bool enabled});

  /// Manual screen view, for surfaces the route observer can't see (e.g. the
  /// bottom-nav shell's tabs, which don't change the route).
  Future<void> logScreenView(String screenName);

  Future<void> logPlanChanged(String plan);
  Future<void> logBlockingToggled({required bool enabled});
  Future<void> logPauseStarted(Duration duration);
  Future<void> logPauseEnded();
  Future<void> logBlockTriggered({
    required String platform,
    required String mode,
  });
  Future<void> logReelsCounted(int count);
  Future<void> logWebBlocked({required String mode});

  /// The user touched a block-screen action. Only the action token is sent.
  Future<void> logBlockScreenAction({required String action});

  /// A soft-nudge card was shown after [thresholdMin] minutes in an app. The
  /// package is never sent.
  Future<void> logNudgeShown({required int thresholdMin});

  /// The first run reached [step], arriving by [direction] (ENTER on the first
  /// render or a resume, FORWARD, BACK). Only these two tokens are sent — never
  /// a name, a screen-time band or a picked feed.
  ///
  /// [direction] is what makes the numbers usable: without it a Back tap counts
  /// identically to a Next tap and every step total is inflated by an unknown
  /// amount; without the ENTER event the first step never fires at all, so the
  /// welcome→survey drop-off — the most valuable number in the funnel — has no
  /// denominator.
  Future<void> logOnboardingStep(String step, {required String direction});
}

/// [AnalyticsService] backed by Firebase Analytics. The [FirebaseAnalytics]
/// instance is injectable so tests can pass a mock (mirrors the constructor
/// default pattern used across the repos, e.g. `ConfigRepositoryImpl`).
class FirebaseAnalyticsService implements AnalyticsService {
  FirebaseAnalyticsService({FirebaseAnalytics? analytics})
    : _analytics = analytics ?? FirebaseAnalytics.instance;

  final FirebaseAnalytics _analytics;

  @override
  NavigatorObserver get navigatorObserver =>
      FirebaseAnalyticsObserver(analytics: _analytics);

  @override
  Future<void> setUserId(String id) => _analytics.setUserId(id: id);

  @override
  Future<void> setCollectionEnabled({required bool enabled}) =>
      _analytics.setAnalyticsCollectionEnabled(enabled);

  @override
  Future<void> logScreenView(String screenName) =>
      _analytics.logScreenView(screenName: screenName);

  @override
  Future<void> logPlanChanged(String plan) =>
      _log(AnalyticsEvent.planChanged, {AnalyticsParam.plan: plan});

  @override
  Future<void> logBlockingToggled({required bool enabled}) => _log(
    AnalyticsEvent.blockingToggled,
    {AnalyticsParam.enabled: enabled ? 1 : 0},
  );

  @override
  Future<void> logPauseStarted(Duration duration) => _log(
    AnalyticsEvent.pauseStarted,
    {AnalyticsParam.durationMin: duration.inMinutes},
  );

  @override
  Future<void> logPauseEnded() => _log(AnalyticsEvent.pauseEnded);

  @override
  Future<void> logBlockTriggered({
    required String platform,
    required String mode,
  }) => _log(AnalyticsEvent.blockTriggered, {
    AnalyticsParam.platform: platform,
    AnalyticsParam.mode: mode,
  });

  @override
  Future<void> logReelsCounted(int count) =>
      _log(AnalyticsEvent.reelsCounted, {AnalyticsParam.count: count});

  @override
  Future<void> logWebBlocked({required String mode}) =>
      _log(AnalyticsEvent.webBlocked, {AnalyticsParam.mode: mode});

  @override
  Future<void> logBlockScreenAction({required String action}) =>
      _log(AnalyticsEvent.blockScreenAction, {AnalyticsParam.action: action});

  @override
  Future<void> logNudgeShown({required int thresholdMin}) => _log(
    AnalyticsEvent.nudgeShown,
    {AnalyticsParam.durationMin: thresholdMin},
  );

  @override
  Future<void> logOnboardingStep(String step, {required String direction}) =>
      _log(AnalyticsEvent.onboardingStep, {
        AnalyticsParam.step: step,
        AnalyticsParam.direction: direction,
      });

  Future<void> _log(String name, [Map<String, Object>? parameters]) =>
      _analytics.logEvent(name: name, parameters: parameters);
}
