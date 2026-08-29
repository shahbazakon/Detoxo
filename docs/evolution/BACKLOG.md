# Evolution Backlog

Ledger for `/detoxo-evolution` (see `.claude/skills/detoxo-evolution/SKILL.md`).
Lifecycle: `proposed` → `approved` → `done` (commit-stamped) | `rejected` (kept
forever — the settled-decisions memory). IDs are monotonic and never reused.

| ID | Title | Feature | Tier | Status | Effort | Proposed | Decided |
|---|---|---|---|---|---|---|---|
| EVO-001 | Smart Auto Lock for the PIN lock | access_protection | 2 | done | M | 2026-08-07 | 2026-08-07 |
| EVO-002 | Harden the PIN KDF (PBKDF2, transparent re-hash) | access_protection | 2 | proposed | S | 2026-08-08 | — |
| EVO-003 | Commitment delay on disabling the PIN lock | access_protection | 2 | proposed | M | 2026-08-08 | — |
| EVO-004 | "While you were away" failed-attempt notice | access_protection | 2 | proposed | S | 2026-08-08 | — |
| EVO-005 | Exclude sensitive stores from Android backup | protected_apps, onboarding | 2 | done (in the working tree; stamp the hash on commit) | S | 2026-08-13 | 2026-09-04 |
| EVO-006 | Validate + give feedback on manual adds (protected + blocker) | protected_apps, app_blocker | 2 | done | S | 2026-08-13 | 2026-08-14 |
| EVO-007 | Installed-app picker (labels + icons) for manual adds | protected_apps, app_blocker, core | 2 | done | M | 2026-08-13 | 2026-08-14 |
| EVO-008 | Real device icons on saved Block/Protected rows | app_blocker, protected_apps | 2 | done | S | 2026-08-14 | 2026-08-14 |
| EVO-009 | "Suggested" section at the top of the add-app picker | core (picker) + native | 2 | proposed | M | 2026-08-14 | — |
| EVO-010 | Refresh affordance in the add-app picker | core (picker) | 2 | done | S | 2026-08-14 | 2026-08-14 |
| EVO-011 | "Blocked by Detoxo" toast at the block moment | web_blocker (native) | 2 | done | S | 2026-08-17 | 2026-08-17 |
| EVO-012 | Per-site pause, activating dormant pausedUntil | web_blocker + native | 2 | done | M | 2026-08-17 | 2026-08-17 |
| EVO-013 | Honest protection status when OS kills the service | blocking/engine + native | 2 | done | S | 2026-08-17 | 2026-08-17 |
| EVO-014 | Render permission/service `unknown` states truthfully | permissions, dashboard, design_system | 2 | done | S | 2026-08-27 | 2026-08-27 |
| EVO-015 | Anchor the PIN lockout to the monotonic clock | access_protection + native | 2 | done | M | 2026-08-27 | 2026-08-27 |
| EVO-016 | Narrow the accessibility event mask to the 3 used types | native res/xml | 2 | done | S | 2026-08-27 | 2026-08-27 |
| EVO-017 | Compile the 18+ list from a JSON source (scrape folded in) + block adult TLDs | web_blocker + native asset + tool | 2 | done | S | 2026-08-28 | 2026-08-28 |
| EVO-018 | Count adult-list blocks without naming the host | web_blocker (native) | 2 | done | S | 2026-08-28 | 2026-08-28 |
| EVO-019 | Escalate to HOME when BACK can't leave a blocked page | web_blocker (native) | 2 | proposed | S | 2026-08-28 | — |
| EVO-020 | Reel identity from the settled pager page + 1 s dwell (counter) | content_counter (native) + One Reel gate | 2 | done | M | 2026-08-29 | 2026-08-29 |
| EVO-021 | Back off the stage-3 DFS on counting-pass misses | content_counter (native) | 2 | done | S | 2026-08-29 | 2026-08-29 |
| EVO-022 | Truthful counter states (bubble grant, counting off) | content_counter, appearance, dashboard | 2 | done | S | 2026-08-29 | 2026-08-29 |
| EVO-023 | Run the native JVM tests in the precommit gate | tool | 2 | done | S | 2026-08-29 | 2026-08-29 |
| EVO-024 | Per-platform pager view-id for reel identity | content_counter (native) + config schema | 2 | done (mechanism; per-app ids pending device calibration) | M | 2026-08-29 | 2026-08-29 |
| EVO-025 | Count down before "Back to {app}" unlocks on the block screen | block_screen + native overlay | 2 | done (in the working tree; stamp the hash on commit) | S | 2026-09-03 | 2026-09-03 |
| EVO-026 | Keep the wall up when the engine's BACK ejects to another app | native service + overlay | 2 | done (in the working tree; stamp the hash on commit) | S | 2026-09-03 | 2026-09-03 |
| EVO-027 | "Opened N times today" on the wall from the usage layer | block_screen + native usage/overlay | 2 | done (in the working tree; stamp the hash on commit) | M | 2026-09-03 | 2026-09-03 |
| EVO-028 | "Unlocks at …" on the rule wall | limits/rules + native overlay | 2 | done (in the working tree; stamp the hash on commit) | S | 2026-09-03 | 2026-09-03 |
| EVO-029 | Reconcile daily limits natively at the watchdog tick | limits/rules + native engine/receivers | 2 | done (in the working tree; stamp the hash on commit) | M | 2026-09-03 | 2026-09-03 |
| EVO-030 | Strict rules a Pause cannot lift | limits/rules + native service | 2 | done (in the working tree; stamp the hash on commit) | S | 2026-09-03 | 2026-09-03 |
| EVO-031 | One-tap rule presets | limits/rules | 2 | done (in the working tree; stamp the hash on commit) | S | 2026-09-03 | 2026-09-03 |
| EVO-032 | Exclude protected apps from Insights | analytics/insights + protected_apps | 2 | done (in the working tree; stamp the hash on commit) | S | 2026-09-04 | 2026-09-04 |
| EVO-033 | Set a daily limit straight from a top app | analytics/insights + limits/rules | 2 | done (in the working tree; stamp the hash on commit) | S | 2026-09-04 | 2026-09-04 |
| EVO-034 | Show what the reach cost, on the wall | block_screen (native) + usage | 2 | done (in the working tree; stamp the hash on commit) | S | 2026-09-04 | 2026-09-04 |
| EVO-035 | Stop comparing a part-day against a whole one | analytics/insights | 2 | done (in the working tree; stamp the hash on commit) | S | 2026-09-04 | 2026-09-04 |

| EVO-036 | Render suppression truthfully when the grant is missing | settings, permissions | 2 | done (in the working tree; stamp the hash on commit) | S | 2026-09-04 | 2026-09-04 |
| EVO-037 | Offer Notification silence on the App Blocker screen | limits/app_blocker | 2 | done (in the working tree; stamp the hash on commit) | S | 2026-09-04 | 2026-09-04 |
| EVO-038 | Block the feed, not the person (messages/calls pass a block) | notification suppression (native) | 2 | done (in the working tree; stamp the hash on commit) | M | 2026-09-04 | 2026-09-04 |
| EVO-039 | Keep the promise a skipped survey makes | onboarding | 2 | done (in the working tree; stamp the hash on commit) | S | 2026-09-04 | 2026-09-04 |
| EVO-040 | Give the onboarding funnel a denominator | onboarding, core/services/firebase | 2 | done (in the working tree; stamp the hash on commit) | S | 2026-09-04 | 2026-09-04 |
| EVO-041 | The permissions gate must not destroy in-progress work | core/navigation | 2 | done (in the working tree; stamp the hash on commit) | S | 2026-09-04 | 2026-09-04 |
| EVO-042 | Tell the truth when the soft nudge cannot render | settings, permissions | 2 | done (in the working tree; stamp the hash on commit) | S | 2026-09-04 | 2026-09-04 |
| EVO-043 | Give the nudge card one way out | soft nudge (native overlay) | 2 | done (in the working tree; stamp the hash on commit) | M | 2026-09-04 | 2026-09-04 |
| EVO-044 | Say what was measured, not what was assumed | soft nudge (copy) | 2 | done (in the working tree; stamp the hash on commit) | XS | 2026-09-04 | 2026-09-04 |
| EVO-045 | Throttle the nudge tick | soft nudge (native service) | 2 | done (in the working tree; stamp the hash on commit) | S | 2026-09-04 | 2026-09-04 |
| EVO-046 | PIN-gate protecting a browser | protected_apps + web_blocker | 2 | done (in the working tree; stamp the hash on commit) | S | 2026-09-04 | 2026-09-04 |
| EVO-047 | Name the browsers Detoxo cannot cover | web_blocker + native channels | 2 | done (in the working tree; stamp the hash on commit) | M | 2026-09-04 | 2026-09-04 |
| EVO-048 | Anchor per-site pause expiry to the monotonic clock | web_blocker (native) | 2 | done (in the working tree; stamp the hash on commit) | S | 2026-09-04 | 2026-09-04 |
| EVO-049 | Bound the blocked-host tally | web_blocker (stats) | 2 | done (in the working tree; stamp the hash on commit) | S | 2026-09-04 | 2026-09-04 |
| EVO-050 | Render the duration chips on the wall itself | block_screen (native) + limits/unblock | 2 | done (in the working tree; stamp the hash on commit) | M | 2026-09-06 | 2026-09-06 |
| EVO-051 | One place that lists what is currently unblocked | limits/unblock, dashboard | 2 | done (in the working tree; stamp the hash on commit) | S | 2026-09-06 | 2026-09-06 |
| EVO-052 | Make overrides visible: the cost before, the history after | limits/unblock, analytics | 2 | done (in the working tree; stamp the hash on commit) | S | 2026-09-06 | 2026-09-06 |
| EVO-053 | Ration the grants, not only the overrides | limits/unblock, settings | 2 | done (in the working tree; stamp the hash on commit) | M | 2026-09-06 | 2026-09-06 |

## 2026-09-04 — Tier-1 batch (notification suppression / M5 evolution run)

Corrective, no proposal files. Found by auditing M5 immediately after it shipped:

1. **The listener stayed bound with the feature OFF.** `syncBinding` had one caller, gated on
   a *changed* pushed flag, so a funnel-only grant never unbound it and an ON→OFF→reboot
   rebound it for the rest of the boot cycle. The "off means Detoxo receives nothing"
   guarantee — asserted in the Play prominent disclosure, the manifest and four docs — was
   false. Fixed with a switch re-assertion in `onListenerConnected`, the only place that can
   survive a reboot; `syncBinding` is now documented as the responsive half only.
2. `Log.w(TAG, "…", t)` was the only 3-arg throwable log in the Kotlin tree, on the one path
   whose entire input is package names and notification keys, 46 lines under a KDoc promising
   none reaches Logcat. Now logs the exception type only.
3. Work-profile apps share a package name with their personal copy, so they inherited
   personal-profile locks. `sbn.user != Process.myUserHandle()` is now skipped.
4. `sbn.key` was unguarded (`packageName` beside it was) — an empty key silently matched
   nothing, so suppression appeared broken with no signal.
5. The listener's "no allocation" comment was wrong: `for (e in List)` allocates an iterator.
   Cost is noise; the claim was the defect.
6. `_PermissionsTile` counted `s.granted` across all 7 permissions, so "All set" became
   unreachable — it demanded uninstall protection and notification access, both shipped off
   by design. Now counts **required** only, via `effectivelyGranted`, matching the funnel's
   own predicate; `_PermissionSheet` uses the same predicate.
7. The permission fan-out awaited each leg serially inside the splash gate, each able to
   sleep 150 ms retrying a null read. Now `Future.wait`, pinned by a concurrency test.
8. Toggle subtitle shortened — at 57 chars it truncated against the design system's
   `maxLines: 2` at ~1.3x text scale, and it was the only in-app statement of what the
   switch does.

## 2026-09-04 — Tier-1 batch (no proposal files; corrective)

Shipped alongside EVO-032/033/034/035 in the insights evolution run:

1. **Crashlytics no longer uploads decode-failure source text.** `FormatException.toString()`
   embeds a window of the string being decoded; five repositories log a decode failure as
   `AppLogger.e(msg, e)`, so a corrupt blob shipped package names — including the
   protected-apps list — to Firebase. Redacted once at the `AppLogger` → Crashlytics bridge
   (`FirebaseServices.offDevice`), pinned by `test/crash_redaction_test.dart`.
2. `InsightsCubit`: `emit` past a second `await` (StateError on leaving the tab mid-scan),
   no `catch` (permanent spinner), numbers gated on the installed-apps scan, and a stale
   `yesterday` surviving a day rollover. `test/insights_cubit_test.dart`.
3. `AnalyticsCubit` never cancelled its block-stream subscription — N mounts meant N racing
   writers on one Hive key, dropping the user's own block events. Appends are now serialised.
   `test/analytics_buffer_test.dart`.
4. Accessibility: `StatCard` gained a merged label and reduce-motion honouring; the insights
   hero and top-app rows announce; the proportion bar is now the shared `ProgressBar`.
5. `DailyStats.fromJson` is tolerant of wrong-typed values, not only missing ones.
6. A backwards device clock can no longer overwrite a finished day with a partial one; the
   exact-midnight fast path checks the grant instead of rendering `0m`.
7. `PermissionCard`'s unknown state can carry an action — the insights "Retry" was previously
   dead code that two docs described as real.
8. One duration formatter: `screen_time_dial`'s third copy is gone, whole hours read `3h`,
   and Kotlin's `UsageQuery.formatHm` mirrors it.

## 2026-09-04 — Tier-1 batch (M6 onboarding / shell evolution run)

Corrective, no proposal files. Found by auditing M6 immediately after it shipped —
most of these were defects in that same milestone's own new code.

1. **The starter rule could be silently lost forever.** `StarterRuleSync` watched the
   false→true edge on `allRequiredGranted`, but `PermissionsCubit.effectivelyGranted`
   consults `_lastKnownGranted`, which `refresh()` overwrites *before* it emits — so
   `listenWhen` re-scored the PREVIOUS state against post-refresh memory. A previous emit
   holding a live `unknown` read back as granted, `!true` collapsed the edge, and the one
   artifact the whole M6 funnel exists to produce was never written. On the most ordinary
   path there is: the 400 ms poll after `request()` routinely returns `unknown`. Replaced
   the edge with a level read; the write is idempotent, so firing often is free.
2. **The selection step could dead-end permanently.** `state.isLoading || state.error == null`
   meant a *successful* scan finding zero installed supported apps rendered the spinner
   forever, with Next disabled and Skip already gone. Onboarding could never be completed,
   so `onboarded` never flipped and every relaunch returned to the same screen. `isLoading`
   is now the only spinner condition, and "pick at least one" is lifted when there is
   nothing to pick.
3. **`targets.load()` ran twice on first run** — the slow leg (native config push +
   installed-package scan). `SettingsCubit._commit` emits synchronously, so the phase-3
   guard re-read a predicate the phase-2 seed had just changed. HEAD had this as an
   `if/else`; M6 flattened it into two independent `if`s. `firstRun` is now captured up
   front.
4. **`rules` / `dailyLimit` / `streak` loaded twice on every cold start** — `main.dart`
   `..load()`ed them at provider construction and the bootstrap loaded them again;
   `RulesCubit.load()` ends in a resync, so that was two UsageStats reads and two native
   snapshot pushes per launch. The bootstrap is now the single owner.
5. **`runBootstrap` could leave `ready` false forever.** The prologue's `context.read`s and
   the `gate.update` argument list sat outside `guardedSync`, and the returned future was
   discarded — a throw there pinned every location to `/` with force-stop as the only exit,
   the exact bug the guards were added to prevent. Wrapped in try/finally; the finally
   opens the gate, reading `onboarded` from the repository so a failure cannot re-onboard
   an existing user.
6. **`mounted` sat inside the rule-write condition**, so an unmounted teardown skipped the
   write and then fell through to consume the record — never written, never retryable.
7. **A grant discovered before `RulesCubit` loaded was dropped.** `save` refuses while
   `!state.loaded`, and the edge would not fire again that session. A second listener now
   re-checks when `loaded` flips, keeping `rules.load` off the startup critical path.
8. **The one failure that matters was invisible in release.** The rejected-save path used
   `AppLogger.w`, which is `kDebugMode`-only; only `.e` reaches Crashlytics.
9. **A completed record orphaned by a crash was never cleaned up** — the step guard
   short-circuited before the clear, leaving the user's name in Hive until "Reset app data".
10. **Disabled buttons were invisible to screen readers.** `PrimaryButton` / `SecondaryButton`
    returned a bare `Opacity`, skipping `AppPressable`'s Semantics — announced as static
    text, unfocusable by switch access. Whole-app, surfaced by onboarding gating Next.
11. **`ProjectionStep` was the one step that could not scroll** — a bare `Column` inside
    fixed 96/168 padding, holding `displayMedium`; it overflowed at large text scale.
12. **`UnsupportedScreen` was the only non-glass screen in the app**, and M6 made it
    reachable for the first time — so it was the sole screen an unsupported user would see.
13. Name field gained `maxLength: 40` (the `rule_editor_screen` convention) and an explicit
    Semantics label — a collapsed `hintText` is announced only while the field is empty.
14. The commitment promise is now rendered FROM the preset instead of restating its hours,
    which had made a third copy of "22:00–07:00" in the one place no test asserted.
15. The `?tab=` deep-link seam was **deleted**: nothing in the repo produced such a URL, and
    `AppGate.redirect` returns a bare `Routes.home`, so `initialTab` was provably always 0.
16. `dailyLimitMinutes` is clamped to the dial's range on read — a restored or hand-edited
    record could otherwise hand `setLimit` a 0, which `isExceeded` treats as "no limit",
    silently disabling the ceiling while the screen still showed one.
17. ~8 comments still described gating as living in the splash.
18. New tests: `test/starter_rule_sync_test.dart` (the write/skip/clear decisions, incl. the
    regressions in 1, 6 and 9) and `test/bootstrap_test.dart` (`guardedSync` never lets a
    failing leg stop app start).


## 2026-09-04 — Tier-1 batch (soft nudge / M7 evolution run)

Corrective, no proposal files. Found by auditing M7 immediately after it shipped; every one
of these was introduced by that milestone unless noted.

1. **A protected app's package reached the nudge.** `nudgeForegroundPkg` was latched inside
   the `WINDOW_STATE_CHANGED` branch — above the privacy guard — gated only on `!isIme`,
   while the content counter two lines up took `!pkgProtected` explicitly. Trace: a protected
   app foregrounds and is latched; the soft keyboard then opens under the IME's package, which
   clobbers `foregroundPkg`, so the guard at the single decision point stops firing while the
   latch still points at the protected app — which is then passed to `tick`, and if it is also
   `distracting` (a supported, PIN-gated user action) can start a session, name the app on a
   card and ship its package in `nudgeShown`. The service's own KDoc for
   `activeWindowProtected` names this exact failure mode. Fixed by latching `null` for a
   protected app, plus subtracting the protected set from the pushed watch list natively in
   `refreshNudgeConfig` (re-run from `refreshProtectedPackages`) so both anchors would have to
   fail. HIGH — violated `24-protected-apps.md`.

2. **The daily cap and the live dwell session were wiped on every app resume.**
   `refreshNudgeConfig` built a *new* `NudgeTracker`, and it is reached from `reload()` ←
   `pushSettings` ← `SettingsCubit.resync()`, which runs on every resume, unthrottled — and
   from `_commit`, so changing the theme did it too. The documented "four cards per app per
   day" was false, and a user 4:50 into a stay who glanced at Detoxo got five fresh minutes.
   `CommandHandler` explicitly reasoned that diffing was pointless here because no hot-path
   set was touched; what a diff buys is idempotence, not CPU. Fixed with
   `NudgeTracker.configure`, which reconfigures in place and drops the session only when the
   *step* changes — the tally now survives everything short of process death, which is the
   ceiling that was actually accepted. Also wired the previously-dead `reset()`. HIGH.

3. **The wall and the card could coexist.** `tickNudge` guards on
   `BlockScreenOverlay.isShowing()`, but it runs *earlier in the same event* than the block
   path, so on the event that raised the wall a standing card survived it — and, being added
   later, sat above the wall taking taps through its `NOT_TOUCH_MODAL` window. Fixed by hiding
   the card in `raiseWall`. The doc's "the two overlays never coexist" is now true in both
   directions.

4. **Per-event allocation on the unthrottled path.** `NudgeTracker` copied an immutable
   `Session` data class on every event inside a watched app (~3.5 MB/h of young-gen garbage at
   fling rates). `ContentCounter.onAppActivity` — the sibling unthrottled per-event call — is
   pure `Long` field math, and that is the standing contract for that path. Session is now a
   mutable private holder.

5. **Raw Material `ChoiceChip`** — the only one in `lib/` — replaced with `AppChip`, which
   carries the glass treatment, the 48 dp tap target and `semanticLabel` (the caps announced
   as bare "2"/"4"). The sheet's two pickers also disagreed about pop-on-select; both now pop,
   matching every other picker sheet in the repo.

6. **The three `SettingsCubit` nudge setters had no test**, though the harness existed and
   `_FakeEngineRepo.pushNudgeConfig` was already a stub recording nothing — so the one thing
   `_commitNudge` exists to do was unverified. Now asserted, along with boundary clamping.

7. **`nudge_sync.dart` was the only sync helper not exported from its feature barrel**
   (`limits.dart` exports all three of its own). Already spreading: the M7 test imported the
   barrel and the deep path on adjacent lines.

8. **Play-release doc was stale in two answers that go on the form** — `SYSTEM_ALERT_WINDOW`
   named two overlays where there are now three, and the prepared AccessibilityService answer
   said the service had "one purpose … close the feed", which the nudge is not. Roadmap gained
   its missing M7 row, and its "no unit tests are bundled for the engine" line — false since
   before M7 — was corrected.

9. **Second clock read per event.** `tickNudge` called `dateKey()`, which took its own
   `System.currentTimeMillis()`, against the invariant stated on the line that reads the clock
   once for the whole event. `DateKeys.today(now)` overload added.

10. **Card a11y**: the ✕ was ≈37 dp against Android's 48 dp minimum and the card root was
    clickable with no `contentDescription`. `BlockScreenRenderer` sets both on every wall
    button; the card now matches.

11. **Doc claimed a test that does not exist** ("pinned by test" for the already-nudging
    branch). The path is genuinely unreachable at the clamped 1-minute floor, so the code was
    right and the claim was not.

12. **Dart-side bounds existed only in the UI option lists.** Native clamped correctly on get
    *and* set, so this was cosmetic — a corrupt blob rendered "up to -5 per app a day" in
    Settings while the engine enforced 1. `fromJson` and both setters now clamp to the same
    range.

Also folded in from the audit's LOW set: a **backwards wall clock** (NTP correction, manual
date change) made `elapsed` negative and suppressed every nudge for that app until the clock
caught up; the idle rule now ends the stay on a negative delta. And `NudgeTracker`'s
constructor coerces its tuning, so a direct caller cannot wedge the machine with a zero step.

## 2026-09-04 — Tier-1 batch (web blocker evolution run)

Corrective, no proposal files. Found by auditing the web blocker — the newest
surface with no evolution coverage (its EVOs 011/012/017/018 all predate the
Protection screen).

1. **The shipped 18+ asset was 46 domains behind its source.** `blocked_websites.json`
   grew to 276 entries on 2026-09-02; `adult_domains.txt.gz` was last compiled on
   2026-08-28 at 230. Every one of those 46 adult domains was unblocked on device with
   the toggle ON. The repo's own guard (`test/adult_blocklist_test.dart`, "source and
   asset drifted — run `bash tool/dev.sh adultlist`") had been red the whole time.
   Fixed by running the compiler; `docs/code_docs/06` corrected from 226 to 272.
2. **"In any browser" was false, in three UI strings and two info_docs.** Enforcement is
   gated on a closed 30-package allowlist (`BrowserUrlExtractor.isBrowser`), and the
   generic DFS fallback only widens coverage *within* it. `com.jio.web` ships as
   `"browser": true` in `platforms_config.json` and was absent from the allowlist —
   Detoxo listed a browser it enforced nothing in. Copy now says "any **supported**
   browser"; EVO-047 names the gap on screen.
3. **A corrupt stats blob killed the live stats stream for the session.** The
   `Map.from(data['hosts'] as Map)` cast sat *outside* the try that guards `jsonDecode`,
   inside `watch()`'s `await for` — the exact failure the try was written to prevent.
   `_read()` now coerces `hosts` at the source.
4. **A failed blocklist load rendered the "add your first site" call to action** over a
   list that is unreadable, not empty — and still enforced natively. Now a distinct
   error state with Retry; the raw `e.toString()` no longer reaches a user-facing toast,
   and the failure is recorded to Crashlytics instead of being swallowed.
5. **Kotlin's `normalizeHost` never stripped userinfo**, so `user:pass@youtube.com`
   became `user` and was never blocked — while Dart's `DomainValidator` strips it and is
   *tested* for it. The mapped-address-bar path (Chrome, Firefox, the common ones) was
   the half that failed; the DFS fallback survived via `URL_REGEX`.
6. **No JVM test existed for either pure class in the web path**, though 7 sibling engines
   have them. `BrowserUrlExtractorTest.kt` added, pinning the userinfo fix. `WebBlockEngine`
   still needs a `Context` seam to be testable — reported, not contorted.
7. `pausedLabel()` hard-coded 24-hour time while `formatLocalTime` exists and the sibling
   rules screens use it ("Paused until 17:30" here, "5:30 PM" one screen over).
8. **The swipe row's non-swipe path had no semantic hint** — TalkBack announced a bare
   "example.com, button" with Pause/Edit/Delete unreachable, on the one surface where
   swipe is the primary affordance.
9. **`EXACT` could never match anything**: its only caller passes `fullUrl = null`, and a
   rule rehydrated from an old blob showed as enabled and blocked nothing. Arm and enum
   value removed, so `fromWire` folds it into `DOMAIN`, which does block.
10. Doc drift in `06`: a source-list entry for a file that does not exist, a stale
    adult-domain count, a `handleBrowser` step that described toast-then-back when the code
    raises a wall first, a "effectively any browser" claim contradicting its own gate
    description 12 lines up, and a code snippet missing the `!paused` guard.
11. Smaller truths: `createdAt` documented a "newest-first ordering" nothing implements;
    the Protection pill's a11y label hardcoded its own denominator; `protectionCount` was
    derived in the widget while every sibling getter lives on state; `DomainValidator` had
    no total-length bound (a 2000-char paste validated and shipped to the wire); and its
    docstring promised punycode support the `[a-z]{2,24}` TLD class cannot deliver.

Rejected from the audit as noise: a 15-element linear scan, one `substring` per host label
behind the 150 ms throttle, and the Protection pill's pinned seed tint (deliberate, per the
comment above it). **Not ranked, deliberately:** the unmapped-browser DFS cost — whether a
12000-node walk on a page with no url-ish node matters depends on real binder timings that
cannot be read off the source. It needs a device measurement, not a guess.

## 2026-09-06 — Tier-1 batch (M8 locked rules / per-target unblock evolution run)

Corrective, no proposal files. Found by auditing M8 immediately after it shipped; all but the
last three were introduced by that milestone's own new code.

1. **A strict rule's websites were still free for the whole Pause** — the gap M8 exists to close.
   The pause early-return was gated on `hasStrictPlatformRules()` alone and sits ABOVE the browser
   arm, so the `hasStrictHostRules()` gate M8 added there was unreachable for any locked rule built
   from websites or a category (both carry no `platformIds`). `RuleEngine`'s own KDoc said that gate
   "has to open the pause gate"; it did not. Both legs now open it. The FAQ, which still advertised
   the bypass, is corrected in the same change — it was accurate until the code was fixed.
2. **Alias grants survived "Resume".** One tap minted a grant per `PopularSites.aliasesFor`, and
   `endEarly` filtered on the exact id — so resuming X left `twitter.com`, a fully working entry
   point, open for the rest of the window while the row's pill cleared and read as protected.
   `endEarly` takes `alsoEnd`, mirroring `grant`'s `alsoFree`.
3. **The App Blocker's grant appeared to do nothing** — M8's headline affordance on that screen.
   `nowMs` was read outside the per-row `Builder` and captured by the `context.select` closure, so a
   grant minted afterwards had `startMs > nowMs`, `isActiveAt` stayed false forever, the selector
   never changed value, and neither the pill nor "Resume" appeared — while the toast said it worked
   and a second tap minted a second grant. The web-blocker twin read the clock inside the selector
   and was correct: same logic, two copies, one drifted.
4. **The wall offered relief it could not deliver.** The App Blocker arm runs above the strict arm
   with `offersUnblock` defaulted true, so a package on the blocklist *and* under an open locked rule
   showed the button, took the tap, minted a grant that lifts only its own arm — and was bounced by
   the next event with no button and no explanation.
5. **A failed grant reported success.** Both row call sites discarded `grant()`'s bool and toasted
   unconditionally, and `UnblockState.error` was rendered by nothing at all. The app-wide listener
   now surfaces it; the wall path's bare `return` no longer leaves the user with silence.
6. **A corrupt ledger disabled every grant for the process.** `load()` returned before `resync()`,
   so two independent stores coupled: native was never re-pushed and every grant and "end early" was
   refused. `loaded` is now the grants' flag and `ledgerLoaded` the ledger's; a bad ledger costs the
   override quota and nothing else.
7. **`pending_unblock` had no TTL.** `launchDetoxo` swallows its own failure and the user can swipe
   Detoxo away before the drain — either way the key survived, and days later an unrelated launch
   opened a duration sheet nobody asked for, one tap from an hour-long bypass. Stamped, and dropped
   past 2 minutes; a backwards clock reads as stale too.
8. **`LockGuard` waved through two ways to neuter a locked rule**: re-saving it as a different
   `kind`, and "tightening" a budget to zero, which `resolveSnapshot` renders as no entry at all.
   Unreachable from today's editor; held because the guard is billed as the choke point.
9. **A draft lock could not be untoggled.** Confirming the dialog flipped the draft and the toggle
   vanished, so a mis-tap was escapable only by leaving the editor and losing every other pending
   edit — punishment for a decision the app had not yet acted on.
10. **The registry's hot-path gate never expired.** Per-type booleans derived at parse stayed true
    for the life of the process once any grant existed, so after the last one lapsed — with Flutter
    dead, the case native expiry exists for — every event still paid a clock read and a scan of up
    to 50 rows. `Snap` now holds the furthest deadline per type.
11. **`_lockWiden` scanned the catalog twice per locked rule**, against `packagesWithBehavior`'s own
    documented contract ("not per rule per resolve") — 100 scans per resolve at the 50-rule cap.
12. **The "Allowed until 10:30 PM" pill was ellipsised at 1.0x text scale** (`Pill` caps at 0.4x
    screen width), losing the only datum it carried; and it dropped `RuleSummary.clock`'s cross-day
    prefix, so a 60-minute grant at 23:40 read "Allowed until 12:40 AM" with no day.
13. One flow, five verbs — wall *Unblock*, sheet *Allow*, toast *allowed*, web row *Resume*, app row
    *Block again*. Settled on **Allow / Resume** everywhere (*Lift* stays for the override, which is
    a different mechanism). Also: a stale TalkBack hint naming a "pause" action that no longer
    exists, and duration chips announcing "5 min, **not selected**" for a one-shot picker.
14. **Not M8's, but in the same uncommitted diff:** `isImePackage` was resolved twice per
    `WINDOW_STATE_CHANGED` when a wall was up, 20 lines apart. One resolve now serves all three
    consumers.

Also fixed, pre-M8 and the highest-leverage find of the run: **onboarding's starter rule enforced
nothing.** `_limitEntry` dropped `platformIds`, and `_sum` meters packages — so the feed-only time
limit that four of six survey answers produce (**including "skip"**) could neither cover anything
nor ever become spent, and the editor blanked its platforms on any re-save. Such a limit now ships
`reelTimeLimitMs` + `platformIds`, the shape native already meters with Detoxo closed.
