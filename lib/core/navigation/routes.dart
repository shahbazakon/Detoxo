/// Centralised route paths for go_router.
///
/// EVERY constant here is a path and must resolve to a registered route —
/// `test/routes_registered_test.dart` reads this file and asserts it, because
/// three of these (`/pause`, `/curious`, `/unsupported`) once sat here declared
/// and unregistered, failing at runtime for anyone who navigated to them.
/// Anything that is not a path (a query-parameter name, say) belongs elsewhere.
abstract final class Routes {
  static const String splash = '/';
  static const String onboarding = '/onboarding';
  static const String permissions = '/permissions';
  static const String home = '/home';
  static const String pinSetup = '/pin/setup';
  static const String pinLock = '/pin/lock';
  static const String settings = '/settings';
  static const String webBlock = '/web-block';
  static const String webProtection = '/web-block/protection';
  static const String appBlock = '/app-block';
  static const String protectedApps = '/protected-apps';
  static const String dailyLimit = '/daily-limit';
  static const String rules = '/rules';
  static const String ruleEditor = '/rules/edit';
  static const String analytics = '/analytics';
  static const String appearance = '/appearance';
  static const String bubbleStyle = '/content-counter/bubble';
  static const String homeWidget = '/content-counter/widget';
  static const String blockScreenStyle = '/block-screen/style';
  static const String help = '/help';
  static const String helpFaq = '/help/faq';
  static const String featureTutorial = '/help/tutorial';
  static const String shareIdeas = '/help/share-ideas';
  static const String privacyPolicy = '/help/legal/privacy';
  static const String termsConditions = '/help/legal/terms';

  /// Reached by the router's redirect when the platform cannot block at all.
  static const String unsupported = '/unsupported';
}
