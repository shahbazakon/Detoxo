package com.errorxperts.detoxo.engine

import android.content.Context
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
class WebBlockEngine(private val context: Context) {

    // `regex` is precompiled at parse time for WILDCARD rules — never on the
    // per-event hot path. `pausedUntil` (epoch ms, 0 = never) lets a rule sit
    // dormant until it expires; expiry is enforced here, natively, so a per-site
    // pause re-arms even if the Flutter app is never reopened.
    private data class Rule(
        val pattern: String,
        val type: String,
        val pausedUntil: Long = 0L,
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
    fun matchHost(host: String, fullUrl: String? = null): Match? {
        if (host.isEmpty()) return null
        val now = System.currentTimeMillis()
        for (r in rules) {
            if (now < r.pausedUntil) continue // per-site pause window
            val hit = when (r.type) {
                "EXACT" -> fullUrl != null && fullUrl == r.pattern
                "WILDCARD" -> r.regex?.matches(host) == true
                else -> host == r.pattern || isSubdomainOf(host, r.pattern)
            }
            if (hit) return Match.RULE
        }
        val set = adultSet
        if (adultEnabled && set != null) {
            // Walk the host up its parent labels, ending at the bare TLD:
            // foo.bar.example.com → bar.example.com → example.com → com. A bare
            // TLD line in the asset (`porn`) therefore blocks every *.porn host.
            var h = host
            while (true) {
                if (set.contains(h)) return Match.ADULT
                val dot = h.indexOf('.')
                if (dot < 0) break
                h = h.substring(dot + 1)
            }
        }
        return null
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
                out.add(
                    Rule(
                        pattern,
                        type,
                        pausedUntil = o.optLong("pausedUntil", 0L),
                        regex = if (type == "WILDCARD") compileWildcard(pattern) else null,
                    ),
                )
            }
            out
        } catch (_: Throwable) {
            emptyList()
        }
    }

    /** Allocation-free `host.endsWith(".$pattern")` for the hot path. */
    private fun isSubdomainOf(host: String, pattern: String): Boolean =
        host.length > pattern.length &&
            host[host.length - pattern.length - 1] == '.' &&
            host.endsWith(pattern)

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
