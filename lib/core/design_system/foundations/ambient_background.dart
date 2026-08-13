import 'dart:ui';

import 'package:detoxo/core/design_system/foundations/background_scope.dart';
import 'package:detoxo/core/design_system/theme/app_theme.dart';
import 'package:detoxo/core/design_system/tokens/app_blur.dart';
import 'package:detoxo/core/design_system/tokens/app_colors.dart';
import 'package:detoxo/core/design_system/tokens/app_gradients.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Full-screen ambient background behind each screen's glass. ONE cheap paint
/// layer (no per-card blur) so glass surfaces above it have something real to
/// blur. The active background comes from [BackgroundScope]; it resolves to
/// either the theme-aware "Aurora" (a gradient + soft brand "mesh" blobs) or an
/// SVG gradient background chosen for the current brightness. Place a single
/// instance behind each screen via [GlassScaffold].
class AmbientBackground extends StatelessWidget {
  const AmbientBackground({
    required this.child,
    this.animated = true,
    super.key,
  });

  final Widget child;

  /// Subtle motion (blob drift / shader animation). Disabled automatically
  /// under reduced-motion.
  final bool animated;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final drift = animated && !reduceMotion;
    final brightness = Theme.of(context).brightness;
    final assetKey = svgAssetFor(BackgroundScope.of(context, brightness));
    final gradient = _auroraGradient(brightness);

    return Stack(
      fit: StackFit.expand,
      children: [
        if (assetKey == null)
          _aurora(brightness: brightness, gradient: gradient, drift: drift)
        else
          // The base gradient fills before the SVG paints (no flash);
          // BoxFit.cover keeps the gradient angle and covers tall screens.
          DecoratedBox(
            decoration: BoxDecoration(gradient: gradient),

            child: ImageFiltered(
              // Heavy abstract blur so the SVG reads as ambient light, not a picture.
              imageFilter: ImageFilter.blur(sigmaX: 70, sigmaY: 70),
              child: Opacity(
                opacity: 0.7,
                child: SvgPicture.asset(assetKey, fit: BoxFit.cover),
              ),
            ),
          ),
        child,
      ],
    );
  }

  /// Theme-aware base gradient + drifting brand blobs (the default background).
  Widget _aurora({
    required Brightness brightness,
    required Gradient gradient,
    required bool drift,
  }) {
    final isDark = brightness == Brightness.dark;

    Widget blob({
      required Alignment align,
      required Color color,
      required double size,
    }) {
      Widget b = Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [color, color.withValues(alpha: 0)]),
        ),
      );
      if (drift) {
        b = b
            .animate(onPlay: (c) => c.repeat(reverse: true))
            .move(
              begin: Offset.zero,
              end: const Offset(24, -28),
              duration: 6.seconds,
              curve: Curves.easeInOut,
            );
      }
      return Align(alignment: align, child: b);
    }

    // Light blobs are far fainter so the pale base stays clean and text-safe;
    // dark keeps the richer, more saturated glow.
    final c1 = AppColors.seed.withValues(alpha: isDark ? 0.40 : 0.16);
    final c2 = AppColors.accent.withValues(alpha: isDark ? 0.32 : 0.14);
    final c3 = AppColors.seed.withValues(alpha: isDark ? 0.30 : 0.12);

    return DecoratedBox(
      decoration: BoxDecoration(gradient: gradient),
      child: RepaintBoundary(
        child: Stack(
          fit: StackFit.expand,
          children: [
            blob(align: const Alignment(-0.9, -1.1), color: c1, size: 460),
            blob(align: const Alignment(1.2, -0.2), color: c2, size: 380),
            blob(align: const Alignment(-0.3, 1.3), color: c3, size: 420),
          ],
        ),
      ),
    );
  }
}

/// Base gradient behind the Aurora blobs (and the shader load/fallback fill):
/// deep navy in dark, a soft near-white wash in light.
Gradient _auroraGradient(Brightness brightness) => brightness == Brightness.dark
    ? AppGradients.ambient
    : const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        // Soft, faintly-cool wash aligned to the light scheme surfaces.
        colors: [Color(0xFFF9FAFE), Color(0xFFEDF0FA), Color(0xFFE3E8F5)],
        stops: [0.0, 0.5, 1.0],
      );

/// Standard screen chrome: a transparent [Scaffold] layered over an
/// [AmbientBackground]. Flagship screens return this instead of a raw Scaffold.
class GlassScaffold extends StatelessWidget {
  const GlassScaffold({
    required this.body,
    this.appBar,
    this.bottomBar,
    this.floatingActionButton,
    this.endDrawer,
    this.scaffoldKey,
    this.drawerScrimColor,
    this.endDrawerEnableOpenDragGesture = true,
    this.extendBody = true,
    this.animatedBackground = true,
    this.safeArea = true,
    super.key,
  });

  final Widget body;
  final PreferredSizeWidget? appBar;
  final Widget? bottomBar;
  final Widget? floatingActionButton;

  /// An optional right-side ([endDrawer]) panel. Pass [scaffoldKey] so callers
  /// can open it via `scaffoldKey.currentState?.openEndDrawer()`.
  final Widget? endDrawer;
  final Key? scaffoldKey;
  final Color? drawerScrimColor;
  final bool endDrawerEnableOpenDragGesture;

  final bool extendBody;
  final bool animatedBackground;
  final bool safeArea;

  @override
  Widget build(BuildContext context) {
    final hasAppBar = appBar != null;
    // The app bar already clears the status bar, so only inset the top when
    // there's no app bar; the bottom bar handles its own bottom inset.
    final content = safeArea
        ? SafeArea(top: !hasAppBar, bottom: bottomBar == null, child: body)
        : body;
    return AmbientBackground(
      animated: animatedBackground,
      child: Scaffold(
        key: scaffoldKey,
        backgroundColor: Colors.transparent,
        extendBody: extendBody,
        // extendBodyBehindAppBar stays at its default (false) so the body sits
        // below the frosted app bar instead of being hidden behind it.
        appBar: appBar,
        bottomNavigationBar: bottomBar,
        floatingActionButton: floatingActionButton,
        endDrawer: endDrawer,
        drawerScrimColor: drawerScrimColor,
        endDrawerEnableOpenDragGesture: endDrawerEnableOpenDragGesture,
        body: content,
      ),
    );
  }
}

/// A frosted top app bar that blurs the ambient gradient behind it.
class GlassAppBar extends StatelessWidget implements PreferredSizeWidget {
  const GlassAppBar({
    this.title,
    this.actions,
    this.leading,
    this.globalActions = true,
    super.key,
  });

  final Widget? title;
  final List<Widget>? actions;
  final Widget? leading;

  /// Whether to append the app-wide [globalActionsBuilder] actions (the global
  /// feedback button). Set `false` on screens that provide their own copy of a
  /// global action — e.g. the feature tutorial, which supplies a *keyed*
  /// feedback button so its coach-mark can spotlight it without a duplicate.
  final bool globalActions;

  /// App-wide trailing actions appended to *every* [GlassAppBar] after the
  /// screen's own [actions] (e.g. the global feedback button). Registered once
  /// at startup via a builder so the design system stays decoupled from feature
  /// code — the design system just invokes it; the feature decides what to show.
  static List<Widget> Function(BuildContext context)? globalActionsBuilder;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final globals = globalActions
        ? (globalActionsBuilder?.call(context) ?? const <Widget>[])
        : const <Widget>[];
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: AppBlur.bar, sigmaY: AppBlur.bar),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: context.glass.border)),
          ),
          child: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            title: title,
            actions: [...?actions, ...globals],
            leading: leading,
          ),
        ),
      ),
    );
  }
}

/// A frosted bottom bar wrapping its [child] (e.g. an adaptive tab bar). One
/// backdrop for the whole bar — never one per item. Pass `enableBlur: false`
/// when the child is itself a native blurred surface (iOS CNTabBar).
class GlassBottomBar extends StatelessWidget {
  const GlassBottomBar({
    required this.child,
    this.enableBlur = true,
    super.key,
  });

  final Widget child;
  final bool enableBlur;

  @override
  Widget build(BuildContext context) {
    final bar = DecoratedBox(
      decoration: BoxDecoration(
        color: enableBlur ? context.glass.fillTop : Colors.transparent,
        border: Border(top: BorderSide(color: context.glass.border)),
      ),
      child: SafeArea(top: false, child: child),
    );
    if (!enableBlur) return bar;
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: AppBlur.bar, sigmaY: AppBlur.bar),
        child: bar,
      ),
    );
  }
}
