package com.errorxperts.detoxo.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins [BrowserUrlExtractor.normalizeHost], the address-bar text → host step
 * that decides whether the web blocker ever gets a chance to match.
 *
 * This is the Kotlin half of a rule implemented twice: Dart's `DomainValidator`
 * normalizes what the user TYPES, this normalizes what the browser SHOWS, and
 * the two must agree or a host the user successfully added is never blocked.
 * `test/web_blocker_test.dart` pins the Dart half; this pins ours.
 *
 * [BrowserUrlExtractor.extractHost] itself is not covered here — it walks
 * `AccessibilityNodeInfo`, which has no JVM instance.
 */
class BrowserUrlExtractorTest {

    private fun norm(raw: String?) = BrowserUrlExtractor.normalizeHost(raw)

    @Test
    fun `strips scheme, www, path, query, fragment and port`() {
        assertEquals("youtube.com", norm("https://www.youtube.com/watch?v=1#t"))
        assertEquals("youtube.com", norm("http://youtube.com"))
        assertEquals("youtube.com", norm("youtube.com:8443"))
        assertEquals("youtube.com", norm("youtube.com/feed"))
        assertEquals("youtube.com", norm("youtube.com?q=1"))
    }

    @Test
    fun `keeps subdomains, which the suffix match needs`() {
        assertEquals("m.youtube.com", norm("m.youtube.com"))
        assertEquals("web.whatsapp.com", norm("https://web.whatsapp.com/"))
    }

    @Test
    fun `strips userinfo before the port split`() {
        // Regression: `substringBefore(':')` ran first and yielded "user", so
        // the host was never matched and the page was never blocked. Dart's
        // DomainValidator has always stripped this.
        assertEquals("youtube.com", norm("https://user:pass@youtube.com"))
        assertEquals("youtube.com", norm("user@youtube.com"))
        assertEquals("youtube.com", norm("https://user:pass@youtube.com:8443/x"))
    }

    @Test
    fun `strips the trailing-dot FQDN form`() {
        // One keystroke would otherwise bypass the blocklist entirely.
        assertEquals("youtube.com", norm("youtube.com."))
        assertEquals("youtube.com", norm("https://www.youtube.com./feed"))
    }

    @Test
    fun `is case insensitive`() {
        assertEquals("youtube.com", norm("HTTPS://WWW.YouTube.COM"))
    }

    @Test
    fun `rejects search queries and placeholder bar text`() {
        // A bar showing a query, not a URL: any space disqualifies it.
        assertNull(norm("Search or type URL"))
        assertNull(norm("how to stop scrolling"))
        assertNull(norm("youtube com"))
    }

    @Test
    fun `rejects blank, single-label and too-short input`() {
        assertNull(norm(null))
        assertNull(norm(""))
        assertNull(norm("   "))
        assertNull(norm("localhost"))
        assertNull(norm("a.c")) // under the 4-char floor
        // …but the floor is only 4: a short real host still passes.
        assertEquals("a.co", norm("a.co"))
    }

    @Test
    fun `rejects IP literals, which the matcher cannot express`() {
        assertNull(norm("192.168.1.1"))
        assertNull(norm("https://127.0.0.1:8080/admin"))
    }

    @Test
    fun `browser recognition is membership, not a heuristic`() {
        // The gate on the whole web branch: an unlisted browser is never even
        // read. Chrome is mapped; a random package and an unlisted browser
        // are both out.
        assertTrue(BrowserUrlExtractor.isBrowser("com.android.chrome"))
        assertFalse(BrowserUrlExtractor.isBrowser("com.instagram.android"))
        assertFalse(BrowserUrlExtractor.isBrowser("com.example.notabrowser"))
    }
}
