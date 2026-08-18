# EVO-013 — Honest protection status when the OS kills the service

- Status: done — implemented 2026-08-17; on-device 2026-08-18: after force-stop the app shows the permission gate, not a false "Active" (Realme now nulls the settings string on force-stop, so the gate catches it before `serviceAlive` is consulted; the string-intact-but-dead path this proposal targets is locked in by test/service_status_test.dart and was not reproducible tonight). "Active & Optimized" with the service live confirms the alive path. Commit pending
- Tier: 2 (enhancement) — approved by user in-conversation 2026-08-17
- Feature: blocking/engine + core/platform_channels + native CommandHandler (app-wide, discovered via web_blocker device testing)
- Commit: c0c5251
- Date: 2026-08-17
- Effort: S

## Why
Verified on a Realme (ColorOS) device 2026-08-17: force-stop kills the accessibility
service and **neither the OS nor an app relaunch rebinds it** — only a manual Settings
re-toggle. Meanwhile `EngineRepositoryImpl.currentStatus()`
(`engine_repository_impl.dart:98-108`) keys "running" off
`isAccessibilityEnabled()` — the Settings.Secure string, which still lists the service.
The Protection Status card shows "Active & Optimized" while every blocker (reels, apps,
web) is dead.

## Expected user impact
The home card tells the truth: enabled-but-dead renders the existing danger state with
its "Enable now" CTA (which opens accessibility settings — exactly where the re-toggle
happens). Closes the silent failure of the core promise ("keeps protecting you even
when Detoxo is closed" — product overview, "Runs quietly, always on").

## Technical complexity
One new channel method `serviceAlive` (native: `DetoxoAccessibilityService.instance !=
null`), consumed by `currentStatus()`: running = enabled **and** alive. No storage, no
manifest, no new UI (the card's stopped state already exists).

## Performance impact
One extra binder call on status refresh (app open / resume). Nothing on the hot path.

## Business value
Retention-critical reliability; the top real-world failure mode found in device
testing. Cites product overview "Runs quietly, always on".

## Rejected alternative
Periodic AlarmManager watchdog posting a notification while the app is closed — covers
the "user never reopens the app" gap, but adds background wakeups + notification
plumbing; workmanager is a pubspec-rejected dependency. Documented ceiling: detection
happens on app open/resume only. Upgrade path: AlarmManager receiver check.

## Rollback
Remove the `serviceAlive` branch + the `&& alive` term. No persisted state.

## Implementation Plan

### Current state
- `channel_constants.dart` ChannelMethods: no `serviceAlive`.
- `CommandHandler.kt` `when`: no such branch.
- `engine_repository_impl.dart:98-108`: `status: enabled ? running : stopped`.

### Target state
- `ChannelMethods.serviceAlive = 'serviceAlive'`; `EngineChannel.serviceAlive()` →
  `invokeBool`.
- `CommandHandler.kt`: `"serviceAlive" -> result.success(DetoxoAccessibilityService.instance != null)`.
- `currentStatus()`: `final alive = await _channel.serviceAlive();`
  `status: (enabled && alive) ? running : stopped`.
- `ProtectionStatusCard` unchanged (its `!running` branch + CTA already fit).

### Steps
1. Add the constant, the `EngineChannel` method, the native branch.
2. Change `currentStatus()` to require both.
3. Test: mocked channel — enabled+dead → stopped; enabled+alive → running.

### Boundaries
Do not change `isAccessibilityEnabled` semantics (the permissions funnel and
restricted-settings recovery depend on it). If cited lines drifted from c0c5251, stop
and report.

### Validation
- [ ] `bash tool/dev.sh precommit`
- [ ] Manual device: force-stop → relaunch → card shows "Protection off" with CTA;
      re-toggle → card returns to running
- [ ] `/docs-sync`
