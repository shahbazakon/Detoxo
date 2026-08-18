---
name: detoxo-auto-test
description: Run Detoxo's three-layer QA automation and report on it — static analysis + unit/widget tests, a real-boot end-to-end walk on an attached Android device with screenshots, and performance (cold start, frame timeline, memory, APK size) gated against a saved baseline. Use when asked to test, QA, verify, validate, benchmark, profile, smoke-test, check for regressions, measure startup or frame performance, screenshot the app, or judge production readiness. Triggers: "run the QA suite", "test everything", "is this ready to ship", "did I regress performance", "take screenshots of the app", "/detoxo-auto-test".
---

# detoxo-auto-test — prove it on real hardware

Everything runs through one driver, `tool/qa.sh`. Paths are relative to the repo root.

```bash
bash tool/qa.sh [-d <serial>] [--reset] [--baseline] \
  {functional|e2e|perf|blocking|all|prep|restore|devices}
```

Layer 1 needs no device. Layers 2–3 need an attached, **unlocked** Android phone. Artifacts land
in `build/qa/` (gitignored via `/build/`).

## When to run

| Situation | Command |
|---|---|
| Pre-commit / any Dart change | `bash tool/qa.sh functional` |
| Touched UI, routing, splash gating, a cubit | `+ e2e` |
| Touched startup, build config, deps, a hot path | `+ perf` |
| Touched native detection or the accessibility service | `+ blocking` |
| "Is it ready to ship" | `all`, then `blocking`, then `restore` |

`all` runs **`functional → e2e → perf`** cheapest-first, so a red Layer 1 surfaces in ~30s rather
than 17 minutes. Each device layer is self-contained — `perf` installs its own profile APK and
clears its own onboarding/permission gates — so they can be run individually, in any order. What
you must never do is read perf numbers off a debug install; `perf` prevents that by installing
profile itself.

## Preconditions

```bash
bash tool/qa.sh devices          # phone attached and authorised?
```

`adb` is resolved in order: `$ADB` → `PATH` → `$ANDROID_HOME` → `$ANDROID_SDK_ROOT` →
`~/Library/Android/sdk/platform-tools/adb`. On a stock macOS Flutter box adb is **not** on
`PATH` and both env vars are unset, so the last fallback is what actually resolves.

The phone must be **unlocked and stay unlocked**. `prep` sets `svc power stayon usb` for this
reason and `restore` puts it back — a perf run spends ~10 minutes in Gradle before it touches
the device, and if the phone locks in the meantime the manual overlay grant can't be given and
`am start` lands behind the keyguard.

## Layer 1 — functional (no device)

```bash
bash tool/qa.sh functional
```

Delegates to `bash tool/dev.sh precommit` (format → analyze → `flutter test` → `check_boundaries.sh`)
and tees to `build/qa/functional.log`, exit code to `build/qa/functional.rc`. It never fails the
driver, so a red Layer 1 still lets Layers 2–3 run and report.

Current green baseline: **188 tests**, analyzer clean, 12 known boundary violations from
`tool/boundaries_baseline.txt` and **0 new**.

## Layer 2 — real-boot E2E + screenshots

```bash
bash tool/qa.sh -d <serial> e2e
```

Boots the real `main()` on the device and walks: splash → onboarding → permissions → home →
showcase → drawer → Appearance (light ↔ dark) → Settings → Activity → home. Writes
`build/qa/e2e.status` (`pass`/`fail`), `build/qa/e2e.log`, and numbered PNGs in `build/qa/shots/`.

The walk **branches on whichever screen it lands on**, so it works on a fresh install and on a
phone that already holds real user data. It never taps *Reset app data*. It fails loudly (rather
than hanging) if an app-scope PIN is set, because it cannot type one.

**Look at the screenshots.** A green `e2e.status` with a blank or error-page PNG is not a pass.

### Screenshots are taken over adb, not by the binding

`flutter test` never surfaces `IntegrationTestWidgetsFlutterBinding.reportData` — that is only
readable through `driver.requestData` — so `binding.takeScreenshot` is unavailable here. Instead
the test `debugPrint`s `QA_SHOT:<name>` and holds the screen ~1.4s; `shots_pump()` in the driver
greps stdout for that marker and fires `adb exec-out screencap -p`. This captures the true device
framebuffer, including the native overlay bubble, which `convertFlutterSurfaceToImage()` would
render as a blank hole.

## Layer 3 — performance

```bash
bash tool/qa.sh -d <serial> --baseline perf   # adopt this run as the baseline (once)
bash tool/qa.sh -d <serial> perf              # gate against it
```

| Metric | Source | Runs |
|---|---|---|
| `cold_start_total_ms`, `cold_start_wait_ms` | `am force-stop` then `am start -W` | median of 3 |
| `time_to_first_frame[_rasterized]_ms`, `time_to_framework_init_ms` | `flutter run --profile --trace-startup` | median of 3 |
| `p90_frame_build_ms`, `p90_frame_raster_ms`, `missed_frame_*_budget_count` | `flutter drive` timeline summary | 1 (already p90 over the run) |
| `total_pss_kb` | `dumpsys meminfo`, 10s after a cold launch | 1 |
| `apk_size_bytes` | `flutter build apk --release` | 1 |

Everything measured is **profile**. Debug is JIT with assertions, no tree-shaking and a live
service-extension isolate: 3–10× frame build times, ~2× startup, and the ratio is not stable
across changes, so a debug "regression" can be a profile improvement. `apk_size_bytes` is the
exception and must be **release** — only that build type sets `isMinifyEnabled`/`isShrinkResources`.

`tool/qa_metrics.py` writes `build/qa/metrics.json`, and `baseline.json` under `--baseline`. A
gate trips only when a delta breaches **both** a percentage and an absolute floor (e.g. cold start
15% *and* 150ms; p90 frame 25% *and* 2.0ms; APK 3% *and* 500KB) — a pure-percent gate flaps on
small numbers, a pure-absolute one on large. No baseline yet → counted as PASS, annotated
*unbaselined*; say so in the report rather than implying it passed a comparison.

Re-run the parser without re-measuring — it only reads files already on disk, so this re-scores a
run without touching the phone:

```bash
QA_APK_BYTES=$(stat -f%z build/app/outputs/flutter-apk/app-release.apk) python3 tool/qa_metrics.py
```

**`total_pss_kb` is screen-dependent — re-baseline whenever the phase order changes.** `dumpsys
meminfo` measures whichever screen the app landed on, and that follows stored state: a fresh
install sits on `/onboarding`, an onboarded one builds the whole dashboard. Measuring it before
the drive made the number a function of install history rather than of the code — a baseline
captured on `/onboarding` scored the very next run on `/home` as **+28.9% memory**, from a
byte-identical APK (`apk_size_bytes` delta 0). The capture now happens **after** the drive, which
always leaves the app onboarded. A baseline taken before that change will fail memory forever;
delete it and re-adopt.

When a gate fails, check `apk_size_bytes` first. A zero delta there means the binary did not
change, so any "regression" is measurement conditions, not code.

## Layer 2b — engine smoke

```bash
bash tool/qa.sh -d <serial> blocking
```

Splits, and must be reported that way. The **automatable** half proves the OS is delivering events
(`dumpsys accessibility`) and that a target app exists. The **non-automatable** half needs a human
to open a reel and scroll — `monkey`/`input swipe` land on login walls, not reels — while the
driver watches `logcat -s DetoxoService:I` for 60s for the real
`blocked <platformId> in <pkg> via <mode>` line.

Outcomes: `blocked | inconclusive | skipped | unbound | notinstalled`. **`inconclusive` is never
scored as a pass.** The EventChannel is not usable as an out-of-process probe —
`ServiceEventBus.post` drops events when no engine is attached — so logcat is the only cross-process
signal.

`unbound` means **installed but the OS is not delivering events** — a real failure, and a hard gate.
`notinstalled` is a *precondition* failure and scores 0 without tripping that gate: `restore`
uninstalls the app, so running `blocking` last always hits it. **Run `blocking` before `restore`.**
A stale `blocking.status` is scored as if it were this run's — check its mtime against the other
artifacts before you trust it.

## Leave the phone as you found it

```bash
bash tool/qa.sh restore
```

Restores `enabled_accessibility_services` / `accessibility_enabled` from the snapshot in
`build/qa/adb_state.env` and clears `stayon`. The snapshot is taken **once** and kept; a second
`prep` will not overwrite it with values `prep` itself wrote. `--reset` (`pm clear`) is opt-in and
prompts, because it destroys real Hive / secure-storage / engine data.

## Gotchas

These all cost a run to find. None are guessable from the source.

- **`flutter test -d` UNINSTALLS the app when it finishes.** Every `e2e` run therefore ends with no
  package, no Hive data and `enabled_accessibility_services` back to `null` — which is why the walk
  must branch on the screen it lands on, and why `perf` re-runs `prep`.
- **Any package replace revokes the accessibility service**, and `flutter test -d` reinstalls
  immediately before running. `PermissionsCubit` only re-checks on `AppLifecycleState.resumed`,
  which never fires during an integration test, so losing that race strands the walk at the
  permission wall permanently. `regrant_loop` re-asserts the grant on a 1s loop for the duration.
- **`app.main()` breaks the test harness.** `FirebaseCrashReportingService.installGlobalHandlers()`
  replaces both `FlutterError.onError` and `PlatformDispatcher.instance.onError`, and the run dies
  on *"A test overrode FlutterError.onError…"* — masking the real failure. `bootApp()` in
  `integration_test/qa_walk.dart` captures and restores both. **Any** future test that boots the
  real app needs this.
- **`flutter drive` needs `--no-dds`.** `traceAction` → `enableTimeline` opens its own websocket to
  the VM Service and DDS holds that port, so the run dies with *"Bad state: Failed to connect to VM
  Service … Connection refused"* **after** the whole walk has already succeeded.
- **`flutter drive` needs `--keep-app-running`.** Its exit-time uninstall raced a spawning process
  and took the Android runtime down with it (`JNI FatalError: Failed to mount
  /data_mirror/data_de/null/0/<pkg>`), soft-rebooting the phone mid-suite.
- **Never `pumpAndSettle`.** `GlassScaffold`'s ambient background repeats forever, so it never
  converges. Use `settle()` (fixed frames) and `waitFor()` (polls real frames) from `qa_walk.dart`.
- **`find.text` matches the RENDERED string.** `SectionHeader` uppercases — it is `'THEME'`, never
  `'Theme'`. The bottom nav pill carries `Semantics(label:)` only, so `find.text('Dashboard')`
  finds nothing; the dashboard marker is `'Block All'`.
- **Widgets below a lazy sliver do not exist.** `Reset app data` sits at the bottom of Settings'
  `ListView(children:)` and is never built into the element tree, so `find.text` cannot see it
  without scrolling. Use `'PROTECTION'` at the top instead.
- **`DashboardTopBar` is the first child of the dashboard `ListView`** — the header scrolls away.
  After the showcase tour the drawer button sits above the viewport clip: `find.byIcon` matches it
  but `tap()` misses with *"would not hit test on the specified widget"*. `openDrawer()` snaps the
  list to 0 first, with `jumpTo` — a drag at the top fires the `RefreshIndicator`.
- **Exactly one `testWidgets` per file may boot.** `configureDependencies()` calls
  `registerSingleton` without `allowReassignment` and nothing calls `sl.reset()`, so a second
  `app.main()` in the same isolate throws *"already registered"*.
- **`am start -W` without `am force-stop` reports a warm relaunch** and `TotalTime` collapses to
  ~50ms. The first cold start after an install is also an ART-warmup outlier (measured 1445 / 931 /
  1088 ms) — hence median-of-3, not mean.
- **A flaky USB link looks exactly like a code failure.** On the test phone the link dropped four
  times mid-suite; `flutter drive` then dies inside `driver.requestData` with a VM Service stack
  trace that reads like a driver bug. The tell is `adb: device '<serial>' not found` further down
  the log. Re-run before debugging — and if `adb devices` is empty, reseat the cable rather than
  editing the harness.
- **`integration_test/` is outside `lib/`,** so `package:` imports cannot reach `qa_walk.dart` and
  `always_use_package_imports` forbids the relative one. Both test files carry a documented
  `// ignore:` — this is deliberate, two ignores beat two divergent copies of `bootApp`.

### OEM permission limits (realme / ColorOS, MIUI / HyperOS)

`appops set` fails with `SecurityException: uid 2000 does not have
android.permission.MANAGE_APP_OPS_MODES`, and `pm grant` with `GRANT_RUNTIME_PERMISSIONS`. There is
**no adb path to the overlay grant** on these devices — a human toggles *Display over other apps*
once. It survives `adb install -r` but **not** an uninstall, so expect one manual grant per
device-facing phase. `prep` opens the settings page and polls for 300s rather than aborting.

Two traps in reading it back: `appops get` reports the default for up to ~a minute after an
install while the package's op state loads (the poll absorbs this; it often clears itself), and a
bare `grep allow` also matches the `Default mode: allow` trailer printed when the app has no entry
— `overlay_ok()` anchors on `^SYSTEM_ALERT_WINDOW: allow`.

Accessibility is different: `settings put secure enabled_accessibility_services` works here, but
the value is a **`:`-separated list** — append, never clobber whatever else the owner relies on.

## Report format

Report all thirteen sections. Do not collapse them, and do not report a layer that did not run as
though it passed.

1. Summary of changes analysed
2. Architecture & code-quality assessment
3. Functional test results (Layer 1)
4. UI / E2E results + screenshot inventory (Layer 2)
5. Performance metrics vs baseline (Layer 3)
6. Engine smoke outcome (Layer 2b) — state `blocked` / `inconclusive` / `skipped` / `unbound` verbatim
7. Bugs found
8. Bugs auto-fixed, with root cause
9. Bugs needing a decision, with options
10. Optimisations applied
11. Remaining risks & technical debt
12. **Overall quality score (0–100)**
13. **Production readiness: Ready / Needs attention**

### The score is computed, not judged

Same artifacts in, same number out.

| Bucket | Pts | Source |
|---|---|---|
| Static analysis | 15 | `build/qa/functional.log` — 15 if analyzer clean, else 0 |
| Unit / widget | 20 | `20 × passed / total` from the `flutter test` summary |
| Boundaries | 10 | 10 if `check_boundaries.sh` reports 0 **new** violations |
| E2E walk | 25 | 25 if `build/qa/e2e.status` is `pass`, else 0 |
| Performance | 20 | `20 − 4 × failed_gates` (floor 0); unbaselined → 20, say so |
| Engine smoke | 10 | `blocked` 10 · `skipped` 5 · `inconclusive` 3 · `unbound` 0 · `notinstalled` 0 |

**A hard gate overrides the score.** Report **Needs attention** regardless of total on any of:
analyzer error or warning · any new boundary violation · `e2e.status == fail` ·
`blocking.status == unbound`. `notinstalled` scores 0 but is **not** a hard gate — it means the
layer never ran, not that the engine is broken.

## Never

- Never report a layer you did not run, or a screenshot you did not open.
- Never score `inconclusive` as a pass.
- Never add to `tool/boundaries_baseline.txt` — the file says burn it down. If a fix needs a new
  cross-feature import, find another way (see `_finish()` in `onboarding_screen.dart`, which routes
  through the splash instead).
- Never tap *Reset app data*, and never run `--reset` on a phone holding real user data without
  explicit confirmation.
- Never leave the device modified — finish with `bash tool/qa.sh restore`.
