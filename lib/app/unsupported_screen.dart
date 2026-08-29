import 'package:detoxo/core/design_system/design_system.dart';
import 'package:flutter/material.dart';

/// Shown on platforms (iOS) where the core AccessibilityService-based blocker
/// cannot run. See docs/15-ios-cross-platform.md for the FamilyControls path.
class UnsupportedScreen extends StatelessWidget {
  const UnsupportedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // GlassScaffold, like every other screen: the router now actually routes
    // here (its route was registered in M6), so this is the ONLY screen an
    // unsupported-platform user ever sees — a bare Material surface would be
    // the one place the app drops its own aesthetic.
    return const GlassScaffold(
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
