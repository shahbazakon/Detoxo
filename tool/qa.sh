#!/usr/bin/env bash
# Detoxo — QA automation driver (three layers, one entry point).
#
#   bash tool/qa.sh functional          # format + analyze + unit tests + boundaries (no device)
#   bash tool/qa.sh e2e                 # real-boot walk on a device + screenshots
#   bash tool/qa.sh perf                # cold start + frame timeline + memory + apk size
#   bash tool/qa.sh blocking            # accessibility-engine smoke (half manual — see SKILL.md)
#   bash tool/qa.sh blockers            # App/Web Blocker walk + real block probes (needs YouTube + Chrome)
#   bash tool/qa.sh all                 # functional -> e2e -> perf  (this order is load-bearing)
#   bash tool/qa.sh devices             # list attached devices
#   bash tool/qa.sh prep | restore      # grant / put back accessibility + overlay
#
# Options, BEFORE the subcommand:
#   -d <serial>   target device (required when more than one is attached)
#   --reset       `pm clear` first — DESTROYS REAL APP DATA, prompts unless QA_YES=1
#   --baseline    write build/qa/baseline.json instead of gating against it
#
# Artifacts land in build/qa/ (already gitignored via /build/).
# Everything device-facing is documented in .claude/skills/detoxo-auto-test/SKILL.md.
set -euo pipefail
cd "$(dirname "$0")/.."

BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'
YELLOW=$'\033[33m'; RED=$'\033[31m'; OFF=$'\033[0m'

run()  { printf '%s→ %s%s\n' "$DIM" "$*" "$OFF"; "$@"; }
ok()   { printf '%s✔ %s%s\n' "$GREEN"  "$*" "$OFF"; }
warn() { printf '%s⚠ %s%s\n' "$YELLOW" "$*" "$OFF" >&2; }
die()  { printf '%s✗ %s%s\n' "$RED"    "$*" "$OFF" >&2; exit 1; }
need() {
  command -v "$1" >/dev/null 2>&1 && return 0
  printf '%s%s not found.%s Install: %s\n' "$RED" "$1" "$OFF" "$2" >&2
  return 1
}

PKG='com.errorxperts.detoxo'
ACT="$PKG/.MainActivity"
A11Y="$PKG/$PKG.accessibility.DetoxoAccessibilityService"
OUT='build/qa'
STATE="$OUT/adb_state.env"

SERIAL="${QA_SERIAL:-}"
RESET=0
BASELINE=0

# ── adb + device resolution ─────────────────────────────────────────────────

# adb is NOT on PATH on a stock macOS Flutter box, and ANDROID_HOME is usually
# unset — the SDK-relative fallbacks are what actually resolve in practice.
resolve_adb() {
  local c
  for c in "${ADB:-}" \
           "$(command -v adb 2>/dev/null || true)" \
           "${ANDROID_HOME:-/nonexistent}/platform-tools/adb" \
           "${ANDROID_SDK_ROOT:-/nonexistent}/platform-tools/adb" \
           "$HOME/Library/Android/sdk/platform-tools/adb"; do
    if [ -n "$c" ] && [ -x "$c" ]; then ADB="$c"; return 0; fi
  done
  die "adb not found. Set ADB=/path/to/adb, or install Android platform-tools."
}

resolve_device() {
  local ready bad n
  ready=$("$ADB" devices | awk 'NR>1 && $2 == "device"    { print $1 }' | tr -d '\r')
  bad=$(  "$ADB" devices | awk 'NR>1 && $2 ~ /unauthorized|offline/ { print $1" ("$2")" }' | tr -d '\r')

  if [ -n "$SERIAL" ]; then
    printf '%s\n' "$ready" | grep -qx "$SERIAL" \
      || die "device '$SERIAL' is not connected/authorised. Ready: ${ready:-none}"
    return 0
  fi

  n=$(printf '%s' "$ready" | grep -c . || true)
  [ "$n" -gt 1 ] && die "$n devices attached — pass -d <serial>:
$ready"
  if [ "$n" -eq 0 ]; then
    [ -n "$bad" ] && die "device attached but not usable: $bad
     Unlock the phone and accept the 'Allow USB debugging' RSA prompt."
    die "no adb device.
     Plug the phone in over USB, enable Developer options ▸ USB debugging,
     then accept the RSA prompt. Verify with: bash tool/qa.sh devices"
  fi
  SERIAL="$ready"
}

adb_() { "$ADB" -s "$SERIAL" "$@"; }
sh_()  { adb_ shell "$@" | tr -d '\r'; }

banner() {
  printf '%sdevice%s %s  (%s %s, API %s)\n' "$BOLD" "$OFF" "$SERIAL" \
    "$(sh_ getprop ro.product.manufacturer)" \
    "$(sh_ getprop ro.product.model)" \
    "$(sh_ getprop ro.build.version.sdk)"
}

# ── permission prep / restore ───────────────────────────────────────────────

t_prep() {
  mkdir -p "$OUT"

  if [ "$RESET" -eq 1 ]; then
    warn "--reset runs 'pm clear $PKG'. That wipes Hive (detoxo.hive),
     detoxo_engine_prefs, flutter_secure_storage and every app-op for the app.
     Any REAL Detoxo data on this phone is destroyed and cannot be recovered."
    if [ "${QA_YES:-0}" != '1' ]; then
      printf 'Type %sYES%s to continue: ' "$BOLD" "$OFF"
      local reply; read -r reply || true
      [ "$reply" = 'YES' ] || die 'aborted — nothing was cleared'
    fi
    run adb_ shell pm clear "$PKG"
  fi

  # Snapshot AFTER pm clear: clearing resets app-ops, so a pre-clear snapshot
  # would describe a state that no longer exists.
  local prev_svc prev_en next
  prev_svc=$(sh_ settings get secure enabled_accessibility_services)
  prev_en=$(sh_ settings get secure accessibility_enabled)
  # Snapshot ONCE. A second `prep` would otherwise capture our own edits as the
  # "original", and `restore` would put those back instead of the user's state.
  if [ -f "$STATE" ]; then
    printf '%skeeping the existing snapshot in %s%s\n' "$DIM" "$STATE" "$OFF"
  else
    printf 'PREV_SVC=%q\nPREV_EN=%q\n' "$prev_svc" "$prev_en" > "$STATE"
  fi

  run ensure_a11y

  # SYSTEM_ALERT_WINDOW + Android 13+ ECM ("restricted settings", which blocks
  # the Settings-UI toggle for sideloaded apps). Both are best-effort: on stock
  # Android `adb shell` holds MANAGE_APP_OPS_MODES and these succeed, but some
  # OEMs refuse — see the overlay fallback below. Never fatal.
  adb_ shell appops set "$PKG" SYSTEM_ALERT_WINDOW allow 2>/dev/null || true
  adb_ shell appops set "$PKG" ACCESS_RESTRICTED_SETTINGS allow 2>/dev/null || true

  sleep 2  # AccessibilityManagerService binds asynchronously

  case ":$(sh_ settings get secure enabled_accessibility_services):" in
    *":$A11Y:"*) ok 'accessibility service enabled' ;;
    *) manual_grant ;;
  esac

  # There is NO adb path to the overlay grant on realme/ColorOS (verified on
  # RMX3997, Android 16): `appops set` fails with "uid 2000 does not have
  # android.permission.MANAGE_APP_OPS_MODES" and `pm grant` with "Neither user
  # 2000 nor current process has android.permission.GRANT_RUNTIME_PERMISSIONS".
  # A human has to toggle it once. It then survives even an uninstall (ColorOS
  # remembers the op by package name), but `appops get` reports the default for
  # up to ~a minute after a reinstall while the package's op state loads — so
  # this poll is normal on a re-run and usually clears itself with nobody
  # touching the phone. Wait rather than aborting the pipeline.
  if ! overlay_ok; then
    warn 'overlay (Display over other apps) is not granted, and this device
     refuses the adb grant. Opening the settings page — toggle Detoxo ON.
     Expect this after an e2e run: `flutter test -d` UNINSTALLS the app when it
     finishes, and an uninstall drops the app-op for good. `adb install -r` over
     a surviving install keeps it, a fresh install does not.'
    adb_ shell am start -a android.settings.action.MANAGE_OVERLAY_PERMISSION \
      -d "package:$PKG" >/dev/null 2>&1 || true
    printf 'waiting up to 300s for the toggle'
    local i
    for i in $(seq 60); do
      sleep 5
      overlay_ok && break
      printf '.'
    done
    printf '\n'
    overlay_ok || die 'overlay still not granted — grant it, then re-run'
  fi
  ok 'overlay (SYSTEM_ALERT_WINDOW) allowed'

  # Keep the screen awake while plugged in. A perf run is ~10 minutes of Gradle
  # before it ever touches the device; if the phone locks in the meantime the
  # manual overlay grant cannot be given, `am start` lands behind the keyguard,
  # and the run dies at the permission wall. `restore` puts this back.
  adb_ shell svc power stayon usb 2>/dev/null || true

  # Keep QA traffic out of production Firebase (routes to DebugView instead).
  adb_ shell setprop debug.firebase.analytics.app "$PKG" 2>/dev/null || true
}

# Anchored on the op line. A bare `grep allow` also matches the "Default mode:
# allow" trailer that `appops get` prints when the app has no explicit entry
# ("No operations."), which would report an ungranted app as granted.
overlay_ok() {
  sh_ appops get "$PKG" SYSTEM_ALERT_WINDOW | grep -qE '^SYSTEM_ALERT_WINDOW: allow'
}

# Idempotent accessibility grant. enabled_accessibility_services is a
# ':'-separated LIST — append, never clobber whatever the owner relies on.
ensure_a11y() {
  local cur next
  cur=$(sh_ settings get secure enabled_accessibility_services)
  case ":$cur:" in *":$A11Y:"*) return 0 ;; esac
  if [ -z "$cur" ] || [ "$cur" = 'null' ]; then next="$A11Y"; else next="$cur:$A11Y"; fi
  adb_ shell settings put secure enabled_accessibility_services "$next" >/dev/null 2>&1 || true
  adb_ shell settings put secure accessibility_enabled 1 >/dev/null 2>&1 || true
}

# Android REVOKES an accessibility service whenever its package is replaced —
# and `flutter test -d` reinstalls the APK immediately before running it, which
# destroys the grant `prep` just made. Re-assert it on a 1s loop for the
# duration of the run so it is back in place well before SplashScreen._bootstrap
# calls permissions.refresh(). (PermissionsCubit only re-checks on
# AppLifecycleState.resumed, which never fires during an integration test, so
# losing that race means the walk is stuck at the wall for good.)
regrant_loop() {
  local deadline=$((SECONDS + ${1:-300}))
  while [ "$SECONDS" -lt "$deadline" ]; do ensure_a11y; sleep 1; done
}

manual_grant() {
  warn "shell could not write secure settings.
     com.android.shell holds WRITE_SECURE_SETTINGS on stock Android, but
     MIUI / HyperOS / ColorOS gate it behind Developer options ▸ 'USB debugging
     (Security settings)', which needs a vendor account. Grant it by hand:"
  printf '       Settings ▸ Accessibility ▸ Detoxo Blocker ▸ On\n'
  printf '       (Android 13+ sideload: ⋮ ▸ "Allow restricted settings" first)\n'
  run adb_ shell am start -a android.settings.ACCESSIBILITY_SETTINGS
  die 'accessibility not enabled — re-run once granted'
}

t_restore() {
  [ -f "$STATE" ] || die "no $STATE — nothing to restore"
  # shellcheck disable=SC1090
  . "$STATE"
  if [ -z "${PREV_SVC:-}" ] || [ "$PREV_SVC" = 'null' ]; then
    run adb_ shell settings delete secure enabled_accessibility_services
  else
    run adb_ shell settings put secure enabled_accessibility_services "$PREV_SVC"
  fi
  if [ -z "${PREV_EN:-}" ] || [ "$PREV_EN" = 'null' ]; then
    run adb_ shell settings delete secure accessibility_enabled
  else
    run adb_ shell settings put secure accessibility_enabled "$PREV_EN"
  fi
  adb_ shell svc power stayon false 2>/dev/null || true
  adb_ shell setprop debug.firebase.analytics.app '.none.' 2>/dev/null || true
  rm -f "$STATE"
  ok 'device accessibility settings restored'
}

# ── Layer 1: static + unit. Delegates — precommit already IS this gate. ─────

t_functional() {
  mkdir -p "$OUT"
  local rc=0
  bash tool/dev.sh precommit 2>&1 | tee "$OUT/functional.log" || rc=$?
  printf '%s\n' "$rc" > "$OUT/functional.rc"
  if [ "$rc" -eq 0 ]; then ok 'functional gate passed'; else warn 'functional gate FAILED'; fi
  return 0
}

# ── Layer 2: real-boot E2E + screenshots ───────────────────────────────────

# The walk debugPrints `QA_SHOT:<name>` then holds the screen ~1.4s; grab the
# device framebuffer when the marker appears. `flutter test` never surfaces
# IntegrationTestWidgetsFlutterBinding.reportData, so binding.takeScreenshot
# is not an option here — see SKILL.md.
shots_pump() {
  local i=0 line name dir="${SHOTS:-$OUT/shots}"
  while IFS= read -r line; do
    printf '%s\n' "$line"
    case "$line" in
      *QA_SHOT:*)
        name=${line#*QA_SHOT:}
        name=${name%%[[:space:]]*}
        i=$((i + 1))
        adb_ exec-out screencap -p > "$dir/$(printf '%02d' "$i")-$name.png"
        ;;
      # The blocker walk hands the phone to a probe_<name> function below.
      *QA_PROBE:*)
        name=${line#*QA_PROBE:}
        name=${name%%[[:space:]]*}
        "probe_${name//-/_}"
        ;;
    esac
  done
}

t_e2e() {
  mkdir -p "$OUT/shots"
  rm -f "$OUT/shots"/*.png
  # The package must EXIST before appops/accessibility can be granted against
  # it, and `flutter test -d` only installs once it starts — so install first.
  # The later `flutter test` reinstalls over this with `install -r`, which
  # preserves app-ops and the accessibility grant.
  if ! sh_ pm list packages "$PKG" | grep -q "package:$PKG"; then
    run flutter install --debug -d "$SERIAL"
  fi
  t_prep

  # Survives the reinstall `flutter test` is about to do — see regrant_loop.
  regrant_loop & local rg=$!
  # shellcheck disable=SC2064
  trap "kill $rg 2>/dev/null || true" RETURN

  if flutter test -d "$SERIAL" --reporter expanded \
       integration_test/app_e2e_test.dart 2>&1 \
       | tee "$OUT/e2e.log" | shots_pump; then
    printf 'pass\n' > "$OUT/e2e.status"; ok 'e2e passed'
  else
    printf 'fail\n' > "$OUT/e2e.status"; warn 'e2e FAILED'
  fi
  kill "$rg" 2>/dev/null || true
  printf 'screenshots: %s\n' "$OUT/shots"
  return 0
}

# ── Layer 2c: blocker walk + engine probes ─────────────────────────────────
# integration_test/blockers_e2e_test.dart drives the App Blocker and Web
# Blocker screens like a user (add YouTube as a whole-app lock, add example.com,
# pause it), printing `QA_PROBE:<name>` and sleeping ~40s at each hand-off.
# shots_pump routes the marker to probe_<name>: launch the target, watch the
# engine log for the block line, record the verdict, bring Detoxo back so the
# walk's next pump gets a frame. Verdicts land in build/qa/blockers.status as
# `<name> blocked|notblocked` (block expected) or `<name> allowed|leaked`
# (pause expected to let it through). The walk's own pass/fail is
# build/qa/blockers.walk.

probe_run() {  # <name> <block|noblock> <logcat regex> <watch secs> <adb shell launch args…>
  local name=$1 expect=$2 pattern=$3 secs=$4; shift 4
  local log="$OUT/blockers.$name.logcat" deadline=$((SECONDS + secs)) hit=0 verdict
  adb_ logcat -c 2>/dev/null || true
  adb_ shell "$@" >/dev/null 2>&1 || true
  while [ "$SECONDS" -lt "$deadline" ]; do
    sleep 1
    adb_ logcat -d -s DetoxoService:I > "$log" 2>/dev/null || true
    if grep -qE "$pattern" "$log"; then hit=1; [ "$expect" = block ] && break; fi
  done
  if [ "$expect" = block ]; then
    if [ "$hit" -eq 1 ]; then verdict=blocked; else verdict=notblocked; fi
  else
    if [ "$hit" -eq 1 ]; then verdict=leaked; else verdict=allowed; fi
  fi
  printf '%s %s\n' "$name" "$verdict" >> "$OUT/blockers.status"
  printf '%sprobe %s: %s%s\n' "$BOLD" "$name" "$verdict" "$OFF"
  # Bring Detoxo back so the walk's next pump gets a frame. Verified, not
  # fire-and-forget: the engine's HOME bounce is still animating when the first
  # `am start` lands, and the launcher can win that race — the walk then sleeps
  # forever on a backgrounded app (cost a run to find).
  local i
  for i in 1 2 3 4 5; do
    adb_ shell am start -n "$ACT" >/dev/null 2>&1 || true
    sleep 2
    sh_ dumpsys activity activities | grep -q "topResumedActivity=.*$PKG" && return 0
  done
  warn "could not bring $PKG back to the foreground after probe $name"
}
probe_app() {
  probe_run app block 'blocked app_block in com.google.android.youtube via HOME' 20 \
    am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER com.google.android.youtube
}
probe_web() {
  probe_run web block 'web-blocked in com.android.chrome' 20 \
    am start -a android.intent.action.VIEW -d https://example.com/ com.android.chrome
}
probe_web_paused() {
  probe_run web-paused noblock 'web-blocked in com.android.chrome' 12 \
    am start -a android.intent.action.VIEW -d https://example.com/ com.android.chrome
}

t_blockers() {
  local shots="$OUT/shots-blockers" p
  mkdir -p "$shots"
  rm -f "$shots"/*.png "$OUT"/blockers.*
  : > "$OUT/blockers.status"
  # Preconditions, not verdicts: a probe against a missing target proves nothing.
  for p in com.google.android.youtube com.android.chrome; do
    sh_ pm list packages "$p" | grep -q "package:$p" \
      || die "$p is not installed — the blocker probes need it"
  done
  if ! sh_ pm list packages "$PKG" | grep -q "package:$PKG"; then
    run flutter install --debug -d "$SERIAL"
  fi
  t_prep
  regrant_loop & local rg=$!
  # shellcheck disable=SC2064
  trap "kill $rg 2>/dev/null || true" RETURN

  if flutter test -d "$SERIAL" --reporter expanded \
       integration_test/blockers_e2e_test.dart 2>&1 \
       | tee "$OUT/blockers.log" | SHOTS="$shots" shots_pump; then
    printf 'pass\n' > "$OUT/blockers.walk"; ok 'blocker walk passed'
  else
    printf 'fail\n' > "$OUT/blockers.walk"; warn 'blocker walk FAILED'
  fi
  kill "$rg" 2>/dev/null || true
  printf 'probes:\n'; cat "$OUT/blockers.status"
  printf 'screenshots: %s\n' "$shots"
  return 0
}

# ── Layer 3: performance ───────────────────────────────────────────────────

t_perf() {
  mkdir -p "$OUT"
  : > "$OUT/coldstart.txt"

  # apk size must come from RELEASE — it is the only build type that sets
  # isMinifyEnabled / isShrinkResources, so debug/profile sizes are fiction.
  run flutter build apk --release --target-platform android-arm64
  local apk='build/app/outputs/flutter-apk/app-release.apk' apk_bytes
  apk_bytes=$(stat -f%z "$apk" 2>/dev/null || stat -c%s "$apk")

  # Everything below is PROFILE. Debug is JIT with assertions, no tree-shaking
  # and a live service-extension isolate: 3-10x frame build times, ~2x startup,
  # and the ratio is not stable across changes.
  run flutter build apk --profile --target-platform android-arm64
  run adb_ install -r -d build/app/outputs/flutter-apk/app-profile.apk

  # app_perf_test.dart needs to reach /home, which means clearing the permission
  # wall. Every step below reinstalls the package (adb install, flutter run,
  # flutter drive) and every install REVOKES the accessibility service, so the
  # re-grant loop has to cover the whole phase, not just one command.
  t_prep
  regrant_loop 3600 & local rg=$!
  # shellcheck disable=SC2064
  trap "kill $rg 2>/dev/null || true" RETURN

  # Cold start x3. force-stop is mandatory — without it `am start -W` reports a
  # warm relaunch and TotalTime collapses to ~50ms.
  local n
  for n in 1 2 3; do
    adb_ shell am force-stop "$PKG"
    sleep 2
    adb_ shell am start -W -n "$ACT" | tr -d '\r' | tee -a "$OUT/coldstart.txt"
    sleep 3
  done
  adb_ shell am force-stop "$PKG"

  # Dart/engine startup x3. --trace-startup forces a cold run and exits on its
  # own once build/start_up_info.json is written.
  for n in 1 2 3; do
    run flutter run --profile --trace-startup --no-pub -d "$SERIAL"
    cp build/start_up_info.json "$OUT/start_up_info.$n.json"
  done

  # Frame timeline. MUST be `flutter drive`: reportData is only readable via
  # driver.requestData, which `flutter test` never calls.
  #
  # --no-dds is REQUIRED, not optional. IntegrationTestWidgetsFlutterBinding
  # .traceAction -> enableTimeline opens its OWN websocket to the VM Service, and
  # the Dart Development Service sits on that port instead, so every run dies
  # with "Bad state: Failed to connect to VM Service ... Connection refused"
  # inside traceAction — after the whole walk has already succeeded.
  # --keep-app-running stops `flutter drive` UNINSTALLING the app on the way out.
  # The uninstall is not merely inconvenient: it raced a spawning process on the
  # test device and took the Android runtime down with it —
  #   JNI FatalError: Failed to mount /data_mirror/data_de/null/0/<pkg> ...
  # — soft-rebooting the phone mid-suite. It also drops the SYSTEM_ALERT_WINDOW
  # app-op, which on this OEM only a human can restore (see t_prep).
  run flutter drive --profile --no-pub --no-dds --keep-app-running -d "$SERIAL" \
    --driver test_driver/perf_driver.dart \
    --target integration_test/app_perf_test.dart

  # Memory 10s after a cold launch — AFTER the drive, deliberately.
  #
  # `dumpsys meminfo` measures whatever screen the app happens to land on, and
  # that depends on stored state: a fresh install sits on /onboarding, an
  # onboarded one builds the whole dashboard (hero, mode selector, blocker
  # cards, ambient background). Measuring before the drive made the number a
  # function of install history rather than of the code — the baseline was
  # captured on /onboarding and the very next run on /home, a +28.9% "regression"
  # from a byte-identical APK. The drive always leaves the app onboarded, so
  # taking the reading here pins the screen and makes runs comparable.
  adb_ shell am force-stop "$PKG"
  adb_ shell am start -W -n "$ACT" > /dev/null
  sleep 10
  sh_ dumpsys meminfo "$PKG" > "$OUT/meminfo.txt"
  adb_ shell am force-stop "$PKG"

  kill "$rg" 2>/dev/null || true
  QA_APK_BYTES="$apk_bytes" QA_BASELINE="$BASELINE" python3 tool/qa_metrics.py
}

# ── Layer 2b: engine smoke. Half automatable, half not — see SKILL.md. ─────

t_blocking() {
  mkdir -p "$OUT"
  local targets='com.instagram.android com.google.android.youtube com.facebook.katana
                 com.snapchat.android com.zhiliaoapp.musically'
  local found=0 p

  # "App not installed" is a PRECONDITION failure, not a verdict. Without this
  # check it falls through to `unbound` — which is a hard NOT-READY gate — so a
  # `blocking` run after `restore` (which uninstalls) would poison the report
  # with a failure caused by nothing. Distinct status, scored separately.
  if ! sh_ pm list packages "$PKG" | grep -q "package:$PKG"; then
    warn "$PKG is not installed — run e2e or perf first (precondition, not a verdict)"
    printf 'notinstalled\n' > "$OUT/blocking.status"
    return 0
  fi

  # Deterministic half: is the OS actually delivering events to our service?
  if sh_ dumpsys accessibility | grep -q "$PKG"; then
    ok 'DetoxoAccessibilityService is bound'
  else
    warn 'DetoxoAccessibilityService is NOT bound'
    printf 'unbound\n' > "$OUT/blocking.status"
    return 0
  fi

  for p in $targets; do
    if sh_ pm list packages "$p" | grep -q "package:$p"; then
      printf '  target installed: %s\n' "$p"; found=1
    fi
  done
  if [ "$found" -eq 0 ]; then
    warn 'no short-form target app installed — real-block check SKIPPED (not passed)'
    printf 'skipped\n' > "$OUT/blocking.status"
    return 0
  fi

  # Non-automatable half: reaching a reel needs a logged-in account and a real
  # scroll inside a third-party UI that changes weekly. monkey/input swipe land
  # on login walls, not reels. So the human scrolls and we watch. No fake pass.
  adb_ logcat -c
  printf '%sOpen a reel/short in one of the apps above and scroll. Watching 60s…%s\n' "$BOLD" "$OFF"
  adb_ logcat -s DetoxoService:I > "$OUT/blocking.logcat" &
  local lp=$!
  sleep 60
  kill "$lp" 2>/dev/null || true

  if grep -qE 'blocked .* in .* via ' "$OUT/blocking.logcat"; then
    ok 'engine blocked a real reel'
    printf 'blocked\n' > "$OUT/blocking.status"
  else
    warn 'no block observed — INCONCLUSIVE (never score this as a pass)'
    printf 'inconclusive\n' > "$OUT/blocking.status"
  fi
  return 0
}

# ── dispatch ───────────────────────────────────────────────────────────────

t_devices() { "$ADB" devices -l; }
t_all()     { t_functional; t_e2e; t_perf; }

while [ $# -gt 0 ]; do
  case "$1" in
    -d)         SERIAL="${2:-}"; [ -n "$SERIAL" ] || die '-d needs a serial'; shift 2 ;;
    --reset)    RESET=1; shift ;;
    --baseline) BASELINE=1; shift ;;
    -*)         die "unknown option: $1" ;;
    *)          break ;;
  esac
done

CMD="${1:-}"
case "$CMD" in
  functional|e2e|perf|blocking|blockers|all|prep|restore|devices) ;;
  *) die "usage: bash tool/qa.sh [-d <serial>] [--reset] [--baseline]
       {functional|e2e|perf|blocking|blockers|all|prep|restore|devices}" ;;
esac

need flutter 'https://docs.flutter.dev/get-started/install' || exit 1
mkdir -p "$OUT"

# `functional` is pure host-side work — do not demand a phone for it.
if [ "$CMD" != 'functional' ]; then
  resolve_adb
  if [ "$CMD" = 'devices' ]; then t_devices; exit 0; fi
  need python3 'ships with macOS' || exit 1
  resolve_device
  banner
fi

"t_$CMD"
