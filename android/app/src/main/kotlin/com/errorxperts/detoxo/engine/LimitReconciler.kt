package com.errorxperts.detoxo.engine

/**
 * EVO-029: decides which pending rule limits have run out, from measurements
 * taken natively — so a daily budget can start enforcing while Detoxo is
 * closed, which Dart cannot do.
 *
 * Android-free (like [RuleEngine] and [ReelTracker]): today's per-package
 * foreground time and launch counts arrive as plain maps, so the arithmetic
 * runs on the JVM under test. The caller ([com.errorxperts.detoxo.receivers.WatchdogJobService])
 * owns the `UsageStatsManager` query and the clock.
 *
 * Dart stays authoritative: its next push re-derives every verdict from the
 * same UsageStats and overwrites whatever this decided. This is the backstop
 * for the window where no Dart is running, not a second source of truth.
 */
object LimitReconciler {

    /**
     * Ids among [pending] whose budget is used up given today's measurements.
     *
     * A limit's usage is the SUM over its packages — a rule targeting a whole
     * category is one budget across the category, matching how Dart resolves it
     * (`_sum` in `resolve_snapshot.dart`).
     */
    fun spentIds(
        pending: List<RuleEngine.Entry>,
        usageMsByPackage: Map<String, Long>,
        opensByPackage: Map<String, Int>,
    ): Set<String> {
        if (pending.isEmpty()) return emptySet()
        val out = HashSet<String>(pending.size)
        for (e in pending) {
            if (e.usageLimitMs > 0L) {
                var used = 0L
                for (p in e.packages) used += usageMsByPackage[p] ?: 0L
                if (used >= e.usageLimitMs) {
                    out.add(e.id)
                    continue
                }
            }
            if (e.openLimitCount > 0) {
                var opens = 0
                for (p in e.packages) opens += opensByPackage[p] ?: 0
                if (opens >= e.openLimitCount) out.add(e.id)
            }
        }
        return out
    }
}
