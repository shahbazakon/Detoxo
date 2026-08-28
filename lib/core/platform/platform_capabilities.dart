import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;

/// Single source of truth for what the current platform can actually do.
///
/// The native blocking engine is an Android accessibility service; iOS has no
/// equivalent (it would need Apple's Screen Time / FamilyControls entitlement —
/// a separate effort). The UI reads these flags to hide/disable Android-only
/// affordances on iOS and show an honest "preview" state instead of dead
/// controls or crashes on missing platform channels.
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
