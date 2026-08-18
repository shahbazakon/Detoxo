package com.errorxperts.detoxo.engine

import android.view.accessibility.AccessibilityNodeInfo
import java.util.ArrayDeque

/**
 * Extracts the current URL host from a browser's accessibility tree.
 *
 * Mapped browsers use a direct address-bar resource-id lookup (one indexed call);
 * unmapped browsers fall back to a bounded DFS over EditText / url-ish nodes, so
 * coverage extends to effectively any installed browser. Stateless and pure.
 */
object BrowserUrlExtractor {

    // Per-browser address-bar resource IDs (the fast path). Add new browsers here.
    private val URL_BAR_IDS: Map<String, List<String>> = mapOf(
        "com.android.chrome" to listOf("com.android.chrome:id/url_bar"),
        "com.chrome.beta" to listOf("com.chrome.beta:id/url_bar"),
        "com.chrome.dev" to listOf("com.chrome.dev:id/url_bar"),
        "com.chrome.canary" to listOf("com.chrome.canary:id/url_bar"),
        "com.sec.android.app.sbrowser" to listOf(
            "com.sec.android.app.sbrowser:id/location_bar_edit_text",
            "com.sec.android.app.sbrowser:id/sbrowser_url_bar",
        ),
        "com.sec.android.app.sbrowser.beta" to listOf(
            "com.sec.android.app.sbrowser.beta:id/location_bar_edit_text",
        ),
        "org.mozilla.firefox" to listOf(
            "org.mozilla.firefox:id/mozac_browser_toolbar_url_view",
            "org.mozilla.firefox:id/url_bar_title",
        ),
        "org.mozilla.firefox_beta" to listOf(
            "org.mozilla.firefox_beta:id/mozac_browser_toolbar_url_view",
        ),
        "org.mozilla.fenix" to listOf(
            "org.mozilla.fenix:id/mozac_browser_toolbar_url_view",
        ),
        "com.microsoft.emmx" to listOf("com.microsoft.emmx:id/url_bar"),
        "com.brave.browser" to listOf("com.brave.browser:id/url_bar"),
        "com.brave.browser_beta" to listOf("com.brave.browser_beta:id/url_bar"),
        "com.opera.browser" to listOf("com.opera.browser:id/url_field"),
        "com.opera.mini.native" to listOf("com.opera.mini.native:id/url_field"),
        "com.opera.gx" to listOf("com.opera.gx:id/url_field"),
        "com.duckduckgo.mobile.android" to listOf(
            "com.duckduckgo.mobile.android:id/omnibarTextInput",
        ),
        "com.kiwibrowser.browser" to listOf("com.kiwibrowser.browser:id/url_bar"),
        "com.vivaldi.browser" to listOf("com.vivaldi.browser:id/url_bar"),
        "com.mi.globalbrowser" to listOf("com.mi.globalbrowser:id/url"),
        "com.mi.globalbrowser.mini" to listOf("com.mi.globalbrowser.mini:id/url"),
        "com.android.browser" to listOf("com.android.browser:id/url"),
        "com.UCMobile.intl" to listOf("com.UCMobile.intl:id/url"),
        "com.yandex.browser" to listOf(
            "com.yandex.browser:id/bro_omnibar_address_title_text",
        ),
        "com.ecosia.android" to listOf("com.ecosia.android:id/url_bar"),
    )

    // Browsers we recognise but rely on the generic fallback for (no mapped id).
    private val KNOWN_BROWSERS: Set<String> = HashSet(URL_BAR_IDS.keys).apply {
        addAll(
            listOf(
                "acr.browser.lightning",
                "org.adblockplus.browser",
                "mark.via.gp",
                "com.qwant.liberty",
                "com.cloudmosa.puffinFree",
                "com.htc.sense.browser",
                "com.huawei.browser",
                "org.torproject.torbrowser",
            ),
        )
    }

    // Matches a host (optionally with scheme / www / path) inside free text.
    private val URL_REGEX = Regex(
        "\\b(?:https?://)?(?:www\\.)?((?:[a-z0-9-]+\\.)+[a-z]{2,})(?:[/?#]\\S*)?",
        RegexOption.IGNORE_CASE,
    )

    // Final shape guard for a plausible registrable host.
    private val HOST_GUARD = Regex("^(?:[a-z0-9-]+\\.)+[a-z]{2,24}$")

    fun isBrowser(pkg: String): Boolean = KNOWN_BROWSERS.contains(pkg)

    /** Best-effort current host for [pkg], or null. */
    fun extractHost(root: AccessibilityNodeInfo, pkg: String, maxNodes: Int): String? {
        // 1) Mapped fast path: the address bar by resource id.
        URL_BAR_IDS[pkg]?.let { ids ->
            var sawMappedBar = false
            for (id in ids) {
                val hits = root.findAccessibilityNodeInfosByViewId(id)
                if (!hits.isNullOrEmpty()) {
                    sawMappedBar = true
                    for (n in hits) {
                        // A focused address bar means the user is typing — don't
                        // match half-typed hosts (the page-load events after
                        // commit re-run this on the then-unfocused bar). Ceiling:
                        // a browser that keeps its bar focused after load would
                        // never be blocked; none of the mapped ones do.
                        if (n?.isFocused == true) continue
                        val host = normalizeHost(n?.text?.toString())
                        if (host != null) return host
                    }
                }
            }
            // The mapped bar existed but yielded nothing (focused, or showing
            // non-URL text). It is authoritative — never fall through to the
            // DFS, which would walk up to maxNodes on every event while typing.
            if (sawMappedBar) return null
        }
        // 2) Generic fallback: bounded DFS over EditText / url-ish nodes.
        val deque = ArrayDeque<AccessibilityNodeInfo>()
        deque.addLast(root)
        var i = 0
        while (deque.isNotEmpty() && i < maxNodes) {
            val node = deque.removeLast()
            i++
            val isEdit = node.className?.toString()?.contains("EditText") == true
            val resName = node.viewIdResourceName
            // Skip focused nodes for the same typing-in-progress reason as above.
            if (!node.isFocused &&
                (isEdit || (resName != null && resName.contains("url", ignoreCase = true)))
            ) {
                val host = extractFromText(node.text?.toString())
                if (host != null) return host
            }
            for (c in node.childCount - 1 downTo 0) {
                node.getChild(c)?.let { deque.addLast(it) }
            }
        }
        return null
    }

    /** Pull a host out of free text (a toolbar label that may carry scheme/path). */
    private fun extractFromText(raw: String?): String? {
        if (raw.isNullOrBlank()) return null
        val match = URL_REGEX.find(raw) ?: return null
        return normalizeHost(match.groupValues.getOrNull(1) ?: match.value)
    }

    /** Lowercase + strip scheme/www/path/query/port; reject placeholder text. */
    fun normalizeHost(raw: String?): String? {
        if (raw.isNullOrBlank()) return null
        var s = raw.trim().lowercase()
        if (s.contains(' ')) return null // "Search or type URL", search queries
        s = s.substringAfter("://", s) // scheme
        s = s.substringBefore('/').substringBefore('?').substringBefore('#')
        s = s.substringBefore(':') // port
        if (s.startsWith("www.")) s = s.substring(4)
        if (s.length < 4 || !s.contains('.')) return null
        return if (HOST_GUARD.matches(s)) s else null
    }
}
