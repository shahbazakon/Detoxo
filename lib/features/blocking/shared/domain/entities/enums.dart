// Central enums for the detection / blocking domain.
//
// Each enum carries the original wire token (the string used in
// `platforms_config.json` / settings) so JSON (de)serialization is explicit
// and resilient to ordering changes.

/// The user's active high-level blocking strategy.
enum BlockingPlan {
  blockAll('BLOCK_ALL'),
  curious('CURIOUS'),
  oneReel('ONE_REEL'),
  paused('PAUSED');

  const BlockingPlan(this.wire);
  final String wire;

  static BlockingPlan fromWire(String? v) => values.firstWhere(
    (e) => e.wire == v,
    orElse: () => BlockingPlan.blockAll,
  );
}

/// The plan's user-facing name — the one place a wire token becomes a label.
/// `BlockingPlan.curious` is the legacy wire for **Conscious** and must never
/// be shown; `oneReel` is "One Reel" for an allowance of 1 and "Unblock" for
/// more (the dashboard's rule). Null → '' (no chip on the block screen).
String planLabel(BlockingPlan? plan, {int allowance = 1}) => switch (plan) {
  null => '',
  BlockingPlan.curious => 'Conscious',
  BlockingPlan.oneReel => allowance <= 1 ? 'One Reel' : 'Unblock',
  BlockingPlan.blockAll => 'Block All',
  BlockingPlan.paused => 'Paused',
};

/// What happens when short content is detected.
enum BlockingMode {
  pressBack('PRESS_BACK'),
  killApp('KILL_APP'),

  /// Locks the offending app behind the user's PIN, app-locker style: the back
  /// press exits the reel and the PIN lock screen is shown; a correct PIN ejects
  /// to Detoxo's home. (Native enforcement is a follow-up; until then the engine
  /// degrades this to a back press.)
  lockApp('LOCK_APP'),

  /// Device-level lock via Device Admin. Retained for wire/config compatibility;
  /// no longer offered in the block-mode picker.
  lockScreen('LOCK_SCREEN'),
  overlay('OVERLAY'),
  none('NONE');

  const BlockingMode(this.wire);
  final String wire;

  static BlockingMode fromWire(String? v) => values.firstWhere(
    (e) => e.wire == v,
    orElse: () => BlockingMode.pressBack,
  );
}

/// How a platform's content is detected.
enum DetectionType {
  legacy('LEGACY'),
  calibration('CALIBRATION'),
  overlay('OVERLAY'),
  manual('MANUAL'),
  none('NONE');

  const DetectionType(this.wire);
  final String wire;

  static DetectionType fromWire(String? v) =>
      values.firstWhere((e) => e.wire == v, orElse: () => DetectionType.legacy);
}

/// The view-matching strategy a detector uses.
enum ViewDetector {
  findById('FINDBYID'),
  viewIdResName('VIEWID_RES_NAME'),
  contentDescription('CONT_DESC'),
  browser('BROWSER');

  const ViewDetector(this.wire);
  final String wire;

  static ViewDetector fromWire(String? v) => values.firstWhere(
    (e) => e.wire == v,
    orElse: () => ViewDetector.findById,
  );
}

/// Website blocklist matching modes.
enum WebMatchType {
  domain('DOMAIN'),
  // No `exact`: it needed a full URL the host-based native engine never has,
  // so an EXACT rule blocked nothing. `fromWire` now folds any stored EXACT
  // back into `domain`, which does block.
  wildcard('WILDCARD');

  const WebMatchType(this.wire);
  final String wire;

  static WebMatchType fromWire(String? v) =>
      values.firstWhere((e) => e.wire == v, orElse: () => WebMatchType.domain);
}

/// What an app-locker enforces when a locked app is opened.
enum AppLockAction {
  overlay('OVERLAY'),
  closeApp('CLOSE_APP'),
  lockScreen('LOCK_SCREEN');

  const AppLockAction(this.wire);
  final String wire;

  static AppLockAction fromWire(String? v) => values.firstWhere(
    (e) => e.wire == v,
    orElse: () => AppLockAction.closeApp,
  );
}

/// PIN credential types.
enum PinType {
  none('NONE'),
  custom('CUSTOM'),
  date('DATE'),
  time('TIME'),
  otp('OTP'),
  deviceDefault('DEVICE_DEFAULT');

  const PinType(this.wire);
  final String wire;

  static PinType fromWire(String? v) =>
      values.firstWhere((e) => e.wire == v, orElse: () => PinType.none);
}

/// Sections that a PIN can guard.
enum PinScope {
  app('DETOXO_APP'),
  settings('SETTINGS_APP'),
  planSwitch('PLAN_SWITCH'),
  detoxoSettings('DETOXO_SETTINGS'),
  appLocker('APP_LOCKER');

  const PinScope(this.wire);
  final String wire;

  static PinScope fromWire(String? v) =>
      values.firstWhere((e) => e.wire == v, orElse: () => PinScope.app);
}

/// App appearance preference. Domain-level (no Flutter dependency); the
/// presentation layer maps this to a Flutter `ThemeMode`.
enum AppThemeMode {
  system('SYSTEM'),
  light('LIGHT'),
  dark('DARK');

  const AppThemeMode(this.wire);
  final String wire;

  static AppThemeMode fromWire(String? v) =>
      values.firstWhere((e) => e.wire == v, orElse: () => AppThemeMode.dark);
}

/// App-background choice. Domain-level (no Flutter dependency); the presentation
/// layer maps this to a design-system `AppBackgroundStyle` and single SVG asset.
///
/// Backgrounds are theme-specific: [dark1]–[dark6] are the dark-mode options
/// (default [dark1]) and [aurora] + [light1]–[light5] are the light-mode options
/// (default [aurora], the built-in theme-aware ambient glow). A dark choice and a
/// light choice are stored independently — see `AppSettings.darkBackground` /
/// `lightBackground`.
enum AppBackground {
  aurora('AURORA'),
  dark1('DARK1'),
  dark2('DARK2'),
  dark3('DARK3'),
  dark4('DARK4'),
  dark5('DARK5'),
  dark6('DARK6'),
  light1('LIGHT1'),
  light2('LIGHT2'),
  light3('LIGHT3'),
  light4('LIGHT4'),
  light5('LIGHT5');

  const AppBackground(this.wire);
  final String wire;

  static AppBackground fromWire(
    String? v, {
    AppBackground fallback = AppBackground.aurora,
  }) => values.firstWhere((e) => e.wire == v, orElse: () => fallback);
}

/// Phase of a timed session (pause or curious).
enum SessionPhase { active, cooldown, idle }

/// Device form-factor used for calibration selection.
enum DeviceFormFactor {
  mobile('MOBILE'),
  tablet('TABLET'),
  landscape('LANDSCAPE'),
  landscapeTablet('LANDSCAPE_TABLET');

  const DeviceFormFactor(this.wire);
  final String wire;

  static DeviceFormFactor fromWire(String? v) => values.firstWhere(
    (e) => e.wire == v,
    orElse: () => DeviceFormFactor.mobile,
  );
}

/// Status of a single runtime permission in the onboarding funnel.
/// [permanentlyDenied] = the OS won't show the prompt again (don't-ask-again);
/// recovery is only via the app's system settings screen.
enum PermissionState { granted, denied, permanentlyDenied, unknown }

/// Live status of the native accessibility service.
enum ServiceStatus { running, stopped, unknown }
