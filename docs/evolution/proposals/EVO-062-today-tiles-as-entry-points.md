# EVO-062 — Today tiles as entry points to the By app segments

- Status: approved
- Tier: 2 (enhancement) — requires explicit per-proposal approval
- Feature: `lib/features/analytics` (presentation) + `lib/core/design_system/components/cards.dart`
- Commit: 185c7f7 (working tree uncommitted — the Activity restructure and its Tier-1 batch of 2026-09-07 are not yet committed)
- Date: 2026-09-07
- Effort: XS

## Why
The Today grid (`lib/features/analytics/presentation/widgets/today_overview.dart`) says "12
blocked" and "5 reels seen", but the card that explains *where* — `ByAppSection`, two cards down
— has to be found by scrolling and its segment chosen by hand. The tiles are static
(`StatCard` has no `onTap`, `cards.dart:59-70`), and the segment index is private to
`_ByAppSectionState` (`by_app_section.dart:137`), so nothing outside the card can select one.

## Expected user impact
Tapping **Reels seen**, **Blocked today** or **Screen time** selects the matching By app segment
and scrolls the card into view. The number becomes the first step of the act-on-it path
(EVO-033, EVO-061) instead of a dead readout. Peripheral polish by the product's own test — it
shortens the path to a limit but does not change what the intervention loop does.

## Technical complexity
Dart only. The segment state moves up one level into the screen (a `ValueNotifier<ByAppSegment>`
or a small `StatefulWidget` around the list), which is also what keeps it alive across the lazy
`ListView` — the keep-alive mixin added on 2026-09-07 can then go from `_ByAppSectionState`.
`StatCard` gains an optional `onTap` (wrapped in the existing `AppPressable`, the `GlassCard`
idiom at `cards.dart:41-42`). Scrolling uses `Scrollable.ensureVisible` on a `GlobalKey` held by
the screen (no current usage in `lib/`; the Flutter API is the convention). No channel, storage
or manifest change.

## Performance impact
None on the hot path. One `ensureVisible` animation per tap (`AppDurations.standard`, honouring
reduce-motion by passing `Duration.zero`).

## Business value
Supports the "tracking **and** intervention" row of the comparison table in
`docs/info_docs/01-product-overview.md`: a report that is one tap from the limit editor is the
opposite of "a chart you close and forget".

## Rejected alternative
Make each tile a deep link to the Rules screen filtered by kind. Rejected: it leaves the
Activity screen (the user loses the number they were reacting to) and the Rules screen has no
per-app filter today, so it would be a larger change for a worse path.

## Rollback
Revert the three Dart files. No stored data.

## Implementation Plan

### Current state
`cards.dart:59-70` — `StatCard` constructor: `label, icon, value, text, unit, trend, caption, compact`; no tap.
`today_overview.dart:36-58` — the two always-present tiles; `:62-84` the two granted-only tiles.
`by_app_section.dart:135-146`:
```dart
class _ByAppSectionState extends State<ByAppSection>
    with AutomaticKeepAliveClientMixin {
  int _index = 0;
  ...
  bool get wantKeepAlive => true;
```
`analytics_screen.dart:63-68` — `_ActivityBody` is a `StatelessWidget` holding the `ListView`.

### Target state
- `StatCard({... VoidCallback? onTap})`: when set, the tile is wrapped in `AppPressable` and its
  `Semantics` gains `button: true` and `hint: 'Show by app'`.
- `ByAppSection({required ValueNotifier<ByAppSegment> segment, super.key})` — the card reads and
  writes the notifier; `_index` and the keep-alive mixin are removed (the notifier lives in the
  screen and survives disposal). The clamp rule stays: if the notifier says `time` and the grant
  is gone, the card shows `blocks` without writing back, so `time` re-selects on return.
- `_ActivityBody` becomes stateful: owns `final _segment = ValueNotifier(ByAppSegment.reels)` and
  `final _byAppKey = GlobalKey()`; passes `onTap` closures to `TodayOverview` that set the segment
  and call `Scrollable.ensureVisible(_byAppKey.currentContext!, duration: reduce ? Duration.zero : AppDurations.standard, curve: AppCurves.standard, alignment: 0.1)`.
- `TodayOverview({this.onReels, this.onBlocks, this.onTime})`; Pickups has no target and stays
  static.

### Repo conventions to follow
- `AppPressable` for tappable glass (`cards.dart:41-42`); reduce-motion via
  `MediaQuery.maybeDisableAnimationsOf` (`cards.dart:109`).
- Screen-level state in the screen, not in get_it (composition rule, `CLAUDE.md`).

### Steps
1. `cards.dart`: add `onTap` to `StatCard` (semantics + `AppPressable`).
2. `by_app_section.dart`: replace `_index` with the notifier; drop the keep-alive mixin.
3. `analytics_screen.dart`: stateful body with the notifier and key; wire the three callbacks;
   dispose the notifier.
4. `today_overview.dart`: accept the three callbacks and pass them to the tiles.
5. Tests: `activity_screen_test.dart` — tapping "Blocked today" selects Blocks (assert the empty
   copy "No blocks yet today." is visible and `Scrollable.ensureVisible` brought the card on screen
   with a short viewport); tapping "Screen time" selects Time; the revoke test still passes.
6. Docs: `docs/code_docs/28-insights.md` §6 (the four-card paragraph and the keep-alive note —
   the segment now lives in the screen), `docs/code_docs/12-…md` source files, `info_docs/02` §15
   (hand over).

### Boundaries
Do not add a route or a dashboard tile. Do not make Pickups tappable. If
`by_app_section.dart:135-146` or `cards.dart:59-70` have drifted from the excerpts, STOP and
report.

Drift note (2026-09-07): both have drifted — `StatCard` gained `contained` (default `true`; the
Activity tiles pass `false` and sit in one `GlassCard` panel under a `SectionHeader`), and
`ByAppSection` is now `SectionHeader` + bare `GlassSegmented` + a `GlassCard` of rows (see
`docs/evolution/BACKLOG.md`, "Activity screen: headed sections"). Re-read the target files and
refresh the excerpts before executing. One design question is now yours: an uncontained tile is a
bare `Padding`, so a tappable Today tile needs its own affordance — keep `contained` for tappable
tiles, or add one (the `AppPressable` scale alone is not it).

### Validation
- [ ] `bash tool/dev.sh precommit` passes (format, analyze, test, boundaries)
- [ ] `tool/boundaries_baseline.txt` line count ≤ before
- [ ] New logic has a test in the repo pattern (bloc_test/mocktail)
- [ ] Invariants grep clean: names Detoxo/errorxperts only; `curious`/"CURIOUS"
      intact in wire/code, "Conscious" in UI strings
- [ ] Production readiness: no persisted state · no permission path · offline · no new
      manifest permission · no new failure paths
- [ ] Native untouched — no device sanity list; manual check: TalkBack announces the three
      tiles as buttons with the hint, Pickups as plain text
- [ ] `/docs-sync` run; mapped docs updated
