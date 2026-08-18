import 'package:equatable/equatable.dart';

/// Aggregate website-blocking analytics rendered as the dashboard stat cards.
class WebBlockStats extends Equatable {
  const WebBlockStats({
    this.totalBlocked = 0,
    this.blockedToday = 0,
    this.mostBlockedHost,
  });

  final int totalBlocked;
  final int blockedToday;
  final String? mostBlockedHost;

  /// Estimated focus time reclaimed — a 30s-per-block heuristic. This is the
  /// only definition; nothing else mirrors it.
  static const int secondsSavedPerBlock = 30;

  int get focusMinutesSaved =>
      (totalBlocked * secondsSavedPerBlock / 60).round();

  WebBlockStats copyWith({
    int? totalBlocked,
    int? blockedToday,
    String? mostBlockedHost,
  }) => WebBlockStats(
    totalBlocked: totalBlocked ?? this.totalBlocked,
    blockedToday: blockedToday ?? this.blockedToday,
    mostBlockedHost: mostBlockedHost ?? this.mostBlockedHost,
  );

  @override
  List<Object?> get props => [totalBlocked, blockedToday, mostBlockedHost];
}
