import 'package:detoxo/features/limits/rules/domain/entities/rule.dart';
import 'package:detoxo/features/limits/rules/domain/entities/rule_snapshot.dart';
import 'package:detoxo/features/usage/usage.dart';

// The whole calendar, with no platform imports, so every edge case runs on a
// dev machine. All arithmetic is calendar arithmetic on local `DateTime`
// fields (`DateTime(y, m, d + 1)`), never `add(Duration(days: 1))`: a DST day
// is 23 or 25 hours long and absolute arithmetic lands on the wrong date.

/// ISO weekday before [weekday] (1 = Monday … 7 = Sunday).
int previousWeekday(int weekday) => weekday == 1 ? 7 : weekday - 1;

/// Whether local time [t] falls inside the weekly window.
///
/// The overnight case is the one that is always got wrong: for "Fri 22:00 →
/// 06:00" the morning slice belongs to the START day, so 02:00 on Saturday is
/// inside (Friday's window), 02:00 on Friday is not. `start == end` never
/// matches.
bool inWeeklyWindow(Set<int> days, int startMin, int endMin, DateTime t) {
  final tm = t.hour * 60 + t.minute;
  if (startMin == endMin) return false;
  if (startMin < endMin) {
    return days.contains(t.weekday) && tm >= startMin && tm < endMin;
  }
  if (tm >= startMin) return days.contains(t.weekday);
  if (tm < endMin) return days.contains(previousWeekday(t.weekday));
  return false;
}

/// Absolute windows for [s] over the next [horizonDays] calendar days from
/// [from] (device zone), including a window that is already open and, for an
/// overnight rule, one that started yesterday. Finished windows are dropped.
List<TimeWindow> scheduleWindows(
  RuleSchedule s,
  DateTime from, {
  int horizonDays = 7,
}) {
  if (s.startMin == s.endMin || s.days.isEmpty) return const [];
  final out = <TimeWindow>[];
  for (var i = -1; i < horizonDays; i++) {
    final day = DateTime(from.year, from.month, from.day + i);
    if (!s.days.contains(day.weekday)) continue;
    final start = DateTime(
      day.year,
      day.month,
      day.day,
      s.startMin ~/ 60,
      s.startMin % 60,
    );
    final end = DateTime(
      day.year,
      day.month,
      s.isOvernight ? day.day + 1 : day.day,
      s.endMin ~/ 60,
      s.endMin % 60,
    );
    if (!end.isAfter(from)) continue;
    out.add(
      TimeWindow(start.millisecondsSinceEpoch, end.millisecondsSinceEpoch),
    );
  }
  return out;
}

/// Local midnight → next local midnight around [now]; a limit's state period.
(DateTime start, DateTime end) todayInterval(DateTime now) => (
  DateTime(now.year, now.month, now.day),
  DateTime(now.year, now.month, now.day + 1),
);

/// Launches per package: foreground TRANSITIONS into an app, so an app
/// resuming its own next activity is not a new open (the same rule as native
/// `UsageQuery.countOpens`).
Map<String, int> countOpens(List<UsageEvent> events) {
  final opens = <String, int>{};
  String? last;
  for (final e in events) {
    if (e.type != UsageEventType.moveToForeground) continue;
    if (e.package == last) continue;
    opens[e.package] = (opens[e.package] ?? 0) + 1;
    last = e.package;
  }
  return opens;
}
