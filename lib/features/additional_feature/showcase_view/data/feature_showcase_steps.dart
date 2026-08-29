import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/features/additional_feature/showcase_view/domain/showcase_step.dart';
import 'package:detoxo/gen/assets.gen.dart';
import 'package:flutter/widgets.dart';

/// Long-lived [GlobalKey]s for the seven showcase targets.
///
/// They are `static final` (one instance for the app's lifetime) because only a
/// single `DashboardTab` is ever mounted at a time — recreating them per build,
/// or having two live simultaneously, would trip Flutter's duplicate-GlobalKey
/// assertion.
abstract final class FeatureShowcaseKeys {
  static final blockAll = GlobalKey(debugLabel: 'showcase.blockAll');
  static final conscious = GlobalKey(debugLabel: 'showcase.conscious');
  static final pause = GlobalKey(debugLabel: 'showcase.pause');
  static final oneReel = GlobalKey(debugLabel: 'showcase.oneReel');
  static final unblock = GlobalKey(debugLabel: 'showcase.unblock');
  static final appBlocker = GlobalKey(debugLabel: 'showcase.appBlocker');
  static final webBlocker = GlobalKey(debugLabel: 'showcase.webBlocker');

  /// Tour order — passed verbatim to `startShowCase`.
  static List<GlobalKey> get ordered => [
    blockAll,
    conscious,
    pause,
    oneReel,
    unblock,
    appBlocker,
    webBlocker,
  ];
}

/// Total number of steps (used for the tooltip's "N of M" progress dots).
const int featureShowcaseStepCount = 7;

/// The ordered content for the seven steps.
///
/// Index 0–4 (the five mode pills) MUST stay aligned with the dashboard's
/// `DashboardMode` order — Block All, Conscious, Pause, One Reel, Unblock — since
/// `ModeSelector.showcaseBuilder` wraps mode `i` with `featureShowcaseSteps[i]`.
/// Index 5–6 are the App Blocker / Web Blocker capsules.
final List<ShowcaseStep> featureShowcaseSteps = [
  ShowcaseStep(
    key: FeatureShowcaseKeys.blockAll,
    image: Assets.images.illustration.block.path,
    tone: AppTone.danger,
    title: 'Block All',
    body:
        'Total focus. Every distracting app and reel is blocked the moment you '
        'open it — no exceptions.',
  ),
  ShowcaseStep(
    key: FeatureShowcaseKeys.conscious,
    image: Assets.images.illustration.conscious.path,
    tone: AppTone.accent,
    title: 'Conscious',
    body:
        'Earn your scroll. Stay off reels to bank time, then spend it mindfully '
        'whenever you choose.',
  ),
  ShowcaseStep(
    key: FeatureShowcaseKeys.pause,
    image: Assets.images.illustration.pause.path,
    tone: AppTone.warning,
    title: 'Pause',
    body:
        'Need a breather? Pause protection for a set window — everything is '
        'allowed, then blocking resumes automatically.',
  ),
  ShowcaseStep(
    key: FeatureShowcaseKeys.oneReel,
    image: Assets.images.illustration.oneReel.path,
    tone: AppTone.accent,
    title: 'One Reel',
    body:
        'One and done. Watch a single reel, then Detoxo locks straight back to '
        'your base mode. Looping or quick-scrolling won’t cost extra — a reel '
        'only unlocks once you’ve watched it a couple of seconds.',
  ),
  ShowcaseStep(
    key: FeatureShowcaseKeys.unblock,
    image: Assets.images.illustration.unlock.path,
    tone: AppTone.success,
    title: 'Unblock',
    body:
        'Pick a number. Unlock a few reels (2–20) with the dial, watch them, '
        'then blocking returns to your base mode on its own. The bubble counts '
        'down how many you have left.',
  ),
  ShowcaseStep(
    key: FeatureShowcaseKeys.appBlocker,
    image: Assets.images.illustration.appBlock.path,
    tone: AppTone.accent,
    title: 'App Blocker',
    body:
        'Choose exactly which apps Detoxo guards. Tap any time to manage your '
        'blocked apps.',
  ),
  ShowcaseStep(
    key: FeatureShowcaseKeys.webBlocker,
    image: Assets.images.illustration.webBlock.path,
    tone: AppTone.success,
    title: 'Web Blocker',
    body:
        'Block distracting and adult websites right in your browser — no VPN '
        'required.',
  ),
];
