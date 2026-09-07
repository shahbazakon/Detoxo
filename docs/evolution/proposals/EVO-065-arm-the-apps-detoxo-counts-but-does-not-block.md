# EVO-065 — Name the apps Detoxo counts but is not blocking, and arm them from the Reels list

- Status: approved
- Tier: 2 (enhancement) — requires explicit per-proposal approval
- Feature: `lib/features/analytics` (presentation), reading `TargetsCubit` and `SettingsCubit` through the `blocking` barrel
- Commit: 185c7f7 (working tree uncommitted — the 2026-09-07 restyle and the 2026-09-08 Tier-1 batch are not yet committed)
- Date: 2026-09-08
- Effort: S

## Why
The Reels segment is built purely from the counter's per-app list —
`lib/features/analytics/presentation/widgets/by_app_section.dart:62-74`:
```dart
    final raw = switch (segment) {
      // The counter documents its lists as sorted by count, descending.
      ByAppSegment.reels => [
        for (final a in count.perAppToday)
          (
            package: a.packageName,
            name: a.displayName,
            iconUrl: a.iconUrl,
            weight: a.count,
            trailing: '${a.count}',
            spoken: a.count == 1 ? '1 reel' : '${a.count} reels',
          ),
      ],
```
and nothing in `rowsFor` or the row consults `AppSettings.enabledPlatformIds`
(`lib/features/blocking/shared/domain/entities/app_settings.dart:21`) or `TargetsCubit`. Native
counts *above* the block gate
(`android/app/src/main/kotlin/com/errorxperts/detoxo/accessibility/DetoxoAccessibilityService.kt:582-585`,
"Awareness counting: runs independent of blocking (master-off / paused / platform-disabled)"),
while the block pass skips a platform the user turned off, `:761-764`:
```kotlin
                // Respect user enable/disable; fall back to defaultStatus if unset.
                val isOn = if (enabled.isEmpty()) platform.defaultStatus
                else enabled.contains(platform.platformId)
                if (!isOn) continue
```
So a row reading "Snapchat 63" can mean "Detoxo watched 63 reels go by and was never allowed to
act", and the only action the row offers is a daily time limit
(`lib/features/analytics/presentation/widgets/app_limit_row.dart:66-81`). Distinct from EVO-063
(the whole service stopped, Blocks segment) and EVO-022 (counting switched off): this is per-app
coverage with the service running.

## Expected user impact
The one screen that can prove the interception loop never started says so: a row whose platform is
off carries a muted **Not blocked** marker, and one line under the panel names them — "Detoxo
counted these but isn't blocking Snapchat and TikTok" — with a single **Turn on** action that arms
them for the very next scroll. The setup-time blocklist decision ("Getting started", step 3)
becomes revisable at the moment the evidence is on screen, instead of a number the user misreads
as "Detoxo is on it". Directly serves the intervention loop: it converts evidence into coverage.

## Technical complexity
Dart only, presentation. Reads `TargetsCubit` (`lib/features/blocking/blocking.dart:17`; state
`TargetsState(targets: List<BlockTarget>)`, `BlockTarget(platformId, packageName, …,
defaultEnabled)`) and `SettingsCubit` (`blocking.dart:33`; `Cubit<AppSettings>`), both app-wide
(`main.dart:92-102`), so no new boundary entry. The "is it on" predicate must mirror the native
rule at `DetoxoAccessibilityService.kt:762` exactly — an **empty** `enabledPlatformIds` means
"every platform at its `defaultEnabled`" — so it lives in one pure `@visibleForTesting` static
beside `ByAppSection.rowsFor` with a test; a second, drifting definition would make the screen lie.
The action is one `SettingsCubit.setEnabledPlatforms(effective ∪ off)`
(`lib/features/blocking/shared/presentation/settings_cubit.dart:166`), the existing commit + native
push path — **the union must start from the effective set, never from the raw (possibly empty)
stored set**, or the first write would switch every default-on platform off. With
`masterEnabled == false` or a live `pauseSession` (`app_settings.dart:23-24`) a per-app toggle
changes nothing, so the line states that instead and offers nothing (the Dashboard owns those
toggles). No new channel method, payload key, `StoreKey`, route or permission.

## Performance impact
`rowsFor` stays pure; the added work is one set lookup per visible row — the Reels segment shows a
handful of apps against ~10 catalog targets — inside a build that already does
`context.watch<ContentCounterCubit>()` and `context.watch<InsightsCubit>()`
(`by_app_section.dart:149-151`). The new subscription is one `context.select` on
`enabledPlatformIds` (an Equatable-compared set that changes only on a user action) and one on
`TargetsState.targets` (loaded once at boot), so nothing rebuilds on the counter's live ticks. No
channel call is added and nothing touches the accessibility service, so the 150 ms throttle and
`maxNodeTraversal 12000` budgets are untouched.

## Business value
`docs/info_docs/01-product-overview.md` § "Why Detoxo is different" ("Steps in **while** you're
scrolling") is the whole promise, and § "Getting started" step 3 makes coverage a one-time setup
choice nobody revisits; § "On-device Reel Counter" states the counter "keeps tallying even when
blocking is turned off or paused", which is precisely the ambiguity this row ships today. Closing
it converts the app's own evidence into detection coverage — the loop's first mile — rather than
another honest number.

## Rejected alternative
A per-row **Turn on** control on `AppLimitRow`, toggling that one platform in place with an undo.
Rejected: it puts a second tap target inside a 48 dp row whose tap EVO-033 (and approved EVO-061)
already own, so TalkBack reads two actions per row against the one-labelled-button rule doc 28's
Accessibility section pins; and it costs N settings commits plus N native pushes plus an undo path
for a fat-fingered change to live blocking. One line, one write, and the row's contract is left to
EVO-061.

## Rollback
Revert the Dart files. A settings write the user made through the line is their own choice and
stays (it is an ordinary `enabledPlatformIds` write).

## Implementation Plan

### Current state
`by_app_section.dart:62-74` — the excerpt above (`rowsFor`, Reels branch).
`by_app_section.dart:147-152`:
```dart
    final count = context.watch<ContentCounterCubit>().state;
    final blocks = context.select((ServiceCubit c) => c.state.blocksByPackage);
    final insights = context.watch<InsightsCubit>().state;
    final stats = insights.hasData ? insights.stats : null;
```
`by_app_section.dart:185-215` — the `GlassCard` of `AppLimitRow`s (`key: ValueKey(package)`,
`package`, `installed`, `name`, `iconUrl`, `trailing`, `spokenTrailing`, `fraction`).
`app_limit_row.dart:22-31` — constructor: `package, trailing, fraction, installed, name, iconUrl,
spokenTrailing`. `:95-104` — `AppPressable(semanticLabel: '$label, ${spokenTrailing ?? trailing}.
Set a daily limit', …)`.
`targets_cubit.dart:46-49` — `TargetsState({this.targets = const []})`.
`app_settings.dart:19-26` — `activePlan`, `enabledPlatformIds = const {}`, `masterEnabled = true`,
`pauseSession`, `reelAllowance = 1`.
`settings_cubit.dart:166-167`:
```dart
  Future<void> setEnabledPlatforms(Set<String> ids) =>
      _commit((s) => s.copyWith(enabledPlatformIds: ids));
```

### Target state
- `ByAppSection` gains two pure statics, `@visibleForTesting`:
  - `static Set<String> effectiveEnabled(List<BlockTarget> targets, Set<String> enabled)` →
    `enabled.isEmpty ? {for (t in targets) if (t.defaultEnabled) t.platformId} : enabled` — the
    native rule at `DetoxoAccessibilityService.kt:762`, cited in the dartdoc.
  - `static Set<String> platformsOff({required Iterable<String> packages, required
    List<BlockTarget> targets, required Set<String> enabled})` → the `platformId`s of targets whose
    `packageName` is in `packages` and is not in `effectiveEnabled(targets, enabled)`.
- `AppLimitRow({…, this.note})`: an optional muted `bodySmall` "Not blocked" after the trailing
  figure (`onGlassMuted`, `AppSpacing.xxs` gap), and the spoken sentence becomes
  `'$label, ${spokenTrailing ?? trailing}, not blocked. Set a daily limit'` when set.
- Under the By app panel, Reels segment only, when `platformsOff` is non-empty:
  `NotBlockingLine` — `Text` (bodySmall, muted): `"Detoxo counted these but isn't blocking
  <Snapchat> and <TikTok>"` (labels from `insights.apps` / the target's `displayName`, joined with
  ", " and a final " and "), then `SecondaryButton('Turn on')` calling
  `context.read<SettingsCubit>().setEnabledPlatforms(effectiveEnabled(targets, enabled) ∪ off)`.
  With `!masterEnabled`: the text reads `"Blocking is off, so Detoxo is only counting"` and no
  button; with `pauseSession != null`: `"Blocking is paused, so Detoxo is only counting"` and no
  button.
- Reads: `context.select((SettingsCubit c) => (c.state.enabledPlatformIds, c.state.masterEnabled,
  c.state.pauseSession != null))` and `context.select((TargetsCubit c) => c.state.targets)`.
- Copy never names a plan; the wire token is not involved.

### Repo conventions to follow
- Pure statics beside `rowsFor` / `emptyCopy` (`by_app_section.dart:55-130`) with
  `test/by_app_rows_test.dart` as the test home.
- `SecondaryButton` from `lib/core/design_system/components/buttons.dart`; no raw `TextButton`.
- Truthful states (EVO-014 / EVO-063): master-off and paused say so instead of offering a toggle
  that would change nothing.
- `context.select` tuples, the `TodayOverview` discipline (`today_overview.dart:30-34`).

### Steps
1. `by_app_section.dart`: add `effectiveEnabled` and `platformsOff`; tests in
   `test/by_app_rows_test.dart` (empty set = defaults; explicit set; a package with no target).
2. `app_limit_row.dart`: `note` + spoken sentence; `test/activity_screen_test.dart` — the spoken
   label with and without the note.
3. `by_app_section.dart`: the two selects, the `note` on Reels rows, `NotBlockingLine` under the
   panel with its three states; screen test cases: line + button with a platform off, master-off
   copy with no button, tapping **Turn on** calls `setEnabledPlatforms` with the effective union
   (mocktail `SettingsCubit`, the `test/resume_sync_test.dart` mock idiom).
4. Docs: `docs/code_docs/28-insights.md` §6 (the Reels segment paragraph);
   `docs/code_docs/12-…md` §1; `docs/code_docs/17-content-counter.md` (the "counts even when not
   blocking" paragraph gains the pointer); `info_docs/02` §15 (hand over — user-owned).

### Boundaries
Do not touch native. Do not add a per-row toggle. Do not write `enabledPlatformIds` from anything
but the effective union. Do not change `rowsFor`'s record shape. If `by_app_section.dart:62-74` /
`:147-152` or `settings_cubit.dart:166-167` have drifted from the excerpts, STOP and report.

### Validation
- [ ] `bash tool/dev.sh precommit` passes (format, analyze, test, boundaries)
- [ ] `tool/boundaries_baseline.txt` line count ≤ before
- [ ] New logic has a test in the repo pattern (bloc_test/mocktail)
- [ ] Invariants grep clean: names Detoxo/errorxperts only; `curious`/"CURIOUS"
      intact in wire/code, "Conscious" in UI strings
- [ ] Production readiness: the write goes through the existing settings commit + native push
      (survives process death and reboot via `ConfigStore`) · master-off / paused handled ·
      offline · no new manifest permission · no new failure paths
- [ ] Native untouched; manual check: turn Snapchat off in the App Blocker, scroll three reels,
      open Activity → marker + line → **Turn on** → the next Snapchat reel is blocked
- [ ] `/docs-sync` run; mapped docs updated
