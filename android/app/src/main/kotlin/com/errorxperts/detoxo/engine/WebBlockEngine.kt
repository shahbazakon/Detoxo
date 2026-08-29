package com.errorxperts.detoxo.engine

import android.content.Context
import android.os.SystemClock
import org.json.JSONArray
import java.util.zip.GZIPInputStream

/**
 * Matches a browser URL host against the user's website blocklist and, when
 * enabled, a bundled set of adult domains.
 *
 * The user/derived blocklist is a tiny JSON list pushed from Dart and held in
 * memory. The adult set is a bundled asset (`adult_domains.txt.gz`, GENERATED
 * from tool/web_blocker/blocked_websites.json by `bash tool/dev.sh adultlist`)
 * loaded lazily only while the toggle is on, and freed when it is turned off so
 * it costs no heap otherwise. All matching is host-based — Android accessibility
 * can read the address bar but cannot see network traffic.
 */
class WebBlockEngine(
    private val context: Context,
    private val unblocks: UnblockRegistry,
) {

    // `regex` is precompiled at parse time for WILDCARD rules — never on the
    // per-event hot path.
    //
    // M8: the per-entry `pausedUntil` this class used to carry is GONE. "This
    // target is dormant until T" is now one mechanism for reels, apps and
    // websites — [UnblockRegistry] — instead of two, and it keeps EVO-048's
    // monotonic deadline (the registry converts at parse exactly as this class
    // used to). An old build's `pausedUntil` key is simply ignored, so a
    // downgrade cannot resurrect a stale pause.
    private data class Rule(
        val pattern: String,
        val type: String,
        val regex: Regex? = null,
    )

    @Volatile private var rules: List<Rule> = emptyList()
    @Volatile private var adultEnabled = false
    @Volatile private var adultSet: HashSet<String>? = null

    /** Replace the active blocklist from the pushed JSON `[{pattern,matchType}]`. */
    fun setBlocklist(json: String?) {
        rules = parse(json)
    }

    /** Toggle the adult set, loading/freeing the bundled asset accordingly. */
    fun setAdultEnabled(on: Boolean) {
        adultEnabled = on
        adultSet = if (on) (adultSet ?: loadAdultSet()) else null
    }

    /** Whether anything is configured — guards the accessibility hot path. */
    fun hasAnyRules(): Boolean =
        rules.isNotEmpty() || (adultEnabled && (adultSet?.isNotEmpty() == true))

    /**
     * Which list matched. RULE hits (the user's own blocklist) may be named in
     * the toast/event; ADULT hits are counted but never named (EVO-018).
     */
    enum class Match { RULE, ADULT }

    /** Which list blocks [host] (already normalized), or null when it is allowed. */
    fun matchHost(host: String): Match? {
        if (host.isEmpty()) return null
        // ONE grant check, above the loop and gating only the user's own rules.
        // The adult walk below is structurally outside it — not merely skipped
        // by a `continue` — so an 18+ hit can never be lifted by a grant, which
        // is EVO-018's promise ("never named, never one tap from being lifted").
        val nowElapsed = SystemClock.elapsedRealtime()
        val granted = unblocks.hasAny(UnblockRegistry.TYPE_WEBSITE, nowElapsed) &&
            unblocks.isUnblocked(UnblockRegistry.TYPE_WEBSITE, host, nowElapsed)
        if (!granted) {
            for (r in rules) {
                // No EXACT arm: nothing has ever pushed one, and matching it needed
                // a full URL this host-based engine never has — so an EXACT rule
                // restored from an old blob fell through and silently blocked
                // NOTHING. It now lands in `else` and blocks by domain.
                val hit = when (r.type) {
                    "WILDCARD" -> r.regex?.matches(host) == true
                    else -> host == r.pattern || isSubdomainOf(host, r.pattern)
                }
                if (hit) return Match.RULE
            }
        }
        if (matchesAdult(host)) return Match.ADULT
        return null
    }

    /**
     * Whether the bundled 18+ set covers [host]. Public so the wall can refuse
     * to render "Unblock for a while" on a host that is on BOTH the user's
     * blocklist and this set — the rule arm wins the match, so the button would
     * otherwise appear, mint a grant, and the very next visit would be blocked
     * again (unnamed). Cold path only: called once per raised wall.
     */
    fun matchesAdult(host: String): Boolean {
        val set = adultSet
        if (adultEnabled && set != null) {
            // Walk the host up its parent labels, ending at the bare TLD:
            // foo.bar.example.com → bar.example.com → example.com → com. A bare
            // TLD line in the asset (`porn`) therefore blocks every *.porn host.
            var h = host
            while (true) {
                if (set.contains(h)) return true
                val dot = h.indexOf('.')
                if (dot < 0) break
                h = h.substring(dot + 1)
            }
        }
        return false
    }

    private fun parse(json: String?): List<Rule> {
        if (json.isNullOrBlank()) return emptyList()
        return try {
            val arr = JSONArray(json)
            val out = ArrayList<Rule>(arr.length())
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                val pattern = o.optString("pattern").trim().lowercase()
                if (pattern.isEmpty()) continue
                val type = o.optString("matchType", "DOMAIN")
                // An old build's `pausedUntil` is read by nothing and therefore
                // ignored — the tolerance the wire-contract change requires,
                // for free.
                out.add(
                    Rule(
                        pattern,
                        type,
                        regex = if (type == "WILDCARD") compileWildcard(pattern) else null,
                    ),
                )
            }
            out
        } catch (_: Throwable) {
            emptyList()
        }
    }

    /** Allocation-free `host.endsWith(".$pattern")` — one copy, in [RuleEngine]. */
    private fun isSubdomainOf(host: String, pattern: String): Boolean =
        RuleEngine.isSubdomainOf(host, pattern)

    /** Translate a glob (`*` = any run) to an anchored regex — once, at parse. */
    private fun compileWildcard(pattern: String): Regex? {
        val sb = StringBuilder("^")
        for (c in pattern) {
            when {
                c == '*' -> sb.append(".*")
                c.isLetterOrDigit() -> sb.append(c)
                else -> sb.append('\\').append(c)
            }
        }
        sb.append('$')
        return try {
            Regex(sb.toString())
        } catch (_: Throwable) {
            null
        }
    }

    private fun loadAdultSet(): HashSet<String> {
        val out = HashSet<String>(4096)
        try {
            context.assets.open(ADULT_ASSET).use { raw ->
                GZIPInputStream(raw).bufferedReader().forEachLine { line ->
                    val s = line.trim()
                    if (s.isNotEmpty() && !s.startsWith("#")) out.add(s.lowercase())
                }
            }
        } catch (_: Throwable) {
            // Asset missing / unreadable → empty set (adult blocking simply no-ops).
        }
        return out
    }

    private companion object {
        const val ADULT_ASSET = "adult_domains.txt.gz"
    }
}
