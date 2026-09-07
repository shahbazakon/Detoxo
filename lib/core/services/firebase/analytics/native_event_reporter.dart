import 'dart:async';

import 'package:detoxo/core/constants/channel_constants.dart';
import 'package:detoxo/core/platform_channels/engine_channel.dart';
import 'package:detoxo/core/services/firebase/analytics/analytics_service.dart';
import 'package:detoxo/core/services/firebase/crashlytics/crash_reporting_service.dart';

/// Bridges native engine events — the ones that don't originate from a user
/// action — into analytics: a blocked reel, a counted short video, a blocked
/// website. Owns one persistent subscription to [EngineChannel.events] so these
/// are captured regardless of which screen (if any) is open.
///
/// Reel counts are high-frequency, so they are batched: instead of one event per
/// reel we flush an aggregate `reels_counted` after [_reelFlushThreshold] reels
/// or [_reelFlushInterval], whichever comes first.
class FirebaseNativeEventReporter {
  FirebaseNativeEventReporter(this._engine, this._analytics, this._crash);

  final EngineChannel _engine;
  final AnalyticsService _analytics;
  final CrashReportingService _crash;

  StreamSubscription<Map<String, dynamic>>? _sub;
  Timer? _reelFlushTimer;
  int _pendingReels = 0;

  static const int _reelFlushThreshold = 25;
  static const Duration _reelFlushInterval = Duration(seconds: 30);

  /// Starts listening to the native event stream. Idempotent — off-Android the
  /// stream is empty, so this is a no-op there.
  void start() {
    _sub ??= _engine.events().listen(_onEvent);
  }

  /// Flushes any pending reels and tears down the subscription.
  Future<void> dispose() async {
    _flushReels();
    await _sub?.cancel();
    _sub = null;
  }

  void _onEvent(Map<String, dynamic> event) {
    switch (event['type']) {
      case ChannelEvents.blocked:
        _analytics.logBlockTriggered(
          platform: (event['platformId'] as String?) ?? 'unknown',
          mode: (event['mode'] as String?) ?? 'unknown',
          wall: (event['wall'] as bool?) ?? false,
        );
        _crash.setKey('blocks_today', (event['today'] as num?)?.toInt() ?? 0);
        _crash.setKey('blocks_total', (event['total'] as num?)?.toInt() ?? 0);
      case ChannelEvents.contentCounted:
        _onReelCounted();
      case ChannelEvents.webBlocked:
        // `host` is intentionally omitted — browsing targets are private.
        _analytics.logWebBlocked(mode: (event['mode'] as String?) ?? 'unknown');
      case ChannelEvents.blockScreenAction:
        // The editor's "Try it" wall is not an intervention; `referenceId`
        // (a host / package) is never forwarded.
        if (event['preview'] == true) return;
        _analytics.logBlockScreenAction(
          action: (event['action'] as String?) ?? 'unknown',
        );
      case ChannelEvents.nudgeShown:
        // The threshold band only — `package` stays on the device.
        _analytics.logNudgeShown(
          thresholdMin: ((event['thresholdMs'] as num?)?.toInt() ?? 0) ~/ 60000,
        );
    }
  }

  void _onReelCounted() {
    _pendingReels++;
    _reelFlushTimer ??= Timer(_reelFlushInterval, _flushReels);
    if (_pendingReels >= _reelFlushThreshold) _flushReels();
  }

  void _flushReels() {
    _reelFlushTimer?.cancel();
    _reelFlushTimer = null;
    if (_pendingReels == 0) return;
    _analytics.logReelsCounted(_pendingReels);
    _pendingReels = 0;
  }
}
