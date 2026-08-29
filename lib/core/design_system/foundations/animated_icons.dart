import 'package:detoxo/core/design_system/tokens/app_motion.dart';
import 'package:flutter/material.dart';
import 'package:not_static_icons/not_static_icons.dart';

// Re-export the controller so screens can drive animations without importing
// the package directly — this file is the project's ONLY `not_static_icons`
// import surface (mirrors how adaptive_controls.dart owns `cupertino_native`).
export 'package:not_static_icons/not_static_icons.dart'
    show AnimatedIconController;

/// Semantic catalogue of the app's animated icons, decoupled from the concrete
/// `not_static_icons` (Lucide) class names. Call sites reference these names;
/// swapping a glyph only touches [_iconBuilders] below.
enum AppIcon {
  dashboard,
  blocklist,
  more,
  appBlocker,
  websiteBlocker,
  dailyLimit,
  activity,
  pinLock,
  settings,
  premium,
  pause,
  tune,
  backspace,
  check,
  info,
  ban,
  statusOff,
  shieldCheck,
  oneReel,
  unblock,
  rules,
}

/// Every `not_static_icons` widget extends `AnimatedSVGIcon` and shares this
/// constructor shape, so the catalogue is a plain lookup of constructor
/// tear-offs rather than a 20-arm switch.
typedef _IconCtor =
    AnimatedSVGIcon Function({
      double size,
      Color? color,
      Color? hoverColor,
      Duration animationDuration,
      double strokeWidth,
      bool infiniteLoop,
      bool interactive,
      AnimatedIconController? controller,
      VoidCallback? onTap,
    });

final Map<AppIcon, _IconCtor> _iconBuilders = {
  AppIcon.dashboard: CircleGaugeIcon.new,
  AppIcon.blocklist: BanIcon.new,
  AppIcon.more: EllipsisIcon.new,
  AppIcon.appBlocker: Grid2x2Icon.new,
  AppIcon.websiteBlocker: EarthLockIcon.new,
  AppIcon.dailyLimit: ClockFadingIcon.new,
  AppIcon.activity: ChartColumnIncreasingIcon.new,
  AppIcon.pinLock: DoorClosedLockedIcon.new,
  AppIcon.settings: CogIcon.new,
  AppIcon.premium: CrownIcon.new,
  AppIcon.pause: CirclePauseIcon.new,
  AppIcon.tune: BoltIcon.new,
  AppIcon.backspace: DeleteIcon.new,
  AppIcon.check: CircleCheckIcon.new,
  AppIcon.info: BadgeInfoIcon.new,
  AppIcon.ban: BanIcon.new,
  AppIcon.statusOff: CircleAlertIcon.new,
  AppIcon.shieldCheck: BrickWallShieldIcon.new,
  AppIcon.oneReel: CirclePlayIcon.new,
  AppIcon.unblock: DoorOpenIcon.new,
  AppIcon.rules: CalendarClockIcon.new,
};

/// Interactive animated icon with app-standard styling, a single entry point
/// for every screen, and built-in reduce-motion safety.
///
/// Triggers (combinable):
/// - [playOnAppear] — plays the morph once on mount, optionally after
///   [appearDelay] (for staggered lists).
/// - [loop] — runs the morph continuously (ambient surfaces, e.g. empty states).
/// - [interactive] — the icon replays on its own tap. Keep `false` inside
///   tiles / buttons / the navbar, where a parent owns the gesture and drives
///   the shared [controller]; only standalone icons should set it `true`.
///
/// Pass a [controller] when an owning widget (navbar item, CTA, tile) needs to
/// replay the morph on its own tap/selection.
class AppAnimatedIcon extends StatefulWidget {
  const AppAnimatedIcon({
    required this.icon,
    this.size = 22,
    this.color,
    this.playOnAppear = false,
    this.appearDelay = Duration.zero,
    this.loop = false,
    this.interactive = false,
    this.controller,
    this.onTap,
    super.key,
  });

  final AppIcon icon;
  final double size;
  final Color? color;
  final bool playOnAppear;
  final Duration appearDelay;
  final bool loop;
  final bool interactive;
  final AnimatedIconController? controller;
  final VoidCallback? onTap;

  @override
  State<AppAnimatedIcon> createState() => _AppAnimatedIconState();
}

class _AppAnimatedIconState extends State<AppAnimatedIcon> {
  late final AnimatedIconController _controller;
  // Only disposed when this widget created it; an injected controller is the
  // owner's responsibility.
  AnimatedIconController? _owned;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? (_owned = AnimatedIconController());
    if (widget.playOnAppear || widget.loop) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _kickoff());
    }
  }

  void _kickoff() {
    if (!mounted) return;
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return;
    if (widget.appearDelay == Duration.zero) {
      _controller.animate();
    } else {
      Future<void>.delayed(widget.appearDelay, () {
        if (mounted) _controller.animate();
      });
    }
  }

  @override
  void dispose() {
    _owned?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final builder = _iconBuilders[widget.icon]!;
    return builder(
      size: widget.size,
      color: widget.color,
      // Match hover/press tint to the base colour so interactive icons don't
      // flash the package's default grey while being pressed.
      hoverColor: widget.color,
      strokeWidth: 2.0,
      animationDuration: AppDurations.normal,
      infiniteLoop: widget.loop && !reduceMotion,
      interactive: widget.interactive && !reduceMotion,
      controller: _controller,
      onTap: widget.onTap,
    );
  }
}
