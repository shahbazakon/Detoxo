# EVO-016 — Narrow the accessibility event mask to the three used types

- Status: done (implemented on `sensitive_protection`, commit pending — DEVICE QA OUTSTANDING)
- Tier: 2 (enhancement; engine-config retune per Guardrail 8) — approved by the
  user in-session ("I approved all", 2026-08-27)
- Feature: android res/xml (accessibility_service_config.xml)
- Commit: fb23a68 (proposal-time HEAD; implementation uncommitted at authoring)
- Date: 2026-08-27
- Effort: S (one line + a device QA session)

## Why
`accessibility_service_config.xml` requested `typeAllMask`, but the service
acts on exactly three event types: `TYPE_WINDOW_STATE_CHANGED` (foreground
tracking, whole-app blocks, browser gate), `TYPE_WINDOW_CONTENT_CHANGED`
(detection + browser URL reads) and `TYPE_VIEW_SCROLLED` (reel-advance +
counting). The XML's own comment named those three. Every other type was
binder-delivered only to be discarded at the handler's first lines — battery
cost that feeds the OEM force-stop cycle (the original "stops working after a
few days" complaint).

## Expected user impact
Lower background battery draw → fewer OEM kills → protection stays alive
longer. Indirect but aimed at the top real-world failure mode.

## Technical complexity
One XML attribute:
`android:accessibilityEventTypes="typeWindowStateChanged|typeWindowContentChanged|typeViewScrolled"`.
Applies when the service (re)binds.

## Performance impact
Fewer event deliveries per scroll session; unquantified until a device perf
run (`bash tool/qa.sh -d <serial> perf` vs the pre-change baseline).

## Business value
Reliability of the in-the-moment intervention loop (product overview: "runs
quietly, always on").

## Rejected alternative
Keep `typeAllMask` and early-return faster — still pays binder delivery and
process wakeups for every discarded type.

## Rollback
Restore `typeAllMask` in the XML. No data involved. Note: the whole-app-block
foreground anchor comment in `DetoxoAccessibilityService.kt` assumes
notification-type events may arrive — the guard stays correct under either
mask.

## Device QA checklist (required before release)
- [ ] Reel detection + blocking still fire in each catalog app (Layer 2b
      `blocking` smoke: expect the `blocked <id> in <pkg> via <mode>` line).
- [ ] Foreground tracking: protected-app entry instantly freezes counting;
      whole-app block bounces on open AND while inside the app.
- [ ] Browser leg: blocked host back-out still triggers on address-bar change.
- [ ] Usage-time accrual (dashboard ring) does not visibly undercount during
      active scrolling.
- [ ] Perf layer vs baseline: no regression; ideally fewer missed frames.
