# Notification Suppression

Written from shipped source. Detoxo could stop a user *entering* a blocked app, but not stop that
app **reaching out and pulling them back**: a locked Instagram still posted "3 new reels", the
banner landed, the user tapped, the engine bounced them, and the notification was still in the shade
to tap again. This closes that hole. Plan doc:
[`plan_docs/06-M5-notification-suppression.md`](../plan_docs/06-M5-notification-suppression.md)
(shipped, with one deliberate deviation — §7).

The load-bearing decision: **the suppressed set is never computed, pushed or stored.** Every
notification is decided against the engine's live in-memory state via
[`RuleEngine`](27-rules-engine.md). Dart owns one boolean and the permission grant; that is all.

---

## 1. Layout

```
android/.../notifications/DetoxoNotificationListener.kt   the NotificationListenerService
android/.../engine/SuppressionDecision.kt                 the decision — Android-free, JVM-tested
android/.../engine/NotificationListenerCheck.kt           the Settings.Secure grant check
```

There is **no `lib/features/notification_suppression/`**. The feature is one bool on `AppSettings`
riding the existing `pushSettings` arm, one toggle in the Settings → Privacy section, and a seventh
entry in the permission funnel. No repository, no cubit, no DI registration, no barrel export —
and because `settings_screen.dart` is an exempt composition root,
`tool/boundaries_baseline.txt` is unchanged (7 entries).

## 2. What the user gets

A **Notification silence** toggle under Settings → Privacy, **off by default**. While it is on, an
app the user has locked in the App Blocker, or that an active schedule / daily-limit rule names,
does not notify: no sound, no banner, no shade entry. When the block lifts — window closes, limit
resets at midnight, a Pause starts, the toggle goes off — its notifications come back. Nothing is
deleted, re-posted, modified or read.

Messages, calls, email, alarms, reminders and calendar events **always come through**, even from
a blocked app (EVO-038, §4) — Detoxo silences the feed, not the person.

**Scope is app-level blocks only.** An app blocked merely at its *reel surface* (Instagram under
Block All) still notifies — the user is expected to keep using it for DMs. Widening suppression to
reel-surface blocking would silence every enabled platform app under the default plan, WhatsApp
included (`wa_status` is a monitored platform). The user's lever for "this app is off limits" is a
lock or a schedule, and that is exactly what suppression follows.

## 3. The hot path

`onNotificationPosted` fires for **every notification from every app on the device**, in bursts.
Anything beyond metadata reads and an in-memory lookup turns a system callback into a latency
source, so the whole body is:

```kotlin
override fun onNotificationPosted(sbn: StatusBarNotification?) {
    try {
        val posted = sbn ?: return
        val pkg = posted.packageName ?: return
        val key = posted.key
        if (key.isNullOrEmpty()) return
        if (posted.user != Process.myUserHandle()) return      // work profile
        val service = DetoxoAccessibilityService.instance ?: return
        if (!service.shouldSuppressNotification(pkg)) return
        if (SuppressionDecision.isAlwaysAllowed(posted.notification?.category)) return
        cancelNotification(key)
    } catch (t: Throwable) {
        Log.w(TAG, "suppress failed: ${t.javaClass.simpleName}")
    }
}
```

A **work-profile** app carries the same package name as its personal copy while the block
arms are anchored to the current user, so a lock set in one profile must not silence the
other's. Only the exception's *type* is logged: the surrounding Kotlin idiom is
`${t.message}`, but a message on this path could embed a package name or key, and §5's
guarantee says none reaches Logcat.

`instance == null` is a **correct** early exit, not a degradation: every block Detoxo enforces
requires the accessibility service, so a dead service means nothing is blocked and nothing should be
silenced. Exceptions are swallowed and logged, never rethrown — a listener that crashes is unbound
by the system and silently stops working for the rest of the session.

`shouldSuppressNotification` on the service reads only its existing `@Volatile` mirrors
(`suppressNotifications`, `masterOn`, `protectedPkgs`, `blockedApps`, `pausedUntil`) and the
in-memory `ruleEngine` — **no SharedPreferences and no Dart round-trip**, the same contract as
the accessibility event path. (Not *allocation*-free: `RuleEngine`'s `for (e in snap.entries)`
allocates one list iterator per scan. Sub-microsecond TLAB bump, and the same cost the far hotter
accessibility loop already pays — noted so the claim stays true.)

## 4. The decision

`SuppressionDecision.shouldSuppress` is Android-free (like `RuleEngine` and `ReelTracker`) so it
runs on the JVM — a `NotificationListenerService` subclass never can. Order is load-bearing:

| # | Check | Result |
|---|---|---|
| 1 | `pkg == ownPkg` | **never** suppressed — Detoxo's own alerts are the user's only signal the engine died |
| 2 | `pkg in protectedPkgs` | **never** suppressed — the privacy guard outranks a lock *and* an active rule |
| 3 | `pkg in blockedApps` | suppressed, **above** the pause gate (App Blocker locks are unconditional) |
| 4 | `rules.blockingForPackage(pkg, now, strictOnly = paused)` | suppressed while a window covers `now`; a Pause narrows this to `strict` entries (EVO-030) |

Then one rule that is **not** a mirror, EVO-038: `isAlwaysAllowed(category)` lets
`msg` · `call` · `email` · `alarm` · `reminder` · `event` through even from a blocked app.
Detoxo blocks the *feed*, not the app — a lock must stop Instagram advertising reels, not
swallow a message from a person. A **null** category is not exempt, so an app cannot opt
itself out of a block by omission. The check runs **last**, only for notifications already
destined for cancellation. See
[`EVO-038`](../evolution/proposals/EVO-038-block-the-feed-not-the-person.md) for why
`category` beat per-channel `channelId` filtering.

The first four checks are a **MIRROR CONTRACT** with the block arms in `DetoxoAccessibilityService.onAccessibilityEvent`:
an app is silenced exactly when opening it would bounce the user HOME. Change the order or the pause
placement in one, change it in the other, or suppression starts silencing apps the user can still
open. A reel-meter entry (the global Daily Limit) never suppresses — it blocks a platform surface,
not an app.

## 5. Privacy

This is the most sensitive capability in the app, and both rules hold **in code**, not just intent:

1. **Protected packages are refused above everything else** (step 2 above). A notification listener
   sees far more of the device than the accessibility service's foreground-package view, so banking,
   UPI and password-manager apps are excluded even when they are also locked or scheduled.
2. **`onNotificationPosted` reads `packageName`, `key`, `user` and `notification.category`
   — and nothing else.** It never touches `.extras`, which is where the title, text, sender
   and images live. `category` is a fixed Android constant naming the *kind* of
   notification, chosen by the sending app from a closed set; it carries no user content,
   which is what made EVO-038 affordable. Grep-checkable, and checked:
   `grep -rn "\.extras" android/` must match only the KDoc that forbids it.

Nothing is stored, logged or transmitted — no package name reaches Logcat, and a cancelled
notification is never read, modified or re-posted.

**Binding follows the toggle — and it takes two mechanisms, not one.** Leaving the listener
bound while the feature is off would mean Detoxo keeps receiving every notification on the
device for nothing.

- `syncBinding` calls `requestRebind` / `requestUnbind` on a real change of the pushed flag.
  This is the **responsive** half (`requestRebind` is API 24; `minSdk` is 24).
- `onListenerConnected` re-reads the stored flag and unbinds itself when it is off. This is
  the **durable** half, and it is not optional: the system binds every listener enabled in
  `Settings.Secure` on boot and after a package replace regardless of an earlier
  `requestUnbind()`, and a user can grant notification access from the permission funnel
  without ever crossing the toggle. `syncBinding` alone is change-gated and covers neither
  case — shipping without this guard made "off means nothing" false after the first reboot
  (see the 2026-09-04 Tier-1 batch in [`BACKLOG.md`](../evolution/BACKLOG.md)).

## 6. Persistence, channel & manifest

**Native** `detoxo_engine_prefs` gains one key, `suppress_notifications` (Boolean, default `false`)
— see [09](09-persistence-data-model.md). The suppressed *set* has no key: it is derived per
notification, so it cannot become a second source of truth that disagrees with the first.

**Dart** persists `suppressNotifications` inside the existing `StoreKeys.settings` blob (no new
key), and it rides the existing `pushSettings` payload — see [18](18-platform-channel-contracts.md).
Two new query/launch methods carry the grant:

| Method | Args | Returns |
|---|---|---|
| `isNotificationListenerEnabled` | — | `Boolean` (read tri-state by the permission repository) |
| `openNotificationListenerSettings` | — | `Boolean` (launch ok) |

No new event types. The only manifest change is one `<service>` (see
[04](04-native-android-layer.md)); there is **no new `<uses-permission>`** — the
`BIND_NOTIFICATION_LISTENER_SERVICE` guard is declared on the tag, held by the system.

`NotificationListenerCheck` mirrors `AccessibilityCheck` against
`"enabled_notification_listeners"` (`Settings.Secure.ENABLED_NOTIFICATION_LISTENERS` is `@hide`,
hence the raw key), matching **both** the long and short flattened component forms — a false "not
enabled" would send an already-granted user down the restricted-settings recovery flow.

## 7. Deviation from the plan doc

The plan was written before M3 shipped. It specified Dart pre-computing a `currentlyBlockedPackages`
set and pushing it over a new `pushSuppressedApps` arm into a `suppressed_packages` StringSet, with
re-pushes on rule / blocklist / plan change and on `ruleBoundary` — and recorded a **staleness
ceiling**: a schedule window opening at 21:00 with no user action left the listener on the 20:59 set.

With M3 shipped, `RuleEngine` already holds the resolved windows in memory, so native derivation —
named in the plan's own `ponytail:` comment as the upgrade path — became both simpler *and* correct:
no Dart re-derivation of window logic native already owns, no new push, no new StringSet, no four
re-push triggers, and **no staleness at all**, since the windows are consulted at notification time.

Dropped accordingly: `lib/features/limits/notification_suppression/**`, `pushSuppressedApps`,
`StoreKeys.suppressedApps`, the `suppressed_packages` set, and the `ruleBoundary` re-push.

## 8. Permission funnel — the seventh entry

`AppPermission.notificationListener`: label "Notification access", `required: false` (suppression is
opt-in; the app works fully without it), `restrictedWhenSideloaded: true` (like accessibility,
overlay and device admin, it is an ECM-gated restricted setting for sideloaded installs). It routes
through the **existing** `requestPermission(context, kind)` entry point, so it inherits the
restricted-settings sheet, the tri-state read with the `lastKnownGranted` fallback, and the
resume-refresh — see [13](13-onboarding-permissions.md).

Because it is optional, `allRequiredGranted` (and therefore the splash gate) is unaffected. There is
no programmatic grant: `request` opens Android's "Notification access" list and the user toggles
Detoxo on there. A **prominent in-app disclosure** is shown first, from the same
`_disclosureFor` table that carries the Accessibility disclosure — see [22](22-play-release.md) for
the policy obligation behind it.

Turning the Settings toggle on while the grant is missing funnels the grant first, then commits the
setting either way: it is the user's intent, and it takes effect the moment the grant lands.

## 9. Ceilings

- ~~**All-or-nothing per app.**~~ **Resolved by EVO-038**: messages, calls, email, alarms,
  reminders and calendar events pass a block. What remains is that an app which sets **no**
  category has everything silenced — deliberate, since the alternative lets an app opt out
  of a block by omission.
- **App-level blocks only** (§2). Widening to reel-surface blocking would silence every enabled
  platform app under the default plan.
- Never re-post, modify, or read the content of a cancelled notification.

## 10. Tests

`SuppressionDecisionTest` (JUnit 4, JVM, 10 tests) pins the whole decision against a real
`RuleEngine`: own package never suppressed · a protected package never suppressed even when also
locked *and* named by an active rule, paused or not · an App Blocker lock suppresses through a Pause
· an active window suppresses but a closed one does not · a Pause lifts an ordinary rule but not a
strict one · unrelated packages never suppressed · a reel-meter entry never suppresses an app ·
the six always-allowed categories pass · `social`/`promo`/`recommendation`/`status`/empty do not ·
a null category is not exempt.

`test/notification_suppression_test.dart` pins the Dart boundary: the flag defaults off, survives a
JSON round-trip, reads off for a pre-M5 blob, and reaches the `pushSettings` map (with no
`suppressed*` key beside it) · the seventh permission is optional and `restrictedWhenSideloaded` ·
it reads tri-state (two null reads ⇒ `unknown`, never `denied`) · `request` opens the system screen.

Not unit-testable, so device sanity: block Instagram → its notification does not appear; unblock →
it does; a DM from a locked app still arrives while its feed notification does not; **reboot with
the toggle OFF → the listener connects and immediately unbinds itself** (the regression that made
"off means nothing" false); reboot with it ON → it reconnects and keeps working; grant from the
permission funnel without touching the toggle → binds, then unbinds itself; revoke access
mid-session → silent degradation, no crash; toggle accessibility → unrelated and unaffected.

## Source files
- `android/app/src/main/kotlin/com/errorxperts/detoxo/notifications/DetoxoNotificationListener.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/SuppressionDecision.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/NotificationListenerCheck.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/ConfigStore.kt` (`suppressNotifications`)
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/RuleEngine.kt` (`blockingForPackage` — the second consumer)
- `android/app/src/main/kotlin/com/errorxperts/detoxo/accessibility/DetoxoAccessibilityService.kt` (`shouldSuppressNotification`, the `suppressNotifications` mirror, `reload()`)
- `android/app/src/main/kotlin/com/errorxperts/detoxo/channels/CommandHandler.kt` (the `pushSettings` field + the two new arms)
- `android/app/src/main/AndroidManifest.xml` (the `<service>`), `android/app/src/main/res/values/strings.xml` (`notification_listener_label`)
- `lib/core/constants/channel_constants.dart`, `lib/core/platform_channels/engine_channel.dart`
- `lib/features/blocking/shared/domain/entities/app_settings.dart` (`suppressNotifications`)
- `lib/features/blocking/shared/data/repositories/engine_repository_impl.dart` (`pushSettings`)
- `lib/features/blocking/shared/presentation/settings_cubit.dart` (`setSuppressNotifications`)
- `lib/features/permissions/domain/entities/permission_status.dart` (`AppPermission.notificationListener`)
- `lib/features/permissions/data/repositories/permission_repository_impl.dart` (`_read`, `request`)
- `lib/features/permissions/presentation/permission_actions.dart` (`_disclosureFor`), `lib/features/permissions/presentation/permissions_screen.dart`
- `lib/features/settings/presentation/settings_screen.dart` (the Privacy toggle, `_setSuppressNotifications`, `_permissionIcon`)
- `android/app/src/test/kotlin/com/errorxperts/detoxo/engine/SuppressionDecisionTest.kt`
- `test/notification_suppression_test.dart`
