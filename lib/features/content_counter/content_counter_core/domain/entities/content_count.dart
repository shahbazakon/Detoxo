import 'package:detoxo/features/content_counter/content_counter_core/domain/entities/app_content_count.dart';
import 'package:equatable/equatable.dart';

/// Snapshot of the short-video / reel counter: today + all-time totals and the
/// per-app breakdowns (each list sorted by count, descending).
class ContentCount extends Equatable {
  const ContentCount({
    this.today = 0,
    this.total = 0,
    this.enabled = true,
    this.bubbleEnabled = true,
    this.perAppToday = const [],
    this.perAppTotal = const [],
    this.timeToday = Duration.zero,
    this.overlayGranted,
    this.loaded = true,
  });

  /// A safe zero-state used before the first pull and off-Android. The only
  /// unloaded state: its `enabled = true` is a placeholder, not a reading.
  const ContentCount.empty()
    : today = 0,
      total = 0,
      enabled = true,
      bubbleEnabled = true,
      perAppToday = const [],
      perAppTotal = const [],
      timeToday = Duration.zero,
      overlayGranted = null,
      loaded = false;

  final int today;
  final int total;
  final bool enabled;
  final bool bubbleEnabled;
  final List<AppContentCount> perAppToday;
  final List<AppContentCount> perAppTotal;

  /// Whole-app foreground time spent in monitored social apps today (native
  /// usage accrual). Drives the dashboard screen-time ring + the bubble tap.
  final Duration timeToday;

  /// Whether the "Display over other apps" grant the bubble needs is held —
  /// tri-state like the permission model: `null` = not read yet / the read
  /// didn't answer (render neutral, never as denied). Not part of the native
  /// snapshot; the cubit fills it in from the overlay-permission read.
  final bool? overlayGranted;

  /// False only for [ContentCount.empty] — nothing has been read from native
  /// yet, so [enabled] is a placeholder. Anything that *commits* on the
  /// counter's state (the daily-limit streak) must wait for a loaded value.
  final bool loaded;

  bool get isEmpty => today == 0 && total == 0;

  /// The bubble is switched on but cannot actually appear (grant missing).
  bool get bubbleBlocked => enabled && bubbleEnabled && overlayGranted == false;

  ContentCount copyWith({
    int? today,
    int? total,
    bool? enabled,
    bool? bubbleEnabled,
    List<AppContentCount>? perAppToday,
    List<AppContentCount>? perAppTotal,
    Duration? timeToday,
    bool? overlayGranted,
  }) => ContentCount(
    today: today ?? this.today,
    total: total ?? this.total,
    enabled: enabled ?? this.enabled,
    bubbleEnabled: bubbleEnabled ?? this.bubbleEnabled,
    perAppToday: perAppToday ?? this.perAppToday,
    perAppTotal: perAppTotal ?? this.perAppTotal,
    timeToday: timeToday ?? this.timeToday,
    overlayGranted: overlayGranted ?? this.overlayGranted,
    loaded: loaded,
  );

  @override
  List<Object?> get props => [
    today,
    total,
    enabled,
    bubbleEnabled,
    perAppToday,
    perAppTotal,
    timeToday,
    overlayGranted,
    loaded,
  ];
}
