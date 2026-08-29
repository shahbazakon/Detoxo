import 'package:detoxo/core/platform_channels/installed_app.dart';
import 'package:detoxo/features/analytics/insights/domain/entities/daily_stats.dart';
import 'package:equatable/equatable.dart';

/// Why the screen has (or has not) numbers to show. The three non-data cases
/// are kept apart deliberately: rendering `0 m` for a missing grant would be
/// indistinguishable from a genuinely quiet day (EVO-014).
enum InsightsStatus {
  loading,

  /// Usage Access is granted and [InsightsState.stats] is real.
  granted,

  /// Usage Access is not granted — an optional permission in the funnel.
  denied,

  /// No native engine, or the query itself failed. Not the user's fault and
  /// not a refusal: render "checking", offer a retry.
  unavailable,
}

/// Immutable UI state for the Insights view.
class InsightsState extends Equatable {
  const InsightsState({
    this.status = InsightsStatus.loading,
    this.stats,
    this.yesterday,
    this.apps = const {},
  });

  final InsightsStatus status;

  /// Today's rollup; non-null exactly when [status] is
  /// [InsightsStatus.granted].
  final DailyStats? stats;

  /// Yesterday, only when it is a *complete* day — a partial yesterday would
  /// make every comparison read low.
  final DailyStats? yesterday;

  /// Package → installed app, for labels and icons in the top-apps list.
  /// Missing entries fall back to the package name; an empty map is normal on
  /// the first frame and off-device.
  final Map<String, InstalledApp> apps;

  bool get isLoading => status == InsightsStatus.loading;

  /// True when there are real numbers to draw.
  bool get hasData => status == InsightsStatus.granted && stats != null;

  /// Change in screen time against yesterday as a whole percent — **only when
  /// both days are finished**, which today never is while it is still running.
  ///
  /// It therefore reads null in the live screen, and that is the point: a
  /// part-day measured against a whole one produced "95% less than yesterday"
  /// every morning, which is true arithmetic and a false statement. Rendering
  /// yesterday's total as a plain reference ([yesterdayScreenTime]) lets the
  /// user compare without the app asserting something it cannot know.
  ///
  /// Kept because a finished-day view (the history UI) can use it honestly.
  int? get screenTimeDeltaPercent {
    final today = stats;
    final before = yesterday;
    if (today == null || before == null) return null;
    if (!today.complete || !before.complete || before.screenTimeMs <= 0) {
      return null;
    }
    final delta = today.screenTimeMs - before.screenTimeMs;
    return ((delta / before.screenTimeMs) * 100).round();
  }

  /// Yesterday's finished total, shown as a neutral reference beside today's.
  Duration? get yesterdayScreenTime =>
      yesterday?.complete ?? false ? yesterday!.screenTime : null;

  /// Standard retention semantics: a null argument **keeps** the current value.
  ///
  /// That matters for [yesterday] — passing a freshly computed `null` (no
  /// complete previous day) does *not* clear it, so a caller that recomputes
  /// after a day rollover must build an [InsightsState] directly rather than
  /// `copyWith`, or it will keep showing the old record and label it
  /// "yesterday". `InsightsCubit._compute` does exactly that.
  InsightsState copyWith({
    InsightsStatus? status,
    DailyStats? stats,
    DailyStats? yesterday,
    Map<String, InstalledApp>? apps,
    bool clearStats = false,
  }) => InsightsState(
    status: status ?? this.status,
    stats: clearStats ? null : (stats ?? this.stats),
    yesterday: clearStats ? null : (yesterday ?? this.yesterday),
    apps: apps ?? this.apps,
  );

  @override
  List<Object?> get props => [status, stats, yesterday, apps];
}
