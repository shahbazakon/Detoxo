#!/usr/bin/env bash
# Detoxo — Flutter workflow automation.
#
#   bash tool/dev.sh            # interactive menu
#   bash tool/dev.sh 7          # run entry 7 directly
#   bash tool/dev.sh validate   # …or by name (see MENU below)
set -euo pipefail
cd "$(dirname "$0")/.."

BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; RED=$'\033[31m'; OFF=$'\033[0m'

run() { printf '%s→ %s%s\n' "$DIM" "$*" "$OFF"; "$@"; }

# `dart format .` walks build/ios/SourcePackages, where the vendored Firebase
# example packages ship an analysis_options.yaml whose `include:` resolves
# outside the checkout — dart_style then aborts the whole run with
# PathNotFoundException. Format the source trees we actually own instead.
DART_SRC=(lib test integration_test test_driver)
fmt() { run dart format "${DART_SRC[@]}"; }
need() {
  command -v "$1" >/dev/null 2>&1 && return 0
  printf '%s%s not found.%s Install: %s\n' "$RED" "$1" "$OFF" "$2" >&2
  return 1
}

# name|label|function
MENU=(
  "fresh|Fresh Project (clean + get + build)|t_fresh"
  "gen|Regenerate Code|t_gen"
  "watch|Watch Generated Files|t_watch"
  "genclean|Clean Generated Files|t_genclean"
  "quality|Full Code Quality Check|t_quality"
  "precommit|Pre-Commit Check|t_precommit"
  "validate|Full Validation (pre-PR)|t_validate"
  "qa|QA Automation (needs a device)|t_qa"
  "deps|Dependency Refresh|t_deps"
  "reset|Complete Project Reset|t_reset"
  "firebase|Firebase Reconfigure|t_firebase"
  "assets|Asset Generation (FlutterGen)|t_assets"
  "icons|App Launcher Icons|t_icons"
  "adultlist|Compile 18+ blocklist asset (tool/web_blocker → android assets)|t_adultlist"
  "release|Build Signed Release Bundle (.aab)|t_release"
)

t_gen()      { run dart run build_runner build --delete-conflicting-outputs; }
t_watch()    { run dart run build_runner watch --delete-conflicting-outputs; }
t_genclean() { run dart run build_runner clean; }
t_fresh()    { run flutter clean; run flutter pub get; t_gen; }
t_quality()  { fmt; run dart fix --apply; run flutter analyze; }
t_precommit(){ fmt; run flutter analyze; run flutter test; run bash tool/check_boundaries.sh; }
t_validate() { t_fresh; fmt; run flutter analyze; run flutter test; run bash tool/check_boundaries.sh; }
# Three QA layers on a real device. `QA_ARGS` passes through to tool/qa.sh:
#   QA_ARGS='-d ABC123 perf' bash tool/dev.sh qa
# See .claude/skills/detoxo-auto-test/SKILL.md.
t_qa()       { run bash tool/qa.sh ${QA_ARGS:-all}; }
t_deps()     { run flutter pub upgrade; run flutter pub get; t_gen; run flutter analyze; }
t_reset()    { run flutter clean; run flutter pub cache repair; run flutter pub get; t_gen; }
t_firebase() { need flutterfire "dart pub global activate flutterfire_cli"; run flutterfire configure; run flutter clean; run flutter pub get; }
t_assets()   { need fluttergen "dart pub global activate flutter_gen (or brew install FlutterGen/tap/fluttergen)"; run fluttergen; run dart format lib/gen; }
t_icons()    { run dart run flutter_launcher_icons; }
# The 18+ web-blocklist source (tool/web_blocker/blocked_websites.json) compiles
# into the native asset the WebBlockEngine reads; test/adult_blocklist_test.dart
# fails when the two drift, so run this after every edit to the JSON.
t_adultlist(){ need python3 "brew install python"; run python3 tool/web_blocker/compile_adult_list.py; }

# Play upload artifact. --obfuscate needs --split-debug-info; without it the
# Dart frames in Crashlytics are unreadable. Upload BOTH symbol sets after:
#   * build/symbols/            -> `flutter symbols upload` (Dart)
#   * build/app/outputs/mapping/release/mapping.txt -> Play Console (R8/Kotlin)
# See docs/code_docs/22-play-release.md.
t_release()  {
  [ -f android/key.properties ] || {
    printf '%sandroid/key.properties missing — the bundle would be debug-signed and rejected.%s\n' "$RED" "$OFF" >&2
    return 1
  }
  run flutter clean
  run flutter pub get
  t_gen
  run flutter build appbundle --release \
    --obfuscate --split-debug-info=build/symbols
  printf '\n%sBundle:%s build/app/outputs/bundle/release/app-release.aab\n' "$BOLD" "$OFF"
  printf '%sMapping:%s build/app/outputs/mapping/release/mapping.txt\n' "$BOLD" "$OFF"
  printf '%sSymbols:%s build/symbols/\n' "$BOLD" "$OFF"
}

dispatch() {
  local sel="$1" i=0 name label fn
  for entry in "${MENU[@]}"; do
    i=$((i + 1))
    IFS='|' read -r name label fn <<<"$entry"
    if [[ "$sel" == "$i" || "$sel" == "$name" ]]; then
      printf '\n%s== %s ==%s\n' "$BOLD" "$label" "$OFF"
      "$fn"
      printf '%s✔ done%s\n' "$GREEN" "$OFF"
      return 0
    fi
  done
  printf '%sUnknown option: %s%s\n' "$RED" "$sel" "$OFF" >&2
  return 1
}

menu() {
  local i=0 name label fn
  printf '\n%s===================================%s\n' "$BOLD" "$OFF"
  printf '%s Detoxo — Flutter Workflow%s\n' "$BOLD" "$OFF"
  printf '%s===================================%s\n' "$BOLD" "$OFF"
  for entry in "${MENU[@]}"; do
    i=$((i + 1))
    IFS='|' read -r name label fn <<<"$entry"
    printf '%2d. %-38s %s%s%s\n' "$i" "$label" "$DIM" "$name" "$OFF"
  done
  printf '%2d. Exit\n\n' $((i + 1))
  # printf + bare `read`: `read -p` means "coprocess" in zsh, so this stays
  # runnable under `zsh tool/dev.sh` as well as bash.
  printf 'Choose: '
  read -r sel || exit 0
  [[ "$sel" == "$((i + 1))" || "$sel" == "exit" || -z "$sel" ]] && exit 0
  dispatch "$sel" || true
}

if [[ $# -gt 0 ]]; then
  dispatch "$1"
else
  while true; do menu; done
fi
