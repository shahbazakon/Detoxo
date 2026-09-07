# EVO-064 — Web blocker adopts the Activity tile pattern and its own label

- Status: approved
- Tier: 2 (enhancement) — requires explicit per-proposal approval
- Feature: `lib/features/limits/web_blocker` (presentation) + `lib/core/design_system/components/cards.dart`
- Commit: 185c7f7 (working tree uncommitted — the Activity restructure and its Tier-1 batch of 2026-09-07 are not yet committed)
- Date: 2026-09-07
- Effort: S

## Why
`lib/features/limits/web_blocker/presentation/web_block_screen.dart:165-190` draws three
full-size `StatCard`s in a bare `Row`:
```dart
                  child: StatCard(
                    label: 'Blocked today',
                    value: stats.blockedToday,
                    icon: Icons.block,
                  ),
                ...
                  child: StatCard(
                    label: 'Total blocked',
                    value: stats.totalBlocked,
                    icon: Icons.public_off,
                  ),
                ...
                  child: StatCard(
                    label: 'Focus saved',
                    value: stats.focusMinutesSaved,
                    unit: 'min',
                    icon: Icons.timer_outlined,
                  ),
```
Since the Activity restructure (2026-09-07) the string "Blocked today" names two different
quantities on two screens (site bounces here, app blocks on Activity), and the two screens model
the same today/all-time pair two ways: Activity folds all-time into a caption on a compact tile,
Web blocker keeps it as a peer full-size tile. The comment at `:160-163` also documents why the
`Row` cannot use `IntrinsicHeight` here (unbounded `ListView` height) — the `StatCardPair` added
on 2026-09-07 solves exactly that.

> Drift (2026-09-08): the Activity tile is now labelled **Blocked** (the copy trim), so "Blocked
> today" names one quantity again — the Web blocker's. The peer-tile vs caption asymmetry this
> proposal addresses still stands. Note the exemplar's caption rule also changed: one reference
> per tile (`Yesterday: N` once there is history, else `All time: N`).

## Expected user impact
The Web blocker screen reads "Sites blocked today" with "All time: N" beneath it, beside
"Focus saved", in the same compact tiles as Activity — one vocabulary, one style, one fewer tile.
Peripheral: consistency, not intervention.

## Technical complexity
Dart only; one screen and no design-system change beyond reuse of `StatCard(compact: true)` and
`StatCardPair`. No channel, storage or manifest change.

## Performance impact
None. One fewer tile and one fewer tween on the screen.

## Business value
The store-listing story bundles reels, apps and sites as one blocker
(`docs/info_docs/01-product-overview.md`, "Block more than reels"); two visual grammars for
"blocked today" undercut that.

## Rejected alternative
Rename only ("Sites blocked today") and keep the three full-size tiles. Rejected: fixes the
collision but leaves the second modelling of today/all-time, which is the thing that will be
copied next time someone adds a counter.

## Rollback
Revert the one Dart file and its test. No stored data.

## Implementation Plan

### Current state
`web_block_screen.dart:160-190` — the excerpt above, inside a `ListView` child.
`cards.dart` — `StatCard` (`compact`, `text`, `caption`) and `StatCardPair(first, second)`.
`test/web_block_screen_semantics_test.dart` — pins the tiles' spoken labels (read it first; the
"Blocked today: N" expectations change).

### Target state
```dart
StatCardPair(
  StatCard(
    compact: true,
    label: 'Sites blocked today',
    value: stats.blockedToday,
    icon: Icons.block,
    caption: stats.totalBlocked > 0 ? 'All time: ${stats.totalBlocked}' : null,
  ),
  StatCard(
    compact: true,
    label: 'Focus saved',
    value: stats.focusMinutesSaved,
    unit: 'min',
    icon: Icons.timer_outlined,
  ),
)
```
The comment block at `:160-163` about `IntrinsicHeight` is deleted — `StatCardPair` is the
answer it was warning about. Spoken: `"Sites blocked today: 12, All time: 340"` (the comma
rule from `cards.dart:96-100`).

### Repo conventions to follow
- `TodayOverview` (`lib/features/analytics/presentation/widgets/today_overview.dart:36-58`) is
  the exemplar for the compact pair with an all-time caption and the zero rule (no caption at 0).
- Copy in `docs/code_docs/06-app-and-web-blocker.md:427-428` and
  `docs/info_docs/02-feature-walkthroughs.md:316` / `04-faqs.md:291` names the old tiles.

### Steps
1. `web_block_screen.dart`: replace the `Row` with the `StatCardPair` above; delete the comment.
2. `test/web_block_screen_semantics_test.dart`: update the spoken-label expectations; add the
   zero-caption case.
3. Docs: `docs/code_docs/06-app-and-web-blocker.md` (the tiles paragraph), `info_docs/02` §
   web blocker and `04-faqs.md:291` (hand over, user-owned).

### Boundaries
Do not touch `WebBlockStats`, the native web blocker or the "Focus saved" arithmetic. If
`web_block_screen.dart:160-190` has drifted from the excerpt, STOP and report.

Drift note (2026-09-07): the exemplar has drifted, not the target — `today_overview.dart` now
renders its tiles `contained: false` inside one `GlassCard` panel under a `SectionHeader` (see
`docs/evolution/BACKLOG.md`, "Activity screen: headed sections"). The web-blocker tiles have no
panel around them, so they stay `contained` (the default) — the shared vocabulary is
`StatCard(compact: true)` + `StatCardPair`, not the surface. Refresh the exemplar excerpt before
executing.

### Validation
- [ ] `bash tool/dev.sh precommit` passes (format, analyze, test, boundaries)
- [ ] `tool/boundaries_baseline.txt` line count ≤ before
- [ ] New logic has a test in the repo pattern (bloc_test/mocktail)
- [ ] Invariants grep clean: names Detoxo/errorxperts only; `curious`/"CURIOUS"
      intact in wire/code, "Conscious" in UI strings
- [ ] Production readiness: no persisted state · no permission path · offline · no new
      manifest permission · no new failure paths
- [ ] Native untouched; manual check: the pair at 1.3× / 2.0× text scale on a 360 dp screen
- [ ] `/docs-sync` run; mapped docs updated
