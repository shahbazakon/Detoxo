/// Single import surface for the Detoxo design system: tokens, theme,
/// foundations, adaptive controls and reusable components.
library;

// Motion engine — re-exported so screens get `.animate()` / `.ms` / `.seconds`.
export 'package:flutter_animate/flutter_animate.dart';

// Adaptive
export 'adaptive/adaptive_controls.dart';
export 'adaptive/platform_adaptive.dart';
// Components
export 'components/app_icon_avatar.dart';
export 'components/badges.dart';
export 'components/buttons.dart';
export 'components/cards.dart';
export 'components/dialog.dart';
export 'components/feedback.dart';
export 'components/inputs.dart';
export 'components/list_tiles.dart';
export 'components/overlays.dart';
export 'components/permission_card.dart';
export 'components/selection.dart';
export 'components/toggle.dart';
export 'components/variant_carousel.dart';
// Foundations
export 'foundations/ambient_background.dart';
export 'foundations/animated_icons.dart';
export 'foundations/background_scope.dart';
export 'foundations/glass_container.dart';
export 'foundations/liquid_glass_border.dart';
export 'foundations/motion.dart';
// Typography + theme
export 'theme/app_theme.dart';
// Tokens
export 'tokens/app_blur.dart';
export 'tokens/app_colors.dart';
export 'tokens/app_elevation.dart';
export 'tokens/app_gradients.dart';
export 'tokens/app_motion.dart';
export 'tokens/app_spacing.dart';
export 'typography/app_typography.dart';
