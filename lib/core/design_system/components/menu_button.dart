import 'package:flutter/material.dart';

/// identical: a primary-tinted circle with a [Icons.menu_rounded] glyph.
///
/// Lives in the design system rather than under the dashboard because three
/// features draw it; reaching into `dashboard/presentation/` for it was a
/// boundary violation the gate could not see (2026-09-06).
class DrawerMenuButton extends StatelessWidget {
  const DrawerMenuButton({required this.onTap, super.key});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: 'Menu',
      child: GestureDetector(
        // child: FenceIcon(
        //   size: 20.0, // Icon size
        //   color: Colors.white, // Default color
        //   hoverColor: Colors.blue, // Hover color
        //   animationDuration: Duration(milliseconds: 600), // Animation duration
        //   strokeWidth: 2.0, // Stroke width
        //   reverseOnExit: true, // Reverse animation on exit
        //   enableTouchInteraction: true, // Enable touch interaction
        //   infiniteLoop: false, // Enable infinite loop
        //   onTap: onTap == null
        //       ? null
        //       : () {
        //           AppHaptics.selection();
        //           onTap!();
        //         }, // Tap callback
        //   interactive: true, // Enable/disable internal gestures
        //   controller: AnimatedIconController(), // External animation controller
        // ),
        child: Icon(Icons.view_sidebar_rounded, size: 22, color: scheme.primary),
      ),
    );
  }
}
