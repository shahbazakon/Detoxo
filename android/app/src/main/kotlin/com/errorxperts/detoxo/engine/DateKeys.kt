package com.errorxperts.detoxo.engine

import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale
import java.util.TimeZone

/**
 * The engine's shared "dd-MM-yyyy" day key (device-local time). One cached
 * formatter instead of a fresh [SimpleDateFormat] allocation per call on the
 * accessibility hot path. ThreadLocal because SimpleDateFormat is not
 * thread-safe and the widget provider / job service can run off the service's
 * main thread. (Subclassed initialValue: ThreadLocal.withInitial is API 26+,
 * minSdk is 24.)
 */
object DateKeys {

    private class Cache {
        val fmt = SimpleDateFormat("dd-MM-yyyy", Locale.US)
        var minute = Long.MIN_VALUE
        var key = ""
    }

    private val cache = object : ThreadLocal<Cache>() {
        override fun initialValue() = Cache()
    }

    fun today(): String = today(System.currentTimeMillis())

    /**
     * The day key for an already-read clock. The per-event nudge tick calls
     * this with `onAccessibilityEvent`'s single `nowMs`, so the event keeps its
     * one-clock-read invariant instead of taking a second.
     */
    fun today(now: Long): String {
        val c = cache.get()!!
        // Memoised per wall-clock minute: the counter asks for the key on every
        // surface check, and a zone lookup + format each time was the single
        // largest allocation on that path. A day key can only change on a
        // minute boundary, so this is exact.
        // ponytail: a timezone change lands within the same minute — up to 60 s
        // of counts land on the old zone's day key.
        val minute = now / 60_000L
        if (minute != c.minute) {
            // SimpleDateFormat snapshots the zone at construction; the service
            // process lives for weeks, so a timezone change (travel, auto-adjust)
            // would otherwise keep rolling the day over at the OLD zone's midnight.
            c.fmt.timeZone = TimeZone.getDefault()
            c.key = c.fmt.format(now)
            c.minute = minute
        }
        return c.key
    }

    /**
     * The key of the local day before [now] — the block counters' "yesterday"
     * (EVO-060). Calendar arithmetic, not `now - 24h`: across a DST change a
     * day is 23 or 25 hours long and the subtraction lands on the wrong key.
     *
     * Not memoised and not on the cached formatter (whose zone `today` owns):
     * this runs once per block, behind the block debounce, and once per status
     * query — never per accessibility event.
     */
    fun dayBefore(
        now: Long = System.currentTimeMillis(),
        zone: TimeZone = TimeZone.getDefault(),
    ): String {
        val cal = Calendar.getInstance(zone).apply {
            timeInMillis = now
            add(Calendar.DAY_OF_MONTH, -1)
        }
        return SimpleDateFormat("dd-MM-yyyy", Locale.US).apply { timeZone = zone }.format(cal.time)
    }
}
