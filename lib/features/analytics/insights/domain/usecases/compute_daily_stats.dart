import 'package:detoxo/core/utils/day_signature.dart';
import 'package:detoxo/features/analytics/insights/domain/entities/daily_stats.dart';
import 'package:detoxo/features/catalog/catalog.dart';
import 'package:detoxo/features/limits/limits.dart' show countOpens;
import 'package:detoxo/features/usage/usage.dart';

/// How many apps a day record keeps. The screen shows five; the store keeps ten
/// so a later per-app view does not need every day recomputed.
const int kTopAppsCap = 10;

/// Folds one local day of `UsageStatsManager` rows into [DailyStats].
///
/// **Pure — no platform imports, no clock, no I/O.** Every metric below is
/// testable against a handcrafted event list in milliseconds, which is the only
/// practical way to be confident about figures the user will compare against
/// Digital Wellbeing.
///
/// The window is `[start, end)` over the **local** day. Native already windows
/// the query, but the events are filtered again here: it costs one pass, it
/// makes the function total for any input, and it is what lets the boundary
/// cases be pinned by a test instead of by trust.
///
/// [protectedPackages] never reach [DailyStats.topApps] — see the note there.
DailyStats computeDailyStats({
  required List<AppUsage> usage,
  required List<UsageEvent> events,
  required Catalog catalog,
  required DateTime start,
  required DateTime end,
  Set<String> protectedPackages = const {},
  int reelCount = 0,
  bool complete = false,
  int computedAtMs = 0,
}) {
  final startMs = start.millisecondsSinceEpoch;
  final endMs = end.millisecondsSinceEpoch;
  // Sorted here, not assumed: the OS yields ascending, but a fold that silently
  // depends on that produces a plausible wrong number when it ever doesn't.
  final kept =
      events
          .where(
            (e) => e.timestampMillis >= startMs && e.timestampMillis < endMs,
          )
          .toList()
        ..sort((a, b) => a.timestampMillis.compareTo(b.timestampMillis));

  var screenTimeMs = 0;
  var distractionMs = 0;
  for (final a in usage) {
    final ms = a.foregroundMillis;
    if (ms <= 0) continue; // native drops these; never trust it into a total
    screenTimeMs += ms;
    if (catalog.behaviorForPackage(a.package) == AppBehavior.distracting) {
      distractionMs += ms;
    }
  }

  // One walk, shared by both open-derived metrics, using the same definition of
  // "an open" as the native engine and the rules limiter.
  final opens = countOpens(kept);
  var totalOpens = 0;
  var distractionOpens = 0;
  opens.forEach((pkg, n) {
    totalOpens += n;
    if (catalog.behaviorForPackage(pkg) == AppBehavior.distracting) {
      distractionOpens += n;
    }
  });
  // The day's first foreground is a transition from nothing, not a switch away
  // from something — this is the plan's `prevPkg != null` guard, derived.
  final contextSwitches = totalOpens > 0 ? totalOpens - 1 : 0;

  final pickups = kept
      .where((e) => e.type == UsageEventType.screenInteractive)
      .toList();

  // Protected apps are excluded from the only output that *names* an app.
  // The user marked these (banking, UPI, password managers) as apps Detoxo
  // ignores entirely, and `docs/code_docs/24-protected-apps.md` promises
  // nothing about them is stored or shown. Their time still counts toward the
  // aggregate totals above — that is not identifying, and dropping it would
  // make the day disagree with Digital Wellbeing for no privacy gain.
  final top =
      usage
          .where(
            (a) =>
                a.foregroundMillis > 0 &&
                !protectedPackages.contains(a.package),
          )
          .toList()
        ..sort((a, b) => b.foregroundMillis.compareTo(a.foregroundMillis));

  return DailyStats(
    dayKey: daySignature(start),
    screenTimeMs: screenTimeMs,
    distractionMs: distractionMs,
    distractionOpens: distractionOpens,
    pickupCount: pickups.length,
    firstPickupMs: pickups.isEmpty ? null : pickups.first.timestampMillis,
    lastPickupMs: pickups.isEmpty ? null : pickups.last.timestampMillis,
    contextSwitches: contextSwitches,
    reelCount: reelCount,
    topApps: top.take(kTopAppsCap).toList(),
    computedAtMs: computedAtMs,
    complete: complete,
  );
}
