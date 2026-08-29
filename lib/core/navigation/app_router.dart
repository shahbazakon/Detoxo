import 'package:detoxo/app/splash_screen.dart';
import 'package:detoxo/app/unsupported_screen.dart';
import 'package:detoxo/core/constants/app_constants.dart';
import 'package:detoxo/core/di/injector.dart';
import 'package:detoxo/core/navigation/app_gate.dart';
import 'package:detoxo/core/navigation/routes.dart';
import 'package:detoxo/core/services/firebase/firebase.dart';
import 'package:detoxo/features/access_protection/presentation/pin_gate.dart';
import 'package:detoxo/features/access_protection/presentation/pin_lock_screen.dart';
import 'package:detoxo/features/access_protection/presentation/pin_setup_screen.dart';
import 'package:detoxo/features/additional_feature/appearance/presentation/appearance_screen.dart';
import 'package:detoxo/features/analytics/presentation/analytics_screen.dart';
import 'package:detoxo/features/blocking/block_screen/presentation/block_screen_style_screen.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/enums.dart';
import 'package:detoxo/features/content_counter/content_counter_appearance/presentation/bubble_style_screen.dart';
import 'package:detoxo/features/content_counter/content_counter_appearance/presentation/home_widget_screen.dart';
import 'package:detoxo/features/dashboard/presentation/home_shell.dart';
import 'package:detoxo/features/help/faq/presentation/faq_screen.dart';
import 'package:detoxo/features/help/feature_tutorial/presentation/feature_tutorial_screen.dart';
import 'package:detoxo/features/help/legal/presentation/legal_web_view_screen.dart';
import 'package:detoxo/features/help/presentation/help_screen.dart';
import 'package:detoxo/features/help/share_ideas/presentation/share_ideas_screen.dart';
import 'package:detoxo/features/limits/app_blocker/presentation/app_block_screen.dart';
import 'package:detoxo/features/limits/daily_limit/presentation/daily_limit_screen.dart';
import 'package:detoxo/features/limits/limits.dart';
import 'package:detoxo/features/limits/rules/presentation/rule_editor_screen.dart';
import 'package:detoxo/features/limits/rules/presentation/rules_screen.dart';
import 'package:detoxo/features/limits/web_blocker/presentation/web_block_screen.dart';
import 'package:detoxo/features/limits/web_blocker/presentation/web_protection_screen.dart';
import 'package:detoxo/features/onboarding/presentation/onboarding_screen.dart';
import 'package:detoxo/features/permissions/presentation/permissions_screen.dart';
import 'package:detoxo/features/protected_apps/presentation/protected_apps_screen.dart';
import 'package:detoxo/features/settings/presentation/settings_screen.dart';
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

/// App navigation graph.
///
/// Gating (unsupported platform / onboarding / PIN / permissions) is one
/// declarative `redirect` reading [AppGate]. It used to be an imperative
/// `context.go` chain inside the splash screen, duplicated again here for the
/// post-unlock hop — every new gate was another branch in a widget, off the
/// router.
/// The routed `Navigator`'s key.
///
/// `MaterialApp.router`'s `builder` runs ABOVE the Navigator, so a widget
/// mounted there has no `Navigator` in its own context and cannot push a route
/// or a bottom sheet. `PendingUnblockListener` (M8) lives exactly there — inside
/// the router so it can read the gate, above the Navigator so it survives route
/// changes — and reaches the sheet through this key.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

GoRouter buildRouter() => GoRouter(
  navigatorKey: appNavigatorKey,
  initialLocation: Routes.splash,
  // Logs `screen_view` on every route push (in-shell tabs log manually).
  observers: [sl<AnalyticsService>().navigatorObserver],
  // The gate notifies on every flag change, which re-runs the redirect below.
  refreshListenable: sl<AppGate>(),
  redirect: (_, state) => sl<AppGate>().redirect(state.matchedLocation),
  routes: [
    GoRoute(path: Routes.splash, builder: (_, _) => const SplashScreen()),
    GoRoute(
      path: Routes.onboarding,
      builder: (_, _) => const OnboardingScreen(),
    ),
    GoRoute(
      path: Routes.permissions,
      builder: (_, _) => const PermissionsScreen(),
    ),
    // One registration, one shell. `Routes.blocklist` used to build a SECOND
    // HomeShell here, which is how the two tabs came to share one navigation
    // stack; that constant is gone. A per-tab deep link is deliberately NOT
    // built: nothing in the app links to a tab, and a seam with no producer is
    // a speculative API that cannot be verified by use.
    GoRoute(path: Routes.home, builder: (_, _) => const HomeShell()),
    // The setup screen can change or disable the PIN, so the route itself is
    // gated — every entry point (settings tile, drawer shortcut, deep link)
    // passes the same guard. PinGuard short-circuits when the settings scope
    // isn't protected.
    GoRoute(
      path: Routes.pinSetup,
      builder: (_, _) =>
          const PinGuard(scope: PinScope.settings, child: PinSetupScreen()),
    ),
    // Launch gate. Unlocking just clears the flag — the redirect then applies
    // whatever gate comes next (a PIN user must still not skip permissions),
    // instead of this screen re-stating the order.
    GoRoute(
      path: Routes.pinLock,
      builder: (_, _) => PinLockScreen(onUnlocked: sl<AppGate>().unlockPin),
    ),
    GoRoute(
      path: Routes.unsupported,
      builder: (_, _) => const UnsupportedScreen(),
    ),
    GoRoute(path: Routes.settings, builder: (_, _) => const SettingsScreen()),
    GoRoute(path: Routes.webBlock, builder: (_, _) => const WebBlockScreen()),
    GoRoute(
      path: Routes.webProtection,
      builder: (_, _) => const WebProtectionScreen(),
    ),
    GoRoute(path: Routes.appBlock, builder: (_, _) => const AppBlockScreen()),
    GoRoute(
      path: Routes.protectedApps,
      builder: (_, _) => const ProtectedAppsScreen(),
    ),
    GoRoute(
      path: Routes.dailyLimit,
      builder: (_, _) => const DailyLimitScreen(),
    ),
    GoRoute(path: Routes.rules, builder: (_, _) => const RulesScreen()),
    // The editor takes its kind / rule through `extra`; a missing or foreign
    // extra (deep link, restored route) opens a blank schedule.
    GoRoute(
      path: Routes.ruleEditor,
      builder: (_, state) => RuleEditorScreen(
        args: switch (state.extra) {
          final RuleEditorArgs args => args,
          _ => const RuleEditorArgs(kind: RuleKind.schedule),
        },
      ),
    ),
    GoRoute(path: Routes.analytics, builder: (_, _) => const AnalyticsScreen()),
    GoRoute(
      path: Routes.appearance,
      builder: (_, _) => const AppearanceScreen(),
    ),
    GoRoute(
      path: Routes.bubbleStyle,
      builder: (_, _) => const BubbleStyleScreen(),
    ),
    GoRoute(
      path: Routes.homeWidget,
      builder: (_, _) => const HomeWidgetScreen(),
    ),
    GoRoute(
      path: Routes.blockScreenStyle,
      builder: (_, _) => const BlockScreenStyleScreen(),
    ),
    GoRoute(path: Routes.help, builder: (_, _) => const HelpScreen()),
    GoRoute(path: Routes.helpFaq, builder: (_, _) => const FaqScreen()),
    GoRoute(
      path: Routes.featureTutorial,
      builder: (_, _) => const FeatureTutorialScreen(),
    ),
    GoRoute(
      path: Routes.shareIdeas,
      builder: (_, _) => const ShareIdeasScreen(),
    ),
    GoRoute(
      path: Routes.privacyPolicy,
      builder: (_, _) => const LegalWebViewScreen(
        title: 'Privacy Policy',
        url: AppLegal.privacyPolicyUrl,
      ),
    ),
    GoRoute(
      path: Routes.termsConditions,
      builder: (_, _) => const LegalWebViewScreen(
        title: 'Terms & Conditions',
        url: AppLegal.termsUrl,
      ),
    ),
  ],
);
