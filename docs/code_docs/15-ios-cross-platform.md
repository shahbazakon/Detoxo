# iOS / Cross-Platform Reality

Detoxo is an **Android-only product**. iOS (and web, and the Dart test host) run the
same Flutter UI, but the blocking/counting engine simply does not exist there — and
cannot, without a fundamentally different Apple-sanctioned mechanism. This doc explains
*why*, how the codebase degrades gracefully instead of crashing, what the user sees on an
unsupported platform, and what an iOS build would *theoretically* have to do (framed
honestly as **not implemented**).

If you only remember one thing: **there is exactly one capability gate**,
`PlatformCapabilities`, and every Android-specific code path defers to it.

---

## 1. Why iOS is unsupported

The entire product depends on Android's **AccessibilityService**. That service is what
lets Detoxo:

- read the on-screen view tree of *other* apps (Instagram, YouTube, Snapchat, browsers…),
- match a Reels/Shorts container by view-id (see [03-detection-engine.md](03-detection-engine.md)),
- and press the system Back button / kill / lock in response.

See [04-native-android-layer.md](04-native-android-layer.md) for how that service is wired
(`DetoxoAccessibilityService.kt`).

**iOS has no equivalent.** By design, iOS sandboxes every app: one app cannot inspect
another app's UI hierarchy, cannot synthesize a global "back" gesture, and cannot kill or
lock a foreground app. There is no AccessibilityService, no `performGlobalAction`, no
`WindowManager` overlay over arbitrary apps, no `UsageStats`, no device-admin `lockNow`.
Every primitive the engine is built on is Android-only. Porting the *implementation* is not
possible; a real iOS build would be a **separate product** built on Apple's Screen Time
stack (see §6).

This is stated in-code at the top of `platform_capabilities.dart`:

> "The native blocking engine is an Android accessibility service; iOS has no equivalent
> (it would need Apple's Screen Time / FamilyControls entitlement — a separate effort)."

---

## 2. The single capability gate: `PlatformCapabilities`

`lib/core/platform/platform_capabilities.dart` is the **single source of truth** for what
the current platform can actually do. It is an `abstract final class` (pure static
namespace — never instantiated) exposing boolean getters.

```dart
abstract final class PlatformCapabilities {
  /// Test-only override: forces Android capabilities on the host test runner
  /// so channel-backed repositories can be exercised in unit tests.
  @visibleForTesting
  static bool? debugForceAndroid;

  static bool get _isAndroid =>
      debugForceAndroid ?? (!kIsWeb && Platform.isAndroid);

  /// The native AccessibilityService blocking engine is Android-only.
  static bool get supportsBlockingEngine => _isAndroid;

  /// The Android runtime-permission funnel (accessibility, overlay, usage,
  /// battery, device-admin) only exists on Android.
  static bool get usesAndroidPermissionFunnel => _isAndroid;

  /// On iOS the app is UI-complete only; surface an honest "preview" state.
  static bool get isBlockingPreviewOnly => !_isAndroid;
}
```

`debugForceAndroid` is a `@visibleForTesting` escape hatch (null in production):
tests set it to `true` to exercise the channel-backed repositories on the host
runner, and reset it in `tearDown`.

| Getter | True when | Meaning |
| --- | --- | --- |
| `supportsBlockingEngine` | Android only | Native detection/blocking/counting engine is available; safe to call platform channels. |
| `usesAndroidPermissionFunnel` | Android only | The accessibility / overlay / usage / battery / device-admin permission funnel exists (see the permissions feature). |
| `isBlockingPreviewOnly` | **not** Android (iOS, web, tests) | App is UI-complete only; show an honest "preview" state instead of dead controls. |

### The `_isAndroid` predicate

```dart
static bool get _isAndroid =>
    debugForceAndroid ?? (!kIsWeb && Platform.isAndroid);
```

The test override wins when set; otherwise two guards, in order:

1. **`!kIsWeb` first.** On Flutter web, `dart:io`'s `Platform` throws — so the `kIsWeb`
   check short-circuits *before* `Platform.isAndroid` is ever evaluated. This is why the
   import is `import 'dart:io' show Platform;` guarded by `import 'package:flutter/foundation.dart' show kIsWeb;`.
2. **`Platform.isAndroid` second.** iOS, macOS, Windows, Linux, and the Dart VM test host
   all fall through to `false`.

The practical consequence: **iOS, web, and the plain Dart test runner are all treated
identically** — "no native engine." That is deliberate; it means widget/unit tests exercise
the same safe-default paths iOS uses, so the preview behavior is continuously tested even
though CI never runs on an iPhone.

---

## 3. How the engine channel degrades off-Android

`lib/core/platform_channels/engine_channel.dart` is the low-level wrapper over the native
command `MethodChannel` (`com.errorxperts.detoxo/commands`) and the engine `EventChannel`
(`com.errorxperts.detoxo/events`). It is the **only** place platform channels are touched,
and it consults `PlatformCapabilities.supportsBlockingEngine` at both entry points so *no
repository above it ever has to know the platform*.

### 3.1 Events stream → empty off-Android

```dart
Stream<Map<String, dynamic>> events() {
  if (!PlatformCapabilities.supportsBlockingEngine) {
    return const Stream<Map<String, dynamic>>.empty();
  }
  return _eventStream ??= _events.receiveBroadcastStream() ... ;
}
```

Off-Android the method returns `const Stream.empty()`. The inline comment explains why this
matters: *subscribing to the EventChannel would otherwise emit a logged error every
launch.* So on iOS, every consumer of `serviceStatus` / `detection` / `blocked` /
`webBlocked` / `foregroundChanged` / `consciousState` / `contentCounted` simply receives a
stream that never emits — no listeners fire, no errors, no crash.

### 3.2 Commands → short-circuit to safe defaults

Every command flows through the private `_invoke<T>`:

```dart
Future<T?> _invoke<T>(String method, [Map<String, dynamic>? args]) async {
  // No native engine off-Android: short-circuit so screens render with safe
  // defaults instead of paying a MissingPluginException round-trip per call.
  if (!PlatformCapabilities.supportsBlockingEngine) return null;
  try {
    return await _commands.invokeMethod<T>(method, args);
  } on PlatformException catch (e) {
    AppLogger.e('channel $method failed', e);
    return null;
  } on MissingPluginException {
    // Running on a platform without the native side (e.g. tests / iOS).
    return null;
  }
}
```

Off-Android `_invoke` returns `null` **without ever touching the channel**. The typed
convenience wrappers then coerce that `null` into a benign default:

| Wrapper | Off-Android result | Effect on UI |
| --- | --- | --- |
| `invokeBool(...)` | `false` | Permission checks (`isAccessibilityEnabled`, `canDrawOverlays`, `hasUsageAccess`, `isDeviceAdminActive`, `isIgnoringBattery`, `pinContentWidget`) all read "not granted / not supported". |
| `invokeVoid(...)` | no-op | Push/mutate commands (`pushConfig`, `pushSettings`, `pushWebBlocklist`, `performBack`, `killApp`, `lockScreen`, `setContentCounterEnabled`, `setCounterStyle`, `refreshContentWidget`, …) silently do nothing. |
| `invokeMap(...)` | `{}` (empty map) | Snapshots (`blockStats`, `consciousState`, `contentCounterSnapshot`) return empty; callers fall back to their own zero-defaults. |
| `installedPackages()` | `null` | Documented contract: `null` = "install state unknown", so the UI shows the **full** blocklist rather than filtering. |

Note the defense-in-depth: even *if* the capability gate were bypassed, the `try/catch`
still swallows `MissingPluginException` (thrown when no native side is registered) and
`PlatformException`, returning `null`. The comment on the `MissingPluginException` arm names
the two realistic cases explicitly: **tests / iOS**. So the app is robust in three layers —
the `PlatformCapabilities` short-circuit, the exception handlers, and the null-coercing
default in each wrapper.

---

## 4. The unsupported screen

`lib/app/unsupported_screen.dart` is the user-facing artifact of all of this. It is a
`StatelessWidget` that renders a single `EmptyState` (from `core/widgets/common_widgets.dart`):

```dart
class UnsupportedScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: SafeArea(
        child: EmptyState(
          icon: Icons.phonelink_erase,
          title: 'Detoxo runs on Android',
          subtitle:
              'The reel/short blocker relies on Android’s Accessibility Service, '
              'which has no equivalent on this platform. An iOS Screen Time / '
              'Family Controls version is a separate effort.',
        ),
      ),
    );
  }
}
```

Design notes:

- **Honest, not broken.** It does not disable buttons or throw; it explains *why* the
  platform can't run the core feature and names the would-be iOS path.
- **Copy is intentionally specific.** It names "Accessibility Service" (the missing
  primitive) and "Screen Time / Family Controls" (the Apple path), matching the code
  comments and this doc.
- **Icon:** `Icons.phonelink_erase`.

This is the "honest preview state" that `PlatformCapabilities.isBlockingPreviewOnly` is
meant to surface. Wherever the app routes an unsupported platform to a dead end, this is the
screen it shows.

> **Cross-reference correction:** The doc-comment in `unsupported_screen.dart` and in
> `platform_capabilities.dart` still points at `docs/15-ios-cross-platform.md`. This file is
> the current, canonical location (`docs/code_docs/15-ios-cross-platform.md`). Treat the
> in-code path as a stale relative reference — an infra/doc-sync follow-up, not a second
> document.

---

## 5. What the rest of the app already does about iOS

Because `PlatformCapabilities` is a plain static gate, the same three flags are reused
across the UI to hide or preview Android-only affordances instead of scattering
`Platform.isAndroid` checks everywhere:

- **Engine plumbing** — `EngineChannel` (§3) neutralizes both channels.
- **Permission funnel** — anything driven by `usesAndroidPermissionFunnel` (accessibility,
  overlay/"Display over apps", usage access, battery-optimization exemption, device admin)
  is Android-gated; on iOS none of these permissions exist and the funnel is skipped.
- **Preview state** — `isBlockingPreviewOnly` is the flag UI layers read to render the
  "preview" affordances / route to `UnsupportedScreen` rather than showing controls that
  would silently no-op.

Everything downstream (repositories, cubits, screens) can call the same command wrappers
unconditionally and get safe defaults, which keeps the platform branch confined to these
three getters.

---

## 6. What an iOS build could *theoretically* do — **not implemented**

There is **no iOS implementation** in this repo: no Swift engine, no `FamilyControls`
entitlement, no `DeviceActivityMonitor` extension, no App Store target beyond the default
Flutter iOS runner. The section below is a **planned / follow-up** sketch of the only
Apple-sanctioned route, for context — treat every item as aspirational.

Apple's equivalent surface is the **Screen Time API family** (iOS 15+):

| Apple framework | Rough analogue to Detoxo's Android mechanism | Reality on iOS |
| --- | --- | --- |
| **FamilyControls** | The "authorize this app to manage screen time" gate (analogous to enabling the AccessibilityService). Requires the special **Family Controls entitlement** from Apple. | Would need an entitlement request + review; gated by Apple. |
| **ManagedSettings** | Shielding/blocking apps & categories (analogous to PRESS_BACK / block modes). | Can *shield* whole apps/categories — **not** a specific Reels tab inside an app. |
| **DeviceActivity** (`DeviceActivityMonitor` extension) | Schedule- and threshold-based triggers (analogous to daily limits / the accountant loop). | Runs in a separate extension with tight time budgets. |

The hard ceiling — and the reason this is a *separate product*, not a port:

- iOS **cannot detect "the user is on the Reels tab specifically."** Screen Time operates at
  **whole-app / category granularity**. Detoxo's entire value — count and block *short-form
  feeds* while leaving DMs, search, and posting usable — has **no iOS analogue**. There is no
  view-tree access, so the 3-stage view-id detection ([03-detection-engine.md](03-detection-engine.md))
  and the decoupled content counter cannot be reproduced.
- No arbitrary **overlay over other apps** → no floating counter bubble
  (`ContentCounterBubble`) and no in-app "press back" nudge.
- No **UsageStats-style foreground polling**, no `killBackgroundProcesses`, no device-admin
  `lockNow`.
- The **Conscious** time-bank plan ("curious"/`CURIOUS` token internally; **"Conscious"** in
  the UI) and **one-reel grace** depend on frame-level, in-app detection that Screen Time
  cannot provide.

Net: a hypothetical iOS build would be a coarser "shield the whole app on a schedule" tool
sharing the Flutter UI shell and this repo's config/persistence, but with a different engine
and a materially reduced feature set. It is explicitly **out of scope** for the shipped
product.

---

## 7. Quick reference

- **Is there iOS support today?** No. UI renders; the engine is inert; `UnsupportedScreen`
  is the honest dead end.
- **Where is the platform branch?** Exactly one file: `lib/core/platform/platform_capabilities.dart`.
- **Where does the engine no-op?** `lib/core/platform_channels/engine_channel.dart` (empty
  event stream + `null`-returning `_invoke`).
- **Do tests hit native code?** No — the Dart test host is `!_isAndroid`, so it exercises the
  same safe-default paths iOS uses.
- **Could iOS ever match Android?** No — Screen Time is whole-app granularity; per-feed
  detection is impossible. A future iOS app would be a separate, coarser effort.

---

## Source files

- `lib/app/unsupported_screen.dart`
- `lib/core/platform/platform_capabilities.dart`
- `lib/core/platform_channels/engine_channel.dart`
- `lib/core/constants/channel_constants.dart` (channel names / command methods referenced)
- `lib/core/widgets/common_widgets.dart` (`EmptyState` used by the unsupported screen)
- `android/app/src/main/kotlin/com/errorxperts/detoxo/accessibility/DetoxoAccessibilityService.kt` (the Android-only primitive that has no iOS equivalent)
