import 'package:collection/collection.dart';
import 'package:detoxo/core/utils/app_logger.dart';
import 'package:detoxo/features/blocking/shared/domain/repositories/blocking_repositories.dart';
import 'package:detoxo/features/limits/daily_limit/domain/repositories/daily_limit_repository.dart';
import 'package:detoxo/features/limits/rules/domain/entities/rule.dart';
import 'package:detoxo/features/limits/rules/domain/entities/rule_snapshot.dart';
import 'package:detoxo/features/limits/rules/domain/repositories/rule_repository.dart';
import 'package:detoxo/features/limits/rules/domain/usecases/resolve_snapshot.dart';
import 'package:detoxo/features/limits/rules/domain/usecases/rule_calendar.dart';
import 'package:detoxo/features/limits/unblock/domain/repositories/unblock_repositories.dart';
import 'package:detoxo/features/limits/unblock/domain/usecases/unblock_quota.dart';
import 'package:detoxo/features/usage/usage.dart';

/// Resolves the stored rules (+ the global Daily Limit) into the native
/// snapshot and pushes it. The single push path, and its ONLY caller is
/// `RulesCubit.resync` — cold start and every wipe come through the cubit's
/// `load()` (main.dart and splash), then every mutation, `ruleBoundary` and the
/// boundary timer. `syncEngineBlocklists()` deliberately does not call this.
/// Returns the evaluation for the UI, or null when the push was skipped.
///
/// Best-effort by contract (the `syncWebBlocklist` shape): a failed `load()`
/// ABORTS the push so native keeps enforcing its last-good snapshot — a
/// corrupt Dart store must never push "[]" and wipe it.
///
/// Dart is authoritative for limits: it re-derives every verdict here and its
/// push overwrites whatever native decided. Native only fills the gap when no
/// Dart is running — EVO-029 has the watchdog re-measure PENDING budgets every
/// 15 minutes, so a daily limit now engages with Detoxo closed.
///
/// ponytail: that flip is up to one watchdog period (15 min) late, and it needs
/// the accessibility service alive to hold the snapshot it flips. Upgrade path
/// = persisting the flip through ConfigStore so it survives a service restart.
///
/// M8: [ledger] is read here so an active override can be subtracted from the
/// rule it lifts before the snapshot is pushed. A failed ledger read is NOT
/// fatal — it means no lift, i.e. the rule keeps enforcing, which is the
/// fail-safe direction; it must never abort the push and leave native on a
/// snapshot that still carries a lift the user has since spent.
Future<RulesEvaluation?> syncRules(
  RuleRepository rules,
  DailyLimitRepository dailyLimit,
  UsageRepository usage,
  EngineRepository engine, {
  DateTime Function() now = DateTime.now,
  RulesSnapshot? previous,
  BypassLedgerRepository? ledger,
}) async {
  try {
    return await _push(
      rules,
      dailyLimit,
      usage,
      engine,
      now(),
      previous,
      ledger,
    );
  } on Object catch (e, s) {
    AppLogger.e('rules sync failed', e, s);
    return null;
  }
}

Future<RulesEvaluation?> _push(
  RuleRepository rules,
  DailyLimitRepository dailyLimit,
  UsageRepository usage,
  EngineRepository engine,
  DateTime now,
  RulesSnapshot? previous,
  BypassLedgerRepository? ledger,
) async {
  final list = await rules.load();
  final limit = (await dailyLimit.load()).limit;
  var usageKnown = false;
  var usageMs = const <String, int>{};
  var opens = const <String, int>{};
  // Each query is a binder round trip plus a channel decode of every row
  // (the event log is a few hundred a day), on every resync. Only the budgets
  // that exist pay for theirs: a time limit never needs the event log, an
  // open limit never needs the per-app totals.
  final needsUsage = list.any((r) => r.enabled && r.kind == RuleKind.timeLimit);
  final needsOpens = list.any((r) => r.enabled && r.kind == RuleKind.openLimit);
  if (needsUsage || needsOpens) {
    final (start, _) = todayInterval(now);
    if (now.isAfter(start)) {
      final u = needsUsage ? await usage.queryAppUsage(start, now) : null;
      final e = needsOpens ? await usage.queryUsageEvents(start, now) : null;
      final usageOk = !needsUsage || u is UsageGranted<List<AppUsage>>;
      final eventsOk = !needsOpens || e is UsageGranted<List<UsageEvent>>;
      if (usageOk && eventsOk) {
        usageKnown = true;
        if (u is UsageGranted<List<AppUsage>>) {
          final ms = <String, int>{};
          for (final a in u.data) {
            ms[a.package] = (ms[a.package] ?? 0) + a.foregroundMillis;
          }
          usageMs = ms;
        }
        if (e is UsageGranted<List<UsageEvent>>) opens = countOpens(e.data);
      }
    }
  }
  // A ledger read that fails means "no lift", never "abort the push": leaving
  // native on a snapshot whose override the user has since used up would keep
  // a locked rule open past its window.
  var lifts = const <String, TimeWindow>{};
  if (ledger != null && list.any((r) => r.locked)) {
    try {
      final entries = (await ledger.load()).entries;
      final nowMs = now.millisecondsSinceEpoch;
      lifts = {
        for (final e in UnblockQuota.activeOverrides(entries, nowMs).entries)
          e.key: TimeWindow(e.value.atMs, e.value.untilMs),
      };
    } on Object catch (e, s) {
      AppLogger.e(
        'rules sync: bypass ledger unreadable, no lift applied',
        e,
        s,
      );
    }
  }
  final eval = resolveSnapshot(
    rules: list,
    now: now,
    usageMsByPackage: usageMs,
    opensByPackage: opens,
    usageKnown: usageKnown,
    dailyReelLimit: limit,
    previousEntries: previous?.entries ?? const [],
    activeOverrides: lifts,
  );
  // An unchanged snapshot still crosses with its boundary — native writes
  // `nextBoundaryMs` unconditionally and reads an absent `json` as "keep what
  // you have" — but the array (~45 KB typical, ~175 KB at the cap) is neither
  // re-encoded nor marshalled: the common resume / boundary push is built to
  // be byte-identical, so it need not be built at all.
  final unchanged =
      previous != null &&
      const ListEquality<SnapshotEntry>().equals(
        previous.entries,
        eval.snapshot.entries,
      );
  final pushed = await engine.pushRules(
    unchanged ? null : eval.snapshot.toJsonString(),
    eval.snapshot.nextBoundaryMs,
  );
  // A push that failed (the channel has already logged it) leaves native on
  // its previous snapshot. Report nothing new, so the caller keeps the
  // statuses and last-pushed snapshot it had, and the next trigger pushes in
  // full instead of assuming native holds what it never received.
  if (!pushed) return null;
  return eval;
}
