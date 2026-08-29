# M5 — Notification suppression

- Status: **shipped** — engineering doc [`code_docs/29-notification-suppression.md`](../code_docs/29-notification-suppression.md); on branch `sensitive_protection` (commit pending at the time of writing). **Shipped with one deliberate deviation — see the box below; the plan text under it is the original, pre-M3 design and is kept for the record.**
- Source: [B6 Notification Suppression](../suggestion_docs/flutter-migration/B-blocking/B6-notification-suppression.md)
- Feature areas: native `notifications/DetoxoNotificationListener.kt` + `engine/{SuppressionDecision,NotificationListenerCheck}.kt`; one `AppSettings` flag and one Settings → Privacy toggle (**no** `lib/features/limits/notification_suppression/` — see below)
- Effort: **M** (one native service, one settings flag, one permission-funnel entry)
- Blocked by: M3 — satisfied, M3 shipped first · Blocks: nothing

> ## ⚠ How this shipped, vs. what is planned below
>
> This plan was written while **M3 was unbuilt**, so it specified Dart pre-computing the blocked
> set and pushing it, and recorded a **staleness ceiling** it could not avoid (a window opening at
> 21:00 with no user action left the listener on the 20:59 set).
>
> M3 shipped first. `RuleEngine` now holds the resolved windows in memory and
> `blockingForPackage(pkg, now, strictOnly)` answers "is this package blocked right now"
> allocation-free — so **native derivation**, named in this doc's own `ponytail:` comment as the
> upgrade path, became both simpler *and* strictly more correct. It was built directly.
>
> | | Planned below | Shipped |
> |---|---|---|
> | Blocked-now source | Dart re-derives the set, pushes it | `SuppressionDecision` asks the live `RuleEngine` per notification |
> | Staleness | ceiling accepted, mitigated by `ruleBoundary` | **none** — windows consulted at notification time |
> | Channel | new `pushSuppressedApps` arm | one `suppressNotifications` bool on the existing `pushSettings` |
> | Native storage | `suppressed_packages` StringSet | `suppress_notifications` Boolean; the set is never stored |
> | Dart module | `lib/features/limits/notification_suppression/**` (entity, repo, cubit, tile) | none — one `AppSettings` field + one settings toggle |
> | Re-push triggers | 4 (rule / blocklist / plan change, `ruleBoundary`) | 0 |
>
> Also decided during implementation: **scope is app-level blocks only** (App Blocker locks +
> active package rules). Extending it to reel-surface blocking would silence every enabled
> platform app under Block All — the default plan — WhatsApp included, since `wa_status` is a
> monitored platform. And the listener is **unbound while the toggle is off**, so "off" means
> Detoxo receives no notifications at all rather than receiving and discarding them.
>
> Kept exactly as planned: the privacy rules (protected apps refused above everything, package
> name + key only, never `sbn.notification`), the never-do-work hot path, the swallowed
> exceptions, the manifest shape, the grant check mirroring `AccessibilityCheck`, the optional
> ECM-gateable seventh funnel entry, and the Play-policy work as part of the milestone.

## Why now

The intervention loop has a hole in it. Detoxo can stop the user *entering* a blocked feed, but it
cannot stop the blocked app from **reaching out and pulling them back**. Instagram posts "3 new
reels from people you follow"; the banner lands; the user taps; the engine bounces them; the
notification is still in the shade to be tapped again.

Blocking the app and then letting it advertise itself is a coherence failure, not a missing
nicety. Detoxo has **no `NotificationListenerService`** today — `grep -rn "NotificationListener"
android/` returns nothing, and `POST_NOTIFICATIONS` exists only for the app's own two channels
(`detoxo_protection_channel` 1125, `detoxo_watchdog_channel` 1127).

## What the user gets

While an app is blocked, its notifications do not arrive. No sound, no banner, no shade entry.
When the block lifts — schedule window closes, limit resets at midnight, pause starts — its
notifications come back. Nothing is deleted; the app just stops interrupting while it is off
limits.

## Source: what is taken, what is dropped

**Taken** — the whole design, including its central simplification.

**Dropped** — the source app's notification-suppression channel namespace (folds into the one
command channel) and the separate-process assumption. Its listener ran in its own process with
no Flutter engine alive, which is what forced the pre-computed-set design. **Detoxo is
single-process**, so a listener could in principle reach further — but the pre-computed set is
still the right design for a different reason, below.

## Algorithm & control flow

The load-bearing rule: **`onNotificationPosted` must never do work.** It is called on every
notification from every app on the device, including bursts. Anything beyond a set lookup — a
Dart round-trip, a rule evaluation, a disk read — turns a system callback into a latency source.

```
Dart (on any rule/blocklist change, and on `ruleBoundary`):
    blocked = rules.currentlyBlockedPackages(now)     // M3's snapshot, resolved
                .where { it != ownPackage }
                .where { it !in protectedPackages }   // privacy guard wins, always
    channel.pushSuppressedApps({ packages: blocked.toList() })

Native:
    onListenerConnected():
        instance = this
        blocked  = ConfigStore.suppressedPackages     // cold read; the service can start
                                                      // before Dart has ever run
    refresh(packages):                                // hot update while bound
        blocked = packages.toSet()

    onNotificationPosted(sbn):
        try {
            pkg = sbn?.packageName ?: return
            if (pkg == ownPackage)   return           // belt and braces
            if (pkg !in blocked)     return           // ONE set lookup — the whole hot path
            cancelNotification(sbn.key)
        } catch (t) { Log.w(TAG, t) }                 // never crash the listener
```

Exceptions are swallowed and logged, never rethrown. A listener that crashes is unbound by the
system and silently stops working for the rest of the session.

### The privacy guard is not optional here

Detoxo's engine already ignores protected apps entirely — banking, UPI, password managers — at
step 3 of the event loop, above everything else. A notification listener sees the **content** of
every notification on the device, which is a far larger surface than the accessibility service's
foreground-package view.

Two rules follow, and both must hold in code, not just in intent:

1. Protected packages are subtracted from the suppressed set in Dart **and** re-checked natively.
2. `onNotificationPosted` reads `sbn.packageName` and `sbn.key` and **nothing else**. It must never
   touch `sbn.notification.extras`. A code-review checklist entry, and a comment at the call site.

### Grant check

```
isNotificationListenerEnabled():
    flat = Settings.Secure.getString(cr, "enabled_notification_listeners") ?: return false
    return flat.split(":")
               .mapNotNull { ComponentName.unflattenFromString(it) }
               .any { it.packageName == context.packageName }
```

This mirrors `engine/AccessibilityCheck.kt`, which already does the equivalent parse against
`ENABLED_ACCESSIBILITY_SERVICES` and matches **both** the long and short flattened forms. Reuse its
approach rather than writing a second, weaker parser.

### Staleness — the one real ceiling

B6 flags it explicitly: a pushed set goes stale at a **schedule boundary**. A rule window opens at
21:00 with no user action, so nothing pushes, and the listener keeps using the 20:59 set.

The fix is already built by M3: the `ruleBoundary` event fires when a window opens or closes, and
Dart re-pushes then. That is why M5 is sequenced after M3 rather than before it.

`ponytail: the suppressed set is a snapshot; it goes stale between ruleBoundary events if the
process is dead and the watchdog is deferred. Upgrade path = have the native RuleEngine derive
the set itself from the pushed rule snapshot, since it already holds the windows.`

**Never** add a Dart round-trip inside `onNotificationPosted` to fix this. That is the one
solution B6 rules out by name, and it is right to.

## Data model

Nothing new in Hive beyond the setting itself.

`StoreKeys.suppressedApps`:

```jsonc
{ "enabled": false, "lastPushedMs": 0 }
```

The set is **derived, never stored** — it is a projection of M3's rules plus the blocklists, and
storing it would create a second source of truth that can disagree with the first.

Native `detoxo_engine_prefs` gains `suppressed_packages` (a `StringSet`), written by the push and
cold-read in `onListenerConnected`. Same shape and lifecycle as the existing
`protected_packages` and `app_blocklist_packages` sets.

## Channel delta

| Method | Args | Returns |
|---|---|---|
| `pushSuppressedApps` | `{packages: List<String>}` | `true`; no-op on absent/malformed; set-if-changed |
| `isNotificationListenerEnabled` | — | `Boolean` |
| `openNotificationListenerSettings` | — | `Boolean` (launch ok) |

`pushSuppressedApps` is a **byte-for-byte copy of `pushProtectedApps`'s contract**
([`channel_constants.dart:28`](../../lib/core/constants/channel_constants.dart#L28)) — flat list,
fail-safe, no-op on malformed input. That symmetry is deliberate: two pushes with the same shape
are two pushes one person can hold in their head.

No new event types.

## Permission funnel — a seventh entry

`AppPermission` gains `notificationListener`:

| Field | Value |
|---|---|
| Label | "Notification access" |
| Required | **no** — suppression is opt-in; the app works fully without it |
| ECM-gateable | **yes** — like accessibility, overlay and device admin, it is a restricted setting for sideloaded installs |
| Status | `isNotificationListenerEnabled` |
| Request | `openNotificationListenerSettings` |

It routes through the **existing** `requestPermission(context, kind)` entry point, so it inherits
the restricted-settings sheet, the tri-state read with the `lastKnownGranted` fallback, and the
resume-refresh — none of which needs to be rewritten.

## Manifest delta

The only manifest change in the entire plan:

```xml
<service
    android:name=".notifications.DetoxoNotificationListener"
    android:exported="false"
    android:permission="android.permission.BIND_NOTIFICATION_LISTENER_SERVICE">
    <intent-filter>
        <action android:name="android.service.notification.NotificationListenerService" />
    </intent-filter>
</service>
```

No new `<uses-permission>`.

## Module layout

```
lib/features/limits/notification_suppression/
├── domain/entities/suppression_state.dart
├── domain/repositories/notification_suppression_repository.dart
├── data/repositories/notification_suppression_repository_impl.dart
└── presentation/{suppression_cubit.dart, suppression_tile.dart}

android/.../notifications/DetoxoNotificationListener.kt
```

Exported from `lib/features/limits/limits.dart`.

## Reuse map

| Existing | Take |
|---|---|
| `pushProtectedApps` arm in `CommandHandler.kt` | The exact fail-safe contract and set-if-changed diff |
| `ConfigStore.protectedPackages` | The `StringSet` persistence idiom |
| `engine/AccessibilityCheck.kt` | The `Settings.Secure` flattened-component parse, including the both-forms match |
| `PermissionsCubit` + `permission_actions.dart` | The whole funnel: tri-state reads, `effectivelyGranted`, restricted-settings recovery, resume refresh |
| `DetoxoAccessibilityService`'s `@Volatile` hot-path mirrors | The same pattern for `blocked` — never read prefs per callback |
| `DetoxoAccessibilityService`'s privacy guard | Protected packages are excluded before anything else happens |

## Steps

1. `DetoxoNotificationListener.kt` — `onListenerConnected` cold read, `refresh()`, and a
   `onNotificationPosted` that does exactly one set lookup.
2. Manifest service entry.
3. The three command arms + `ConfigStore.suppressedPackages`.
4. Add `AppPermission.notificationListener` with `required: false`, `restrictedWhenSideloaded: true`.
5. Dart repository + cubit; derive the set from M3's rules minus protected minus self.
6. Re-push on: rule change, blocklist change, plan change, and the `ruleBoundary` event.
7. Settings toggle with copy that states plainly what notification access permits — this grant is
   broader than it looks and the user deserves to know that before granting it.
8. `/docs-sync` — 04, 06, 12, 13, 18, 22, 24 + `info_docs/02` and `03-permissions-explained.md`.

## Risks & ceilings

- **Play policy is the real risk here, not the code.** `BIND_NOTIFICATION_LISTENER_SERVICE` on an
  app that already declares an AccessibilityService and device-admin invites scrutiny. Required
  before shipping: a prominent disclosure at grant time, an honest data-safety answer (notification
  metadata is read and **never** stored or transmitted), and an updated
  `22-play-release.md`. Treat the policy work as part of the milestone, not paperwork after it.
- **Privacy blast radius.** See the two rules above. This is the most sensitive capability in the
  plan and the one most worth being conservative about.
- **Staleness ceiling** — recorded above; mitigated by M3's `ruleBoundary`.
- `ponytail: suppression is all-or-nothing per app; a blocked app's DM notification is cancelled
  alongside its feed notification. Upgrade path = per-channel filtering via
  sbn.notification.channelId — which requires reading more of the notification, so it is a
  deliberate privacy trade, not a free improvement.`
- **Never** re-post, modify, or read the content of a cancelled notification.

## Validation

- [ ] `bash tool/dev.sh precommit` passes
- [ ] With the listener **not** granted, everything behaves exactly as today; the funnel shows it
      as optional and ungranted
- [ ] Revoking notification access mid-session degrades silently — no crash, no ANR
- [ ] Protected apps are never in the suppressed set (test both the Dart derivation and the native
      re-check)
- [ ] Detoxo's own two notifications are never cancelled
- [ ] Grep check: `sbn.notification` appears **nowhere** in the listener
- [ ] Device sanity: block Instagram → its notification does not appear; unblock → it does; reboot
      → the listener reconnects and cold-reads the set; toggle accessibility → unrelated and
      unaffected
- [ ] `pubspec.yaml` unchanged
- [ ] `tool/boundaries_baseline.txt` line count ≤ 8

## Target files

**New** — `android/.../notifications/DetoxoNotificationListener.kt` ·
`lib/features/limits/notification_suppression/**` · `test/notification_suppression_test.dart`

**Edited** — `android/app/src/main/AndroidManifest.xml` (service only) ·
`android/.../channels/CommandHandler.kt` · `android/.../engine/ConfigStore.kt` ·
`lib/core/constants/channel_constants.dart` · `lib/core/storage/local_store.dart` ·
`lib/features/permissions/**` (7th entry) · `lib/features/limits/limits.dart` ·
`lib/features/settings/presentation/settings_screen.dart` · `lib/core/di/injector.dart`
