# Locked Rules & Per-Target Unblock

Written from shipped source. Two halves of one tension: making a rule **harder to escape**, and
giving the user a **legitimate, rationed, per-target way out** so they don't disable everything
instead. Plan doc: [`plan_docs/10-M8-locked-rules-and-app-unblock.md`](../plan_docs/10-M8-locked-rules-and-app-unblock.md).

Before this, every escape hatch in Detoxo was **global and unrationed** — Pause, Unblock-N-reels and
One Reel all lift protection on *everything*, and any blocklist entry or rule was one tap from off.
So a user who needed Instagram for two minutes had exactly one option: turn the product off. The one
place Detoxo already did this right was the web blocker's per-site pause (EVO-012/EVO-048); M8
generalises that line to reels and apps and adds the commitment side that makes it safe to have.

The load-bearing decision: **the two mechanisms are deliberately different shapes.** A *grant*
frees one target; an *override* lifts one rule. Collapsing them would break the thing each protects
— see §4.

---

## 1. Layout

```
lib/features/limits/unblock/
├── domain/entities/{temporary_unblock,bypass_entry,bypass_config}.dart
├── domain/repositories/unblock_repositories.dart   TemporaryUnblockRepository, BypassLedger(+Repository)
├── domain/usecases/unblock_quota.dart              ALL the pure logic — static, clock-injected
├── domain/unblock_sync.dart                        syncTemporaryUnblocks(): THE push path
├── domain/migrate_web_pauses.dart                  one-time, for the wire-contract change
├── data/repositories/{temporary_unblock,bypass_ledger}_repository_impl.dart
└── presentation/
    ├── unblock_cubit.dart                          app-wide; grants, quota, the wall hand-off
    └── widgets/{unblock_duration_sheet,pending_unblock_listener}.dart

android/.../engine/UnblockRegistry.kt               Android-free; JVM-tested
```

The `limits.dart` barrel exports the domain, both syncs and the app-wide `UnblockCubit` (the
`RulesCubit` precedent), so the App Blocker screen, the Website blocker screen, the rule editor and
`AppResumeSync` all reach it without a boundary violation. `tool/boundaries_baseline.txt` is
unchanged (still zero entries).

## 2. Part A — the per-target grant

### Data model — Hive `StoreKeys.temporaryUnblocks`

```jsonc
{ "grants": [                          // newest first, capped at 50, pruned ON WRITE
    { "targetType": "APP",             // REEL | APP | WEBSITE
      "targetId": "com.instagram.android",   // platformId | package | host
      "startMs": 1756742400000,
      "endMs":   1756743300000,
      "cancelledMs": null,             // "I'm done" — protection back NOW, not at endMs
      "source": "WALL" }               // WALL | BLOCKLIST_ROW
] }
```

`cancelledMs` is a separate field rather than a rewritten `endMs`, so the history stays honest about
what was asked for versus what was used. Every field is read null- **and** type-tolerantly; a row
with an unknown type, an empty id or an inverted window is dropped on its own.

There is **no `OVERRIDE` source**: an override is not a grant (§4).

### EVO-053 — grants are rationed too, if you ask

M8 shipped two escapes with opposite economics: the override was rationed and
the grant was not, so a 60-minute allowance could be re-taken the instant it
lapsed, from the very wall the block raised. "Everything else stays protected"
was true per window, not per day.

`BypassConfig.grantLimit` (per `grantPeriod`, default **0 = unlimited**, set
under *Settings → Protection → Allowances*) budgets them, counted by the same
rolling-window arithmetic as the override so the store has one clock story.
Every grant writes a `BypassKind.grant` row **even when unlimited** — a budget
switched on tomorrow needs today's history to mean anything — and one user
action spends exactly one allowance, aliases included.

Native cannot see the ledger and never will: the refusal is stated in the sheet,
not on the wall, so `offersUnblock` is unchanged. That is the accepted ceiling.

### EVO-051 / EVO-052 — the state, said back

`ActiveUnblocksCard` (dashboard) is the one place that lists what is open right
now, including a `REEL` grant, which had no surface at all. `OverrideHistoryCard`
(Activity → Events) says what the override ledger recorded — the reasons the
user picked themselves. Both hide entirely when there is nothing true to say.

### Durations

Reuse, not reinvention: `showUnblockDurationSheet` is the web blocker's EVO-012 pause sheet lifted
verbatim — a `GlassBottomSheet` of **5 / 15 / 30 / 60**-minute `AppChip`s. Every entry point uses
it, and the override sheet in the rule editor (`_OverrideTile` / `_showOverrideSheet` — there is no
separate screen or route) passes `maxWindow` so it cannot buy more than the quota allows. Backing
out grants nothing.

### Wire — `pushTemporaryUnblocks {json}`

Three keys, and only the **active** grants:

```jsonc
[{ "targetType": "APP", "targetId": "com.instagram.android", "endMs": 1756743300000 }]
```

`startMs` has already passed by push time, cancelled rows never ship, and `source` is Dart's
bookkeeping. The arm is `pushWebBlocklist`'s twin in `CommandHandler.kt`: an absent / non-array
`json` is a **no-op** (clearing needs an explicit `"[]"`), an unchanged payload skips the prefs
write, then `service.refreshTemporaryUnblocks()` — never a full `reload()`.

### Native — `engine/UnblockRegistry.kt`

Android-free, so the decision logic runs on the JVM; `WebBlockEngine` takes a `Context` for its
bundled asset and is untestable for exactly that reason. Modelled on `RuleEngine`'s `Snapshot`: the
grants plus their derived gates swapped as **one** `@Volatile` reference, holding the `source`
string so a re-push of an unchanged payload costs no parse.

```kotlin
fun setGrants(json: String?, nowWall: Long, nowElapsed: Long)   // clocks are ARGUMENTS
fun isUnblocked(type: String, id: String, nowElapsed: Long): Boolean
fun hasAny(type: String, nowElapsed: Long): Boolean             // the hot-path gate
```

- **Deadlines are monotonic (EVO-048).** `endMs` rides the wire as a wall stamp because that is the
  only thing that survives a reboot, and is converted **once per parse** to an `elapsedRealtime`
  deadline — the `toElapsedDeadline` helper moved here from `WebBlockEngine`, which no longer has a
  copy. Comparing the wall clock per event would let a user roll the device clock back in Settings
  and hold a grant open forever.
- A deadline already in the past is **dropped at parse**. That is the entire pruning story: stale
  grants can neither accumulate in prefs nor come back after a clock jump, with no Dart push.
- `APP` / `REEL` match exactly; `WEBSITE` also matches a subdomain of the granted host
  (`RuleEngine.isSubdomainOf`), so unblocking `youtube.com` covers `m.youtube.com` — the coverage
  the per-site pause had, since it paused the whole matching rule.
- Malformed keeps the previous set; blank clears; capped at `MAX_GRANTS = 50`.

`refreshTemporaryUnblocks()` has **two callers** — the command arm *and* `reload()` — so a reboot or
a service reconnect re-anchors every grant against the surviving wall stamp. Without the second,
every grant would silently die at reboot.

### The four check sites

Computed once and opted into textually, the way `val paused = nowMs < pausedUntil` already works:

| Site | Change |
|---|---|
| App Blocker whole-app lock | `pkg in blockedApps && … && !appUnblocked(pkg)` |
| **strict rules (above the pause gate)** | **untouched — this absence is the guarantee** |
| package rules (below the gate) | `!paused && hasPackageRules() && … && !appUnblocked(pkg)` |
| reel detector loop | `reelUnblocked` per platform, consumed after the rule resolve |
| `WebBlockEngine.matchHost` | one check above the rule loop (§3) |

`appUnblocked(pkg)` is resolved **after** each arm's cheaper guards (`pkg in blockedApps`,
`hasPackageRules()`), not once up front: hoisting it meant a grant-holder paid the scan on every
event of every monitored app even where neither consumer could fire.

Inside it, `hasAny(type, nowElapsed)` is the gate, so a user with no grants pays one volatile read
and one long compare. It takes the clock because the gate has to **expire itself**: per-type
booleans derived at parse stayed true for the life of the process once a single grant existed, so
after the last one lapsed — with Flutter dead, which is the case native expiry exists for — every
event went on paying a full scan of up to `MAX_GRANTS` rows. `Snap` now holds the furthest deadline
per type instead. Same shape in the reel loop and in `WebBlockEngine.matchHost`, each reading
`elapsedRealtime` once and passing it to both calls.

### EVO-050 — the chips are on the wall

The tap that says "let me in" now asks its own question, where the block
happened. `BlockScreenRenderer` renders a **5 / 15 / 30 / 60** row that replaces
the trigger button in place; `ACTION_UNBLOCK` only reveals it (and is still
posted, so analytics keeps the intent separate from the choice), and
`ACTION_UNBLOCK_5` … `_60` carry the answer.

Pressing a button on a wall blocking Instagram used to take the user *out of
Instagram and into Detoxo* — the outcome the wall was already producing — and
every defect the M8 audit found on that path (a prefs key with no TTL that
re-fired days later, a tap eaten by a PIN-locked launch, a sheet with no
Navigator above it) existed only because the question was asked somewhere other
than where it was raised.

**The cost is a bidirectional store, and it is the thing to keep straight.**
`ConfigStore.appendGrant` writes the row to **two** keys: `temporary_unblocks_json`,
which native enforces on the very next event, and `native_grants_json`, a
hand-off list. Hive stays canonical — it holds the history and the ledger — and
`syncTemporaryUnblocks` rewrites the enforced list wholesale, so without the
second key Dart's next push would silently delete the grant the user just took.
`UnblockCubit.absorbNativeGrants` drains it (read-and-clear) from the bootstrap
and from every resume, **before** the resync, and records the spend in the
ledger like any other grant.

If `appendGrant` fails, the arm falls back to M8's hand-off — arm
`pending_unblock`, launch Detoxo — rather than dropping the tap. The button must
never do nothing.

> **A grant lifts the App Blocker row**, whose comment used to call locks unconditional. That *is*
> the headline feature — "Unblock Instagram for 15 minutes" has to work from an app-block wall and
> from the blocklist row, or the only way in is turning protection off entirely. A **Pause** still
> does not.

### The reel loop resolves strict FIRST

The loop cannot trust the first match's `strict` flag, because
`RuleEngine.blockingForPlatform` returns the **first covering entry** and the snapshot is ordered by
`createdAtMs`. An older non-strict rule on `ig_reels` therefore *masks* a newer locked one — its
wall would offer "Allow for a while", and the grant that tap mints would lift the locked rule for
free, with no override spent.

So the loop runs its own `strictOnly = true` pass first (gated on `hasStrictPlatformRules()`),
exactly like the package arm above the pause gate. A hit blocks with `offersUnblock = false` and the
grant is never consulted. Only then does the general pass run, and only below `if (paused) continue`.
`RuleEngineTest.strictOnlyFindsAStrictEntryBehindAnOlderNonStrictOne` pins it for all three arms.

A granted reel is still **counted** — the awareness pass runs above the whole block branch.

### The Conscious accountant freezes — by clearing the watch stamp

The granted arm does `lastReelAtMs = 0L` before returning, which drops the 1 Hz accountant into its
existing *"lingering in a reel app with no fresh detection"* branch: neither drain nor accrue. That
is the freeze, and it costs one assignment.

It is deliberately **not** a per-package early return in `accountConscious`. The accountant only
knows the foreground package, but a grant names one `platformId` — so freezing on "any platform of
this package is granted" would stop the bank draining for every *other* surface in the same app
(Snapchat Stories while Spotlights is granted), a free ride the user never bought.

For the same reason the drain-to-empty wall names `lastReelPlatformId` — the surface that actually
drained the bank — rather than the package's first reel platform. Since M8 that `referenceId` is
what an Unblock tap grants, so guessing would sell the user a grant for a surface they were not on;
with no stamp (a service restart mid-drain) the wall offers no button at all.

## 3. The wire-contract change — the web per-site pause

M8's one contract change, and the point of the milestone: `pausedUntil` is **gone** from
`pushWebBlocklist` and from `WebBlockEntry`. "This target is dormant until T" is one mechanism now,
not two.

```kotlin
fun matchHost(host: String): Match? {
    if (host.isEmpty()) return null
    val nowElapsed = SystemClock.elapsedRealtime()
    val granted = unblocks.hasAny(TYPE_WEBSITE, nowElapsed) &&
        unblocks.isUnblocked(TYPE_WEBSITE, host, nowElapsed)
    if (!granted) { for (r in rules) { … } }
    if (matchesAdult(host)) return Match.ADULT
    return null
}
```

The grant check gates **only** the user's own rules. The adult walk is structurally outside it — not
merely skipped by a `continue` — so an 18+ hit can never be lifted by a grant (EVO-018). Native
ignores an old build's `pausedUntil` key for free: nothing reads it.

- **`ruleEngine.blockingForHost` is deliberately NOT gated by the registry.** `pausedUntil` never
  lifted a scheduled rule either, and adding it would be new bypass surface. An override reaches a
  locked rule's websites through the window split instead (§4).
- The row's Allow/Resume action calls `UnblockCubit.grant` / `endEarly`; a **popular** entry's
  cross-registrable aliases (`youtu.be` for `youtube.com`) each get their own grant, exactly as
  `syncWebBlocklist` used to duplicate the pause onto them.
- `migrateWebPauses` runs once at bootstrap: it reads the **raw** `web_blocklist` blob (the parsed
  entity has already dropped the field), turns any live pause into a `WEBSITE` grant keyed on the
  pattern, then rewrites the blob without the key — which is what makes it idempotent.

## 4. Part B — locked rules

`Rule` gains two sparse fields beside `strict` (`if (locked) 'locked': true`, so an unlocked rule's
document is byte-identical to a pre-M8 one):

```jsonc
{ "locked": true, "lockScope": "DISTRACTING" }   // SELECTION (default) | DISTRACTING
```

**Set once, at creation, behind a blunt confirmation, and never cleared.** There is no in-app
unlock: the commitment is the feature. The unwind of last resort is Settings → Reset app data, or
turning the accessibility service off, and the copy says so.

### `locked ⟹ strict` — the snapshot gains no key

At snapshot time Dart emits `strict: r.strict || r.locked` (`Rule.isStrict`). Native learns
**nothing new**: `locked` and `lockScope` stay Dart-side, purely for the refusal and the UI, and are
additive to the wire later if a reason ever appears. `SuppressionDecision` inherits the right
behaviour for free — a locked rule keeps silencing notifications through a Pause.

This also closed EVO-030's documented website gap. `strict` covered apps and reel feeds only, so a
two-minute Pause opened a strict rule's *websites* for free — which for a locked rule would mean
paying an override for what one tap gives away. `RuleEngine.blockingForHost` gained `strictOnly`
(its two siblings already had it) plus a `hasStrictHostRules()` gate, and the browser arm now runs
when `!paused || ruleEngine.hasStrictHostRules()`, passing `strictOnly = paused` down. Everything
else a Pause lifted still lifts: the user's own blocklist and every non-strict host rule.

### An override lifts a RULE, not its targets

An active override is `{ruleId, untilMs}` on the ledger. `resolveSnapshot` runs the pure
`subtractWindow(windows, from, until)` over that rule's own entry windows:

```
schedule 09:00–17:00, override 10:00–11:00  →  windows: [[09:00,10:00],[11:00,17:00]]
spent limit (today's period)                →  [[dayStart,10:00],[11:00,dayEnd]], spent STAYS true
```

Why this shape and nothing else:

- **Zero Kotlin, zero wire.** `RuleEngine.Entry.isActive` already walks a flat pair array.
- **Native re-arms at 11:00 by its own long compare**, with Flutter dead — the property a
  "skip this rule" flag would lose.
- **It is scoped correctly.** A target-shaped grant on `com.instagram.android` would also lift every
  *sibling* rule on Instagram and the App Blocker row — the plan's own `liftsUnlockedRulesToo:
  false` default made flesh. Because only that rule id is touched, the knob falls out for free and
  was dropped from `config` rather than implemented twice.
- Keeping `spent: true` on a limit entry (rather than flipping it to `false`) makes it immune to
  EVO-029: `LimitReconciler` only measures *pending* entries, so the watchdog cannot re-close the
  override 15 minutes in.

`consider(untilMs)` puts the lift's end into `nextBoundaryMs`, so `ruleBoundary` fires and Dart
re-pushes exactly when the rule resumes. The status reads `Lifted to 5:30 PM`, never "Active now".

### `lockScope: DISTRACTING`

Widens the rule to every package `Catalog.bundled.packagesWithBehavior(AppBehavior.distracting)`
names, plus their domains — so a lock keeps holding as new apps are installed. Three gates, each of
which is the difference between a feature and a bug:

1. Applied at **`SnapshotEntry` construction**, never inside `_flatten` — whose package list is also
   the *budget denominator* (`_sum`, and native's `LimitReconciler` sums across the same set).
2. **`SCHEDULE` only.** Widening a time or open limit would turn "30 minutes of Instagram" into
   "30 minutes of any distracting app", spent within minutes.
3. **`BLOCK` only.** Under `ALL_EXCEPT` membership is inverted, so the widened set would become the
   only apps *exempt*. The editor emits `BLOCK` today, but `ALL_EXCEPT` is carried end to end for a
   later focus mode, so this is a live trap.

Size is a non-issue: ~1.4 KB of JSON against a ~45 KB typical snapshot, and `MAX_ENTRIES = 51` is
untouched. Protected apps need no subtraction — the privacy guard returns before every block branch.

> `ponytail:` the catalog is a bundled static seed, so an app released after the last build is
> `neutral` and DISTRACTING misses it too. It widens today's coverage; it does not future-proof it.

### Non-disableable, enforced in the domain

`RuleRepository` is only `load()`/`save()`, so the invariant lives on the one choke point every
mutation funnels through — **`RulesCubit._commit`**, behind `save` / `remove` / `setEnabled`. The
pure `LockGuard.check(previous, next)` refuses **deleting, disabling, unlocking and narrowing** a
locked rule (narrowing includes flipping `BLOCK` → `ALL_EXCEPT`, which frees every target it names,
and shrinking the lock scope). Renaming and *widening* stay allowed — tightening a commitment is
never the thing you regret at 1 a.m.

Hiding the toggle would not be enough: this cubit is reachable from the dashboard card, the resume
sync and the splash reload, and a rule that can be disabled through a side door is not locked. The
rules screen renders **no `AppToggle`** for a locked rule — absent, not greyed, because a disabled
switch is an invitation to keep tapping.

### The ledger and the quota — `StoreKeys.bypassLedger`

```jsonc
{ "config": { "overrideLimit": 2, "overridePeriod": "WEEK", "overrideMaxWindowMs": 3600000 },
  "entries": [ { "kind": "OVERRIDE", "atMs": 0, "untilMs": 0, "ruleId": "uuid",
                 "reason": "SCHEDULE_CHANGE" } ] }   // newest first, max 50, pruned on write
```

**One store with a `kind` discriminator from day one.** M8 writes only `OVERRIDE`; M2.2's emergency
pass adds `EMERGENCY` to this same list rather than a second key — a persisted-key rename is a
one-way door. Each preset reads only its own kind. A corrupt blob **throws**: reading an unparseable
ledger as empty would hand out a fresh quota every time.

`"WEEK"` means a **rolling** seven days, not a calendar week: an entry counts while
`now - atMs < periodMs`. A calendar period needs week-start/timezone/DST arithmetic for no gain, and
it makes a clock jump *more* rewarding (one hop past the boundary refills everything, instead of
ageing out one entry). It is also the shape M2.2's cooldown already specifies for this store.

```
effectiveRemaining = max(0, limit - count{ kind==OVERRIDE && now - atMs < periodMs })
resetsAtMs         = min(atMs of counted entries) + periodMs      // 0 while some are available
```

> `ponytail:` wall-clock. Moving the system clock forward mints quota — the ceiling already accepted
> at `pin_config.dart` (reboot + clock-forward) and in `WebBlockEngine`. Not worth hardening here
> alone: the same jump already walks the user out of every schedule window and resets every daily
> budget. Harden at that shared `now`, once, or not at all.

`requestOverride` validates **before any write** — a refusal must never leave a half-spent quota
behind, so a wrong-shaped request must not be able to burn one either:

1. **`enforcingNow`** — checked first. An override buys a window starting *now*, so spending one on
   a schedule that is closed (or a limit whose budget is not spent) costs a scarce resource and
   lifts nothing; the rule was going to let you in anyway. The editor also greys the tile for the
   same condition, so the user is never led into a sheet that will refuse, and the status is
   re-read at commit time because the sheet is two taps long and a window can close inside it.
2. `remaining > 0`, 3. a reason is present, 4. `start < end`, 5. window ≤ `maxWindow`. The six reason tokens
are C2's, verbatim: `FEELING_SICK`, `MEDICAL_APPOINTMENT`, `FAMILY`, `SCHEDULE_CHANGE`,
`WRONG_SCHEDULE`, `OTHER`. The picker asks for the reason **first**, then the window: naming the
reason is the friction, and picking a duration before it would make the reason feel like paperwork.

**The PIN is deliberately not stacked on top.** The PIN guards settings; the quota guards the rule.

## 5. The wall's "Allow for a while"

M1 shipped the button, the action token, the string and the event, with `offersUnblock` false
everywhere and `ACTION_UNBLOCK -> Unit  // M8 owns what happens next`. M8 fills both in.

`offersUnblock` is now true at the **non-strict** payload builders only:

| Wall | `offersUnblock` |
|---|---|
| App Blocker lock | `true` **unless a strict rule also covers the package** |
| non-strict package rule | `true` |
| **strict rule (the arm above the pause gate)** | `false` |
| reel block | `!rule.strict` |
| website, user blocklist hit | `match == RULE && !webEngine.matchesAdult(host)` |
| website, rule hit | `false` (a rules-path host lift is not supported) |
| adult | already `false` via `sanitised()` (EVO-018) |

`matchesAdult` is a new cold-path method: a host on **both** the user's blocklist and the 18+ set
wins its match on the rule arm, so the button would otherwise appear, mint a grant, and the next
visit would still be blocked — now unnamed. The affordance must not lie.

The App Blocker row obeys the same rule, and it is the one place it is not obvious: that arm runs
*above* the strict arm, so a package on the blocklist **and** under an open locked rule would offer
the button, take the tap, mint a grant that lifts only its own arm — and be bounced by the very next
event with no button and no explanation. It therefore resolves `blockingForPackage(strictOnly = true)`
on the block path (already debounced) and passes `offersUnblock = strict == null`.

### The hand-off is a consumable key, not an event

`ACTION_UNBLOCK` calls `ConfigStore.setPendingUnblock(type, id, now)` — stored as `"TYPE|id|stamp"`
— and then `detach(); launchDetoxo()`, the `OPEN_APP` shape. Dart drains it with
**`takePendingUnblock`**, which reads *and clears* and hands back the `"TYPE|id"` pair; the stamp
never crosses the channel, so the wire contract is unchanged.

**The stamp is what keeps the key from outliving the tap.** `launchDetoxo` swallows its own failure,
and the user can swipe Detoxo away before the drain — either way the key survived, and days later an
unrelated launch opened a duration sheet nobody asked for, one tap from an hour-long bypass. Anything
older than `ConfigStore.PENDING_UNBLOCK_TTL_MS` (2 minutes, generous against a drain that runs in
bootstrap seconds later) is dropped. A backwards clock yields a negative age, which is also outside
the window: fail-safe.

Two details in `PendingUnblockListener` that are easy to get wrong, and were:

- **It pushes the sheet through `appNavigatorKey`, not its own context.**
  `MaterialApp.router`'s `builder` runs *above* the `Navigator`, so
  `showModalBottomSheet` on that context finds none and throws — the button would have been dead on
  arrival. The listener has to live there (it needs the gate, and it must survive route changes), so
  the router got an explicit `navigatorKey` and the sheet goes through it.
- **A tap that lands on a PIN-locked launch is HELD, not consumed.** Launching Detoxo is what the
  tap *does*, so it usually arrives before the gate opens; consuming it there would make the button
  silently do nothing. The listener also subscribes to `AppGate` and shows the sheet the moment the
  gate opens.

`test/pending_unblock_test.dart` mounts the real shape — router, `builder`, gate — because nothing
else in the suite does, and both of those defects were invisible to every other test.

The `blockScreenAction` event still fires (analytics logs it), but it cannot carry this flow: on a
cold start the EventChannel sink does not exist when the action is posted, so the event is dropped
and the button would silently do nothing. Making it sticky instead would re-offer a bypass for a
stale target on the next engine attach, and double-log the analytics event.

Drained from the bootstrap's background phase **and** from `AppResumeSync`'s cheap leg (the tap
foregrounds Detoxo, so a resume is the delivery path when the process was already alive).
`PendingUnblockListener` is mounted inside `MaterialApp.router`'s `builder`, so the sheet can never
float over the PIN lock or the splash.

> `ponytail:` the upgrade path is rendering the chips on the wall itself and skipping the app switch
> entirely — at the cost of a second duration UI in Canvas and a native→Dart reconcile.

## 6. No expiry event — the timer instead

The plan specified a tenth EventChannel type, `temporaryUnblockExpired`. It was **dropped**:
Detoxo is single-process, so the Dart isolate is alive in exactly the states where a native event
would have had a sink to reach. `UnblockCubit` arms a one-shot `Timer` to the earliest `endMs + 1 s`
— the `RulesCubit._armTimer` idiom, never a ticker — and the callback re-derives and re-emits
locally: no persist, no re-push, because native has already expired it.

Two things make that work, and both are load-bearing:

- **`UnblockState` carries a derived `active` list**, recomputed on every resync. `emit` is a no-op
  when props are equal, so a state holding only the raw rows would not rebuild on the tick and the
  dead countdown would stay on screen — which is what the row does today when it reads
  `DateTime.now()` at build time. The blocklist rows now `context.select` the grant off `active`.
- **`AppResumeSync` re-syncs**, covering a timer that slept through a doze.

Event types stay at **9**; command methods go 50 → **52** (`pushTemporaryUnblocks`,
`takePendingUnblock`), and `StoreKeys` 16 → **18**.

## 7. Tests

- JVM `engine/UnblockRegistryTest.kt` — blank clears / malformed keeps the previous set / an
  unchanged payload is not re-parsed (so a resume re-push cannot renew a grant); the 50 cap; APP and
  REEL match exactly and never cross type; WEBSITE matches `m.youtube.com` against a `youtube.com`
  grant but **not** the reverse, `notyoutube.com` or `youtu.be`; hosts lower-cased but packages not;
  a past deadline dropped at parse; end exclusive; and **the EVO-048 guard — a grant minted 10
  minutes out is still gone after the wall clock is moved back an hour.**
- JVM `engine/RuleEngineTest.kt` gained `strictOnly` on the host arm, `hasStrictHostRules` (false
  for a strict rule that names only packages, or the browser arm would open on every Pause), and
  **a strict entry hiding behind an older non-strict one** — the ordering hazard the reel loop's
  strict-first pass exists for, pinned on all three arms.
- Dart `test/temporary_unblock_test.dart` — window boundaries, cancellation clamping, the exact
  three-key wire payload asserted off the decoded JSON, type-tolerant parsing, the pure helpers, the
  cubit (wire shape, alias expansion, replace-don't-stack, end-early, **the derived `active` list
  actually changing props when a grant lapses**, a corrupt store aborting the push instead of
  clearing native, the pending hand-off and its malformed inputs), and every branch of
  `migrateWebPauses` including idempotency.
- Dart `test/override_quota_test.dart` — the six reasons round-trip and never leak a wire token into
  a label; an unknown `kind` is dropped, not miscounted; a hostile config is clamped (`limit: 0` can
  never be created); the rolling window at exactly `periodMs`; emergency entries not spending the
  override quota; `resetsAt` from the oldest counted entry; a backwards clock not forgiving an
  entry; every validation refusing **before** the write; and `LockGuard` refusing
  delete/disable/unlock/narrow/reschedule/loosen-the-budget while allowing rename/widen; and an
  override refusing **first** on a rule that is not blocking, without touching quota.
- Dart `test/rules_engine_test.dart` — `locked` emits `strict: true` and adds no snapshot key; an
  override splits the covering window in two and lands `nextBoundaryMs` on the lift's end; a full
  cover removes the window and keeps the rest; a lifted rule reports "Lifted", not "Active now"; a
  spent limit keeps `spent: true` while split; `subtractWindow`'s disjoint/empty cases; DISTRACTING
  widening a BLOCK schedule but **not** a limit and **not** an `ALL_EXCEPT` rule; sparse round-trip;
  **an unknown-usage limit staying spent through a lift** (the hole cut in the previous snapshot
  would otherwise read as "never spent" and silently un-spend the budget for good); and a lift on a
  rule with no open window not being reported as "Lifted".
- `test/pending_unblock_test.dart` — the wall hand-off in the real widget shape: the sheet opens
  from the builder context, backing out grants nothing, and a tap arriving behind the PIN lock is
  held until the gate opens.
- `test/web_block_screen_semantics_test.dart` provides an `UnblockCubit` (the row reads its pill
  off it) and `integration_test/blockers_e2e_test.dart` asserts the grant, not the old field.
- Device sanity (not automatable here): unblocking Instagram leaves reels blocked in every other app
  and web blocking untouched; a grant expires on time with Detoxo force-stopped, and survives a
  reboot with the right remaining time; "end early" restores protection immediately; a strict rule
  is not lifted by a wall unblock and — new — its websites hold through a Pause while an ordinary
  site block still lifts; a locked rule shows no toggle and no delete anywhere; an override lifts
  exactly that rule and re-arms at the end with Detoxo force-stopped; a host on both the blocklist
  and the 18+ set shows no Unblock button; Settings → Reset app data leaves no grants and no ledger.

## Source files

- `lib/features/limits/unblock/**`
- `lib/features/limits/limits.dart`
- `lib/features/limits/rules/domain/entities/{rule,rule_snapshot}.dart` (`locked`, `lockScope`, `isStrict`, `RuleStatus.liftedUntilMs`)
- `lib/features/limits/rules/domain/usecases/{lock_guard,resolve_snapshot,rule_summary}.dart`
- `lib/features/limits/rules/domain/rule_sync.dart` (the ledger leg)
- `lib/features/limits/rules/presentation/{rules_cubit,rules_screen,rule_editor_screen}.dart`
- `lib/features/limits/web_blocker/domain/entities/web_block_entry.dart` (`pausedUntil` removed)
- `lib/features/limits/web_blocker/domain/web_block_sync.dart`, `presentation/{web_block_cubit,web_block_screen}.dart`
- `lib/features/limits/app_blocker/presentation/app_block_screen.dart` (the per-row Allow action)
- `lib/core/storage/local_store.dart` (`temporaryUnblocks`, `bypassLedger`)
- `lib/core/constants/channel_constants.dart`, `lib/core/platform_channels/engine_channel.dart`
- `lib/features/blocking/shared/domain/repositories/blocking_repositories.dart`, `.../data/repositories/engine_repository_impl.dart`
- `lib/core/di/injector.dart`, `lib/main.dart`, `lib/app/{bootstrap,app_resume_sync}.dart`
- `lib/core/navigation/app_router.dart` (`appNavigatorKey` — the sheet's way to the Navigator)
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/UnblockRegistry.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/WebBlockEngine.kt` (`pausedUntil` removed, `matchesAdult`)
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/RuleEngine.kt` (`blockingForHost(strictOnly)`, `hasStrictHostRules`)
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/ConfigStore.kt` (`temporary_unblocks_json`, `pending_unblock`)
- `android/app/src/main/kotlin/com/errorxperts/detoxo/channels/CommandHandler.kt` (`pushTemporaryUnblocks`, `takePendingUnblock`)
- `android/app/src/main/kotlin/com/errorxperts/detoxo/accessibility/DetoxoAccessibilityService.kt` (the four check sites, `refreshTemporaryUnblocks`, the browser re-gate, the `offersUnblock` producers, `foregroundReelUnblocked`)
- `android/app/src/main/kotlin/com/errorxperts/detoxo/overlay/BlockScreenOverlay.kt` (the `ACTION_UNBLOCK` branch)
- `android/app/src/test/kotlin/com/errorxperts/detoxo/engine/{UnblockRegistryTest,RuleEngineTest}.kt`
- `test/{temporary_unblock_test,override_quota_test,pending_unblock_test,rules_engine_test,web_blocker_test,web_block_screen_semantics_test}.dart`
- `integration_test/blockers_e2e_test.dart`
